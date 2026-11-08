#!/usr/bin/ucode

// 喵窝（主控内置的组网，Tailscale 协议）的命令行入口，LuCI 后端调用，输出一行 JSON：
//   status   设置、tailscale 安装与运行情况、本机在喵窝里的地址、对端、局域网候选网段、上次应用的结果
//   save     <JSON> 保存设置（enabled / networks / force_map / hostname / router_access / lan_access），不应用
//   apply    按设置入网或退出：tailscale up / down、防火墙区域、网段映射（入网要先在「插件配置」里登录主控账户）
//   install  装 tailscale（opkg / apk，后台跑，status 里看进度）
//   leave    把这台路由器从喵窝里删掉（主控里删设备、撤掉申报的网段、tailscale logout），并关掉开关
//   heal     tailscale0 的喵窝地址 / 路由丢了时重启 tailscaled 重新配置（status 发现时在后台调）
//
// 路由器用官方 tailscale 程序（局域网要靠它的子网路由开放出去，内核里的 tailscale 只能当出站）。
// 入网 key 由 meowx-core panel mesh enroll 向主控要（一次性、10 分钟有效），不用用户填。
// tailscaled 不改防火墙（--netfilter-mode=off）：转发、源地址转换、网段映射由这里写进 fw4，免得和透明代理的规则互相覆盖。
// 站点互通（lan_access）：收别的站点申报的网段（--accept-routes），局域网可以进喵窝，出喵窝的源地址换成本机的喵窝地址
// （主控按设备的 100.x 地址放行，对端也不必收我们的网段）；本机各网卡的网段加一条先于表 52 的策略路由，别的站点申报了
// 重叠的网段也不会把本地流量抢走。

'use strict';

import { readfile, writefile, popen, access, unlink, open, stat } from 'fs';
import { cursor } from 'uci';
import * as ubus from 'ubus';

const STATE_PATH = '/etc/meowx/mesh.json';
const SNAT_PATH = '/etc/meowx/mesh-snat.nft';
const DNAT_PATH = '/etc/meowx/mesh-dnat.nft';
const APP_LOG_PATH = '/var/log/meowx/app.log';
const INSTALL_LOG = '/var/log/meowx/mesh-install.log';
const INSTALL_FLAG = '/var/run/meowx-mesh-install.running';
const APPLY_FLAG = '/var/run/meowx-mesh-apply.running';
const TAILSCALE = '/usr/sbin/tailscale';
const TAILSCALED = '/usr/sbin/tailscaled';
const DEVICE = 'tailscale0';
const SELF = '/etc/meowx/ucode/mesh_cli.uc';
// 本地网段优先的策略路由优先级：在 tailscale 的 5210–5270 之前、透明代理的 1024 / 1025 之后
const LOCAL_RULE_PREF = 5190;
// 自动修复（重启 tailscaled）至少隔这么久一次
const HEAL_INTERVAL = 600;
// tailscale 装好后约 22MB，留一点余量
const NEED_SPACE_KB = 24 * 1024;

const uci = cursor();
uci.load('meowx');

function log(msg) {
	const t = localtime();
	const fd = open(APP_LOG_PATH, 'a');
	if (fd) {
		fd.write(sprintf('[%04d-%02d-%02d %02d:%02d:%02d] [喵窝] %s\n', t.year, t.mon, t.mday, t.hour, t.min, t.sec, msg));
		fd.close();
	}
}

function shell_quote(value) {
	return "'" + replace(`${value ?? ''}`, "'", "'\\''") + "'";
}

// 跑一条命令，返回 { code, out }（stdout + stderr）
function run(cmd) {
	const p = popen(cmd + ' 2>&1');
	if (!p) {
		return { code: -1, out: '' };
	}
	const out = p.read('all') ?? '';
	const code = p.close();
	return { code: code, out: trim(out) };
}

function run_json(cmd) {
	const r = run(cmd);
	let obj = null;
	try {
		obj = json(r.out || 'null');
	} catch (e) {
		obj = null;
	}
	return { code: r.code, out: r.out, json: obj };
}

function uci_bool(v) {
	return v == '1' || v == 'true' || v == 'yes' || v == 'on';
}

function uci_list(v) {
	if (v == null) {
		return [];
	}
	return type(v) == 'array' ? v : [ v ];
}

function settings() {
	return {
		enabled: uci_bool(uci.get('meowx', 'mesh', 'enabled')),
		networks: uci_list(uci.get('meowx', 'mesh', 'network')),
		force_map: uci_bool(uci.get('meowx', 'mesh', 'force_map')),
		hostname: uci.get('meowx', 'mesh', 'hostname') ?? '',
		router_access: uci_bool(uci.get('meowx', 'mesh', 'router_access')),
		lan_access: uci_bool(uci.get('meowx', 'mesh', 'lan_access'))
	};
}

function ensure_section() {
	if (uci.get('meowx', 'mesh') == null) {
		uci.set('meowx', 'mesh', 'mesh');
	}
}

// 路由器自己的稳定标识（主控按它把同一账号下多台路由器申报的网段分开）。第一次用时生成、存进 UCI。
function router_id() {
	let id = uci.get('meowx', 'mesh', 'router_id');
	if (id && match(id, /^[A-Za-z0-9._:-]{1,64}$/)) {
		return id;
	}
	id = trim(readfile('/proc/sys/kernel/random/uuid') ?? '');
	if (!id) {
		id = sprintf('%08x%08x', time(), int(time() * 7919) % 4294967296);
	}
	ensure_section();
	uci.set('meowx', 'mesh', 'router_id', id);
	uci.save('meowx');
	uci.commit('meowx');
	return id;
}

// 设备名：设置里填了用它，否则用系统主机名；只留小写字母、数字、连字符（主控按 DNS 标签校验）
function hostname(s) {
	let name = s.hostname;
	if (!name) {
		const sys = cursor();
		sys.load('system');
		name = sys.get_first('system', 'system', 'hostname') ?? 'openwrt';
	}
	name = lc(name);
	name = replace(name, /[^a-z0-9-]+/g, '-');
	name = replace(name, /^-+|-+$/g, '');
	if (length(name) > 63) {
		name = substr(name, 0, 63);
	}
	return name || 'openwrt';
}

function load_state() {
	return json(readfile(STATE_PATH) ?? 'null') ?? {};
}

function save_state(st) {
	writefile(STATE_PATH, sprintf('%J\n', st));
}

function installed() {
	return !!access(TAILSCALE) && !!access(TAILSCALED);
}

function package_manager() {
	if (system('command -v opkg >/dev/null 2>&1') == 0) {
		return 'opkg';
	}
	if (system('command -v apk >/dev/null 2>&1') == 0) {
		return 'apk';
	}
	return null;
}

function free_kb(path) {
	const r = run(`df -k ${shell_quote(path)} | tail -n 1`);
	const f = split(r.out, /[[:space:]]+/);
	return length(f) >= 4 ? int(f[3]) : 0;
}

function tailscale_version() {
	if (!installed()) {
		return null;
	}
	const r = run(`${TAILSCALE} version`);
	return r.code == 0 ? split(r.out, '\n')[0] : null;
}

function ts_status() {
	const r = run_json(`${TAILSCALE} status --json`);
	return r.json;
}

function ts_prefs() {
	const r = run_json(`${TAILSCALE} debug prefs`);
	return r.json;
}

// 等 tailscaled 起来（status 能回 JSON）
function wait_daemon(seconds) {
	for (let i = 0; i < seconds; i++) {
		if (ts_status()?.BackendState) {
			return true;
		}
		system('sleep 1');
	}
	return false;
}

// tailscale0 有没有本机的喵窝地址、路由表 52 有没有路由。tailscaled 入网时配好，之后被清掉（例如别的程序、
// 或已在运行时又跑了一次 /etc/init.d/tailscale start——它会先跑 tailscaled --cleanup）它不会自己补。
// 没有对端时表 52 本来就可能是空的，只在有对端时要求有路由。
function tun_health(st) {
	st ??= ts_status();
	if (st?.BackendState != 'Running') {
		return null;
	}
	const ip4 = filter(st.Self?.TailscaleIPs ?? [], (x) => index(x, ':') < 0)[0];
	const addrs = run(`ip -4 addr show dev ${DEVICE}`).out;
	const has_addr = !!ip4 && index(addrs, `inet ${ip4}/`) >= 0;
	const has_peers = length(keys(st.Peer ?? {})) > 0;
	const has_routes = length(trim(run('ip route show table 52').out)) > 0;
	return { ok: has_addr && (!has_peers || has_routes), has_addr: has_addr, has_routes: has_routes, ip: ip4, checked_at: time() };
}

// 等到 tailscaled 回到 Running（最多 seconds 秒）
function wait_running(seconds) {
	for (let i = 0; i < seconds; i++) {
		if (ts_status()?.BackendState == 'Running') {
			return true;
		}
		system('sleep 1');
	}
	return false;
}

// 重启 tailscaled：重新起来后按存着的设置入网、重新配 tailscale0 的地址与路由
function restart_daemon() {
	system('/etc/init.d/tailscale restart >/dev/null 2>&1');
	wait_daemon(20);
	return wait_running(30);
}

// 本机各网卡的 IPv4 网段（主路由表里内核生成的直连路由，不含 tailscale0）
function local_networks() {
	const out = [];
	for (let line in split(run('ip -4 route show table main proto kernel scope link').out, '\n')) {
		const m = match(line, /^([0-9.]+\/[0-9]+) dev ([^ ]+)/);
		if (m && m[2] != DEVICE && index(out, m[1]) < 0) {
			push(out, m[1]);
		}
	}
	return out;
}

// 站点互通开着时：本机各网卡的网段先查主路由表（优先级 LOCAL_RULE_PREF，在 tailscale 的表 52 之前）；关着时撤掉
function local_rules_sync(enable) {
	for (let i = 0; i < 64; i++) {
		if (system(`ip -4 rule del pref ${LOCAL_RULE_PREF} >/dev/null 2>&1`) != 0) {
			break;
		}
	}
	if (!enable) {
		return;
	}
	for (let net in local_networks()) {
		system(`ip -4 rule add pref ${LOCAL_RULE_PREF} to ${shell_quote(net)} lookup main >/dev/null 2>&1`);
	}
}

function host_of(url) {
	const m = match(url ?? '', /^[a-z]+:\/\/(\[[^\]]+\]|[^\/:]+)/);
	return m ? m[1] : null;
}

function is_ip(host) {
	return iptoarr(replace(host ?? '', /^\[|\]$/g, '')) != null;
}

// ---------- 局域网候选网段 ----------

function prefix_of(addr, mask) {
	const a = iptoarr(addr);
	if (!a || length(a) != 4 || mask < 1 || mask > 32) {
		return null;
	}
	const out = [];
	for (let i = 0; i < 4; i++) {
		const bits = mask - i * 8;
		const m = bits >= 8 ? 255 : (bits <= 0 ? 0 : (255 << (8 - bits)) & 255);
		push(out, a[i] & m);
	}
	return arrtoip(out) + '/' + mask;
}

// 防火墙 lan 区域里各接口的 IPv4 网段
function lan_networks() {
	const fw = cursor();
	fw.load('firewall');
	let nets = [];
	fw.foreach('firewall', 'zone', (z) => {
		if (z.name == 'lan') {
			nets = uci_list(z.network);
		}
	});
	if (length(nets) == 0) {
		nets = [ 'lan' ];
	}
	const conn = ubus.connect();
	const dump = conn?.call('network.interface', 'dump') ?? {};
	const out = [];
	for (let iface in dump.interface ?? []) {
		if (index(nets, iface.interface) < 0) {
			continue;
		}
		for (let a in iface['ipv4-address'] ?? []) {
			const p = prefix_of(a.address, a.mask);
			if (p && length(filter(out, (x) => x.cidr == p)) == 0) {
				push(out, { iface: iface.interface, cidr: p, address: a.address });
			}
		}
	}
	return out;
}

// ---------- 防火墙 ----------

// 喵窝进来的流量：转发到 lan、访问路由器本身按设置；进 lan 时做源地址转换（局域网设备的回包回到路由器，
// 不用知道 100.x 的路由）；映射段 1:1 改回原网段。tailscale 的 UDP 端口在 wan 上放行，打洞直连更容易成。
function firewall_apply(s, sites) {
	const fw = cursor();
	fw.load('firewall');
	fw.set('firewall', 'meowx_mesh', 'zone');
	fw.set('firewall', 'meowx_mesh', 'name', 'meshnet');
	fw.set('firewall', 'meowx_mesh', 'device', [ DEVICE ]);
	fw.set('firewall', 'meowx_mesh', 'input', s.router_access ? 'ACCEPT' : 'REJECT');
	fw.set('firewall', 'meowx_mesh', 'output', 'ACCEPT');
	fw.set('firewall', 'meowx_mesh', 'forward', 'REJECT');

	fw.set('firewall', 'meowx_mesh_lan', 'forwarding');
	fw.set('firewall', 'meowx_mesh_lan', 'src', 'meshnet');
	fw.set('firewall', 'meowx_mesh_lan', 'dest', 'lan');

	// 站点互通：局域网可以进喵窝
	if (s.lan_access) {
		fw.set('firewall', 'meowx_lan_mesh', 'forwarding');
		fw.set('firewall', 'meowx_lan_mesh', 'src', 'lan');
		fw.set('firewall', 'meowx_lan_mesh', 'dest', 'meshnet');
	} else {
		fw.delete('firewall', 'meowx_lan_mesh');
	}

	const ts = cursor();
	ts.load('tailscale');
	const port = ts.get('tailscale', 'settings', 'port') ?? '41641';
	fw.set('firewall', 'meowx_mesh_wg', 'rule');
	fw.set('firewall', 'meowx_mesh_wg', 'name', 'MeowX-Mesh');
	fw.set('firewall', 'meowx_mesh_wg', 'src', 'wan');
	fw.set('firewall', 'meowx_mesh_wg', 'proto', 'udp');
	fw.set('firewall', 'meowx_mesh_wg', 'dest_port', `${port}`);
	fw.set('firewall', 'meowx_mesh_wg', 'target', 'ACCEPT');

	let snat = `iifname "${DEVICE}" oifname != "${DEVICE}" counter masquerade comment "!meowx-mesh"\n`;
	// 站点互通：局域网设备发进喵窝的包，源地址换成本机的喵窝地址（主控按 100.x 放行；对端没收我们的网段也能回包）
	if (s.lan_access) {
		snat += `oifname "${DEVICE}" ip saddr != 100.64.0.0/10 counter masquerade comment "!meowx-mesh-out"\n`;
	}
	writefile(SNAT_PATH, snat);
	fw.set('firewall', 'meowx_mesh_snat', 'include');
	fw.set('firewall', 'meowx_mesh_snat', 'type', 'nftables');
	fw.set('firewall', 'meowx_mesh_snat', 'path', SNAT_PATH);
	fw.set('firewall', 'meowx_mesh_snat', 'position', 'chain-post');
	fw.set('firewall', 'meowx_mesh_snat', 'chain', 'srcnat');

	let dnat = '';
	for (let site in sites) {
		if (site.mapped) {
			dnat += `iifname "${DEVICE}" ip daddr ${site.advertised} counter dnat ip prefix to ${site.original} comment "!meowx-mesh"\n`;
		}
	}
	if (dnat) {
		writefile(DNAT_PATH, dnat);
		fw.set('firewall', 'meowx_mesh_dnat', 'include');
		fw.set('firewall', 'meowx_mesh_dnat', 'type', 'nftables');
		fw.set('firewall', 'meowx_mesh_dnat', 'path', DNAT_PATH);
		fw.set('firewall', 'meowx_mesh_dnat', 'position', 'chain-pre');
		fw.set('firewall', 'meowx_mesh_dnat', 'chain', 'dstnat');
	} else {
		fw.delete('firewall', 'meowx_mesh_dnat');
		unlink(DNAT_PATH);
	}
	fw.save('firewall');
	fw.commit('firewall');
	return system('fw4 -q reload >/dev/null 2>&1') == 0;
}

function firewall_remove() {
	const fw = cursor();
	fw.load('firewall');
	let changed = false;
	for (let name in [ 'meowx_mesh', 'meowx_mesh_lan', 'meowx_lan_mesh', 'meowx_mesh_wg', 'meowx_mesh_snat', 'meowx_mesh_dnat' ]) {
		if (fw.get('firewall', name) != null) {
			fw.delete('firewall', name);
			changed = true;
		}
	}
	unlink(SNAT_PATH);
	unlink(DNAT_PATH);
	if (changed) {
		fw.save('firewall');
		fw.commit('firewall');
		system('fw4 -q reload >/dev/null 2>&1');
	}
}

// ---------- 透明代理共存 ----------

// 透明代理（fake-ip）下路由器自己查主控 / 中继的域名会拿到假地址，tailscaled 的连接按 fwmark 绕过代理后就连不上。
// 这些域名记在 mesh.json 的 hosts 里，生成运行配置时加进 fake-ip-filter（mixin.uc），防火墙按 fwmark 放行
// tailscaled 的连接（hijack.ut）。列表或开关变了、代理在跑时要重载一次。
function sync_proxy(before, after) {
	if (join(',', sort(before ?? [])) == join(',', sort(after ?? []))) {
		return;
	}
	if (system('/etc/init.d/meowx running >/dev/null 2>&1') == 0) {
		log('主控 / 中继地址变了，重载代理以绕开 fake-ip');
		system('/etc/init.d/meowx reload >/dev/null 2>&1');
	}
}

function relay_hosts() {
	const r = run_json(`${TAILSCALE} debug derp-map`);
	const out = [];
	for (let id, region in r.json?.Regions ?? {}) {
		for (let node in region.Nodes ?? []) {
			const h = node.HostName;
			if (h && !is_ip(h) && index(out, h) < 0) {
				push(out, h);
			}
		}
	}
	return out;
}

// ---------- 命令 ----------

// 正在应用（标记文件 5 分钟内；更早的是没清掉的残留，同 apply 的判断）
function applying() {
	const f = stat(APPLY_FLAG);
	return !!f && time() - f.mtime < 300;
}

function panel_logged_in() {
	return !!access('/etc/meowx/panel.json');
}

function status() {
	const s = settings();
	const out = {
		settings: s,
		router_id: uci.get('meowx', 'mesh', 'router_id') ?? null,
		hostname: hostname(s),
		installed: installed(),
		version: tailscale_version(),
		package_manager: package_manager(),
		free_kb: free_kb('/overlay') || free_kb('/'),
		need_kb: NEED_SPACE_KB,
		installing: !!access(INSTALL_FLAG),
		install_log: access(INSTALL_LOG) ? trim(readfile(INSTALL_LOG) ?? '') : null,
		applying: applying(),
		panel_logged_in: panel_logged_in(),
		lan: lan_networks(),
		state: load_state(),
		daemon: false
	};
	if (out.install_log && length(out.install_log) > 4000) {
		out.install_log = substr(out.install_log, -4000);
	}
	if (out.installed) {
		const st = ts_status();
		if (st?.BackendState) {
			out.daemon = true;
			out.backend = st.BackendState;
			const self = st.Self ?? {};
			out.self = {
				id: self.ID,
				name: self.HostName,
				dns_name: rtrim(self.DNSName ?? '', '.'),
				ip: (self.TailscaleIPs ?? [])[0],
				online: self.Online,
				relay: self.Relay
			};
			out.peers = [];
			for (let k, p in st.Peer ?? {}) {
				push(out.peers, {
					name: p.HostName,
					dns_name: rtrim(p.DNSName ?? '', '.'),
					ip: (p.TailscaleIPs ?? [])[0],
					os: p.OS,
					online: p.Online,
					relay: p.Relay,
					direct: !!p.CurAddr,
					routes: p.PrimaryRoutes ?? []
				});
			}
			const prefs = ts_prefs();
			out.control_url = prefs?.ControlURL;
			out.advertised = prefs?.AdvertiseRoutes ?? [];
			// 自检：地址 / 路由丢了就在后台重启 tailscaled（至多 HEAL_INTERVAL 一次，应用中不动）
			out.tun = s.enabled ? tun_health(st) : null;
			if (out.tun && !out.tun.ok && !out.applying && time() - (out.state.healed_at ?? 0) > HEAL_INTERVAL) {
				system(`(${SELF} heal >/dev/null 2>&1 &)`);
				out.healing = true;
			}
		}
	}
	return out;
}

function fail(st, msg) {
	st.error = msg;
	st.applied_at = time();
	save_state(st);
	log('应用失败：' + msg);
	return { success: false, error: msg };
}

function apply_up() {
	const s = settings();
	const st = load_state();
	const hosts_before = st.hosts ?? [];
	if (!installed()) {
		return fail(st, '还没有安装 tailscale');
	}
	if (!panel_logged_in()) {
		return fail(st, '还没有登录主控账户（在「插件配置」里用主控的登录链接登录）');
	}
	system('/etc/init.d/tailscale enable >/dev/null 2>&1');
	// /etc/init.d/tailscale start 每次先跑 tailscaled --cleanup：已在运行时再 start 会清掉 tailscale0 的地址与路由、
	// 服务却不重启，之后一直没有地址（#1722，tailscale 1.104）。只在没跑时才 start
	if (system('/etc/init.d/tailscale running >/dev/null 2>&1') != 0 && !ts_status()?.BackendState) {
		system('/etc/init.d/tailscale start >/dev/null 2>&1');
	}
	if (!wait_daemon(15)) {
		return fail(st, 'tailscaled 没有启动');
	}

	const ps = run_json('/usr/bin/meowx-core panel mesh status');
	if (!ps.json || ps.json.success === false) {
		return fail(st, ps.json?.error ?? ('连不上主控：' + ps.out));
	}
	if (!ps.json.available) {
		return fail(st, ps.json.message || '主控没有开放喵窝');
	}
	const control = rtrim(ps.json.control_url ?? '', '/');
	if (!control) {
		return fail(st, '主控没有给出控制地址');
	}
	st.control_url = control;
	st.magic_dns = ps.json.magic_dns;

	// 先把主控域名加进去、让代理绕开 fake-ip，tailscaled 才连得上主控（中继地址入网后再补）
	const control_hosts = filter([ host_of(control) ], (h) => h && !is_ip(h));
	st.hosts = [ ...hosts_before ];
	for (let h in control_hosts) {
		if (index(st.hosts, h) < 0) {
			push(st.hosts, h);
		}
	}
	const hosts_phase1 = [ ...st.hosts ];
	save_state(st);
	sync_proxy(hosts_before, hosts_phase1);

	// 申报这台路由器要开放的网段（整份），拿到每个网段在喵窝里用的地址
	const id = router_id();
	let cmd = `/usr/bin/meowx-core panel mesh sites --router ${shell_quote(id)}`;
	if (s.force_map) {
		cmd += ' --force-map';
	}
	for (let n in s.networks) {
		cmd += ' ' + shell_quote(n);
	}
	const sr = run_json(cmd);
	if (!sr.json || sr.json.success === false) {
		return fail(st, '申报网段失败：' + (sr.json?.error ?? sr.out));
	}
	const sites = filter(sr.json.sites ?? [], (x) => x.router == id);
	const advertised = map(sites, (x) => x.advertised);
	st.sites = map(sites, (x) => ({ original: x.original, advertised: x.advertised, mapped: x.mapped }));

	// 没登录、或者登录的是别的控制服务器：向主控要一次性 key 重新入网
	const ts = ts_status() ?? {};
	const prefs = ts_prefs() ?? {};
	const name = hostname(s);
	const other_control = prefs.ControlURL && rtrim(prefs.ControlURL, '/') != control;
	const need_login = ts.BackendState == 'NeedsLogin' || ts.BackendState == 'NoState' || ts.BackendState == 'NeedsMachineAuth' || other_control;
	let up = `${TAILSCALE} up --reset --timeout=60s --login-server=${shell_quote(control)} --hostname=${shell_quote(name)}` +
		` --advertise-routes=${shell_quote(join(',', advertised))} --accept-dns=false --accept-routes=${s.lan_access ? 'true' : 'false'} --netfilter-mode=off`;
	if (need_login) {
		const prev = match(ts.Self?.ID ?? '', /^[0-9]+$/) ? ts.Self.ID : '';
		const er = run_json(`/usr/bin/meowx-core panel mesh enroll ${shell_quote(name)} ${shell_quote(prev)}`);
		if (!er.json?.auth_key) {
			return fail(st, '向主控要入网 key 失败：' + (er.json?.error ?? er.out));
		}
		up += ` --authkey=${shell_quote(er.json.auth_key)}`;
		if (other_control) {
			up += ' --force-reauth';
		}
		log(`入网：${name} → ${control}`);
	}
	const ur = run(up);
	if (ur.code != 0) {
		// 别把 key 写进日志 / 应答
		return fail(st, 'tailscale up 失败：' + replace(ur.out, /hskey-[A-Za-z0-9_-]+/g, '***'));
	}

	if (!firewall_apply(s, st.sites)) {
		log('防火墙重载失败');
	}
	local_rules_sync(s.lan_access);

	// 自检：tailscale0 要有本机的喵窝地址、有对端时表 52 要有路由；不对就重启 tailscaled 重新配一次
	system('sleep 2');
	let health = tun_health();
	if (health && !health.ok) {
		log(`tailscale0 ${health.has_addr ? '路由表为空' : '没有喵窝地址'}，重启 tailscaled 重新配置`);
		st.healed_at = time();
		restart_daemon();
		local_rules_sync(s.lan_access);
		health = tun_health();
	}
	st.tun = health;
	st.warning = health && !health.ok ? 'tailscale0 没有喵窝地址或路由（重启 tailscaled 也没恢复）：看看有没有别的程序在改 tailscale0，或 network 里绑定了 tailscale0 的接口' : null;

	// 入网后按现在的主控 + 中继重算（换过的中继域名不留着）
	const hosts = [ ...control_hosts ];
	for (let h in relay_hosts()) {
		if (index(hosts, h) < 0) {
			push(hosts, h);
		}
	}
	st.hosts = hosts;
	st.error = null;
	st.applied_at = time();
	st.advertised = advertised;
	save_state(st);
	sync_proxy(hosts_phase1, st.hosts);
	log(`已入网，开放网段：${length(advertised) ? join('，', advertised) : '无'}`);
	return { success: true };
}

function apply_down() {
	const st = load_state();
	const hosts_before = st.hosts ?? [];
	if (installed() && ts_status()?.BackendState) {
		run(`${TAILSCALE} down`);
	}
	if (installed()) {
		system('/etc/init.d/tailscale stop >/dev/null 2>&1');
		system('/etc/init.d/tailscale disable >/dev/null 2>&1');
	}
	firewall_remove();
	local_rules_sync(false);
	st.hosts = [];
	st.tun = null;
	st.warning = null;
	st.error = null;
	st.applied_at = time();
	save_state(st);
	sync_proxy(hosts_before, []);
	log('已关闭');
	return { success: true };
}

function apply() {
	// 上一次应用没跑完（5 分钟内）就不再起一次；更早的当作残留
	if (applying()) {
		return { success: false, error: '正在应用，请稍后再试' };
	}
	writefile(APPLY_FLAG, `${time()}\n`);
	let res;
	try {
		res = settings().enabled ? apply_up() : apply_down();
	} catch (e) {
		res = fail(load_state(), `${e}`);
	}
	unlink(APPLY_FLAG);
	return res;
}

function install() {
	if (installed()) {
		return { success: true, already: true };
	}
	if (access(INSTALL_FLAG)) {
		return { success: true, running: true };
	}
	const pm = package_manager();
	if (!pm) {
		return { success: false, error: '找不到 opkg / apk' };
	}
	const free = free_kb('/overlay') || free_kb('/');
	if (free < NEED_SPACE_KB) {
		return { success: false, error: sprintf('存储空间不够：tailscale 约需 %d MB，剩余 %d MB', NEED_SPACE_KB / 1024, free / 1024) };
	}
	const cmd = pm == 'opkg' ? 'opkg update && opkg install tailscale' : 'apk update && apk add tailscale';
	// 装完先不启动：开关打开、应用时再起（关着的时候不占内存）
	system(`mkdir -p /var/log/meowx /var/run; touch ${INSTALL_FLAG}; rm -f ${INSTALL_LOG}; ` +
		`( (${cmd}) > ${INSTALL_LOG} 2>&1; rc=$?; ` +
		`[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale stop >/dev/null 2>&1 && /etc/init.d/tailscale disable >/dev/null 2>&1; ` +
		`echo "exit $rc" >> ${INSTALL_LOG}; rm -f ${INSTALL_FLAG} ) >/dev/null 2>&1 &`);
	log(`开始安装 tailscale（${pm}）`);
	return { success: true, running: true };
}

function leave() {
	const s = settings();
	const res = { success: true };
	if (panel_logged_in()) {
		const st = installed() ? ts_status() : null;
		const id = st?.Self?.ID;
		if (id && match(id, /^[0-9]+$/)) {
			const r = run_json(`/usr/bin/meowx-core panel mesh delete ${shell_quote(id)}`);
			if (r.json?.success === false) {
				res.warning = '主控里删设备失败：' + (r.json.error ?? r.out);
			}
		}
		// 撤掉这台路由器申报的网段
		const rid = uci.get('meowx', 'mesh', 'router_id');
		if (rid) {
			run_json(`/usr/bin/meowx-core panel mesh sites --router ${shell_quote(rid)}`);
		}
	}
	if (installed() && ts_status()?.BackendState) {
		run(`${TAILSCALE} logout`);
	}
	ensure_section();
	uci.set('meowx', 'mesh', 'enabled', '0');
	uci.save('meowx');
	uci.commit('meowx');
	apply_down();
	const st = load_state();
	st.sites = [];
	st.advertised = [];
	save_state(st);
	log(`已退出喵窝（${s.hostname || hostname(s)}）`);
	return res;
}

// tailscale0 的喵窝地址 / 路由丢了：重启 tailscaled 重新配置（status 发现时在后台调，至多 HEAL_INTERVAL 一次）
function heal() {
	const s = settings();
	if (!s.enabled || !installed() || applying()) {
		return { success: true, skipped: true };
	}
	writefile(APPLY_FLAG, `${time()}\n`);
	const st = load_state();
	st.healed_at = time();
	save_state(st);
	let health = tun_health();
	if (health && !health.ok) {
		log(`tailscale0 ${health.has_addr ? '路由表为空' : '没有喵窝地址'}，重启 tailscaled 重新配置`);
		restart_daemon();
		local_rules_sync(s.lan_access);
		health = tun_health();
		log(health?.ok ? 'tailscale0 已恢复' : 'tailscale0 重启后仍没有恢复');
	}
	st.tun = health;
	st.warning = health && !health.ok ? 'tailscale0 没有喵窝地址或路由（重启 tailscaled 也没恢复）：看看有没有别的程序在改 tailscale0，或 network 里绑定了 tailscale0 的接口' : null;
	save_state(st);
	unlink(APPLY_FLAG);
	return { success: true, tun: health };
}

// 网段写法：a.b.c.d/n，存成网络地址（192.168.1.1/24 → 192.168.1.0/24）
function normalize_cidr(value) {
	const m = match(trim(`${value ?? ''}`), /^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\/([0-9]{1,2})$/);
	if (!m) {
		return null;
	}
	return prefix_of(m[1], int(m[2]));
}

function save(raw) {
	let s;
	try {
		s = json(raw ?? '');
	} catch (e) {
		s = null;
	}
	if (type(s) != 'object') {
		return { success: false, error: 'bad settings' };
	}
	const networks = [];
	for (let n in s.networks ?? []) {
		const p = normalize_cidr(n);
		if (!p) {
			return { success: false, error: sprintf('%s 不是合法的网段（写法如 192.168.1.0/24）', n) };
		}
		if (index(networks, p) < 0) {
			push(networks, p);
		}
	}
	if (length(networks) > 16) {
		return { success: false, error: '一次最多开放 16 个网段' };
	}
	let name = lc(trim(`${s.hostname ?? ''}`));
	if (name != '' && !match(name, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/)) {
		return { success: false, error: '设备名只能用小写字母、数字和连字符（不超过 63 个字符）' };
	}
	ensure_section();
	uci.set('meowx', 'mesh', 'enabled', s.enabled ? '1' : '0');
	uci.set('meowx', 'mesh', 'force_map', s.force_map ? '1' : '0');
	uci.set('meowx', 'mesh', 'router_access', s.router_access ? '1' : '0');
	uci.set('meowx', 'mesh', 'lan_access', s.lan_access ? '1' : '0');
	if (length(networks) > 0) {
		uci.set('meowx', 'mesh', 'network', networks);
	} else {
		uci.delete('meowx', 'mesh', 'network');
	}
	if (name != '') {
		uci.set('meowx', 'mesh', 'hostname', name);
	} else {
		uci.delete('meowx', 'mesh', 'hostname');
	}
	uci.save('meowx');
	uci.commit('meowx');
	return { success: true };
}

const action = ARGV[0] ?? 'status';
let result;
if (action == 'status') {
	result = status();
} else if (action == 'save') {
	result = save(ARGV[1]);
} else if (action == 'apply') {
	result = apply();
} else if (action == 'install') {
	result = install();
} else if (action == 'leave') {
	result = leave();
} else if (action == 'heal') {
	result = heal();
} else {
	result = { success: false, error: 'usage: mesh_cli.uc status | save <JSON> | apply | install | leave | heal' };
}
print(sprintf('%J\n', result));
