#!/usr/bin/ucode

// 喵窝（主控内置的组网，Tailscale 协议）的命令行入口，LuCI 后端调用，输出一行 JSON：
//   status   设置、tailscale 安装与运行情况、本机在喵窝里的地址、对端、局域网候选网段、上次应用的结果
//   save     <JSON> 保存设置（enabled / networks / force_map / hostname / router_access / lan_access），不应用
//   apply    按设置入网或退出：tailscale up / down、防火墙区域、网段映射（入网要先在「插件配置」里登录主控账户）
//   install  装 tailscale（opkg / apk，后台跑，status 里看进度）
//   leave    把这台路由器从喵窝里删掉（主控里删设备、撤掉申报的网段、tailscale logout），并关掉开关
//   heal     tailscale0 的喵窝地址 / 路由丢了时重启 tailscaled 重新配置（status 发现时在后台调）
//   panel    喵窝页要的主控信息：访问范围、设备上限、共享设备 / 站点、可经喵窝连接的服务器（meowx-core panel mesh view），
//            外加当前运行配置里经喵窝连接的节点（页面打开时取一次，不在 2 秒一次的轮询里）
//   whitelist <0|1>  「白名单节点经喵窝连线」开关（缺省开）；生效与否变了就在后台重拉订阅 / 重载（init 的 mesh_refresh）
//   direct   打印 on / off：白名单直连这一刻生效没有（mesh_direct.uc direct_on）
//   header <订阅地址> [<实时通道地址>]  打印拉这份订阅时 X-MeowX-Mesh 头的值（on / off；不是登录主控的订阅打印空行）
//   nodes <on|off>  从 stdin 读配置（JSON：proxies / proxy-groups / rules / sub-rules），stdout 输出处理喵窝版节点后的补丁（JSON；不用改输出 {}）
//   tick [force]    设备中继与路径上报（cron 每分钟一次，标记 #mmx-mesh；入网后、改中继设置后带 force 立刻跑一次）：
//                   meowx-core panel mesh tick 报路径、报中继、按主控的 desired 执行 tailscale set，这里按它的输出开 / 撤 fw4 规则 meowx_mesh_relay
//   relay           中继一节要的：本机设备编号、主控里这台的中继配置与状态、本机中继、版本够不够、静态包信息
//   relay_set <JSON> 保存中继配置到主控（enabled / port / static_endpoints / ddns_host / share），成功后后台 tick force
//   paths           主控汇总的路径（GET /user/mesh/paths?device_id=本机）+ 上次 tick 的结果；主控读不到时带本机中继会话；顺手后台 tick 一次
//   netcheck        tailscale netcheck --format=json 的 NAT 信息（有网络开销，只在页面打开中继一节时调）
//   cron            按当前设置补上 / 撤掉 tick 的定时任务（定时任务只在入网时加：已入网的老版本升级上来由 uci-defaults 调这个补上）
//   install_static  装 MeowX 提供的 tailscale 静态包（官方源码编的合体程序，带中继服务器；后台跑，status 里看进度）
//
// 路由器用官方 tailscale 程序（局域网要靠它的子网路由开放出去，内核里的 tailscale 只能当出站）。
// 入网 key 由 meowx-core panel mesh enroll 向主控要（一次性、10 分钟有效），不用用户填。
// tailscaled 不改防火墙（--netfilter-mode=off）：转发、源地址转换、网段映射由这里写进 fw4，免得和透明代理的规则互相覆盖。
// 站点互通（lan_access）：收别的站点申报的网段（--accept-routes），局域网可以进喵窝，出喵窝的源地址换成本机的喵窝地址
// （主控按设备的 100.x 地址放行，对端也不必收我们的网段）；本机各网卡的网段加一条先于表 52 的策略路由，别的站点申报了
// 重叠的网段也不会把本地流量抢走。

'use strict';

import { readfile, writefile, popen, access, unlink, open, stat, stdin, rename, symlink, mkdir } from 'fs';
import { cursor } from 'uci';
import * as ubus from 'ubus';
import { direct_on, header_value, mesh_nodes } from '/etc/meowx/ucode/mesh_direct.uc';
import { relay_via } from '/etc/meowx/ucode/mesh_relay_name.uc';

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
const PANEL_PATH = '/etc/meowx/panel.json';
const RUN_PROFILE = '/etc/meowx/run/config.yaml';
// 本地网段优先的策略路由优先级：在 tailscale 的 5210–5270 之前、透明代理的 1024 / 1025 之后
const LOCAL_RULE_PREF = 5190;
// 自动修复（重启 tailscaled）至少隔这么久一次
const HEAL_INTERVAL = 600;
// tailscale 装好后约 22MB，留一点余量
const NEED_SPACE_KB = 24 * 1024;
const CORE = '/usr/bin/meowx-core';
const TS_SOCKET = '/var/run/tailscale/tailscaled.sock';
// tick 的状态放内存盘（每分钟都写，别磨闪存）：重启后丢了无所谓，下一轮重新报
const TICK_DIR = '/var/run/meowx-mesh';
const TICK_LAST = TICK_DIR + '/last.json';
const TICK_FW_ERROR = TICK_DIR + '/fw-error';
const CRONTAB = '/etc/crontabs/root';
// 标记不能含「#meowx」：/etc/init.d/meowx 停服务时删掉所有含它的行，而喵窝不依赖 meowx 服务
const CRON_TAG = '#mmx-mesh';
// 设备中继要求的 tailscaled 最低版本（主控 device_relay.min_version 的缺省）
const RELAY_MIN_VERSION = '1.86.0';
// MeowX 提供的 tailscale 静态包（官方源码编的合体程序，CI 见 .github/workflows/tailscale-static.yml）：每次发 OpenWrt 版时定一次版本
const TS_STATIC_VERSION = '1.104.5';
const TS_STATIC_BASE = 'https://dl.miaomiaowux.com/meowx/openwrt/tailscale';
const TS_STATIC_TMP = '/tmp/meowx-tailscale.combined';

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
		lan_access: uci_bool(uci.get('meowx', 'mesh', 'lan_access')),
		// 白名单节点经喵窝连线：缺省开，本机偏好（退出登录不清）；只有写成 0 才算关
		whitelist_direct: uci.get('meowx', 'mesh', 'whitelist_direct') != '0'
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

// 这台设备是不是授权给本机的中继（tailscale whois 的 CapMap 里有 relay-target）：只在中继 IP 对上不止一台设备时才问，
// 结果在内存盘里留 5 分钟（status 2 秒一次）
const RELAY_CAPS = TICK_DIR + '/relay_caps.json';
function relay_target_checker() {
	let cache = null, dirty = false;
	try {
		cache = json(readfile(RELAY_CAPS) ?? 'null');
	} catch (e) {
		cache = null;
	}
	if (type(cache) != 'object') {
		cache = {};
	}
	const now = time();
	return {
		check: (q) => {
			const ip = (q?.TailscaleIPs ?? [])[0];
			if (!ip) {
				return false;
			}
			const c = cache[ip];
			if (c && now - c.at < 300) {
				return c.ok;
			}
			const r = run_json(`${TAILSCALE} whois --json ${shell_quote(ip)}`);
			const ok = exists(r.json?.CapMap ?? {}, 'tailscale.com/cap/relay-target');
			cache[ip] = { ok: ok, at: now };
			dirty = true;
			return ok;
		},
		save: () => {
			if (dirty) {
				mkdir(TICK_DIR);
				writefile(RELAY_CAPS, sprintf('%J', cache));
			}
		}
	};
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
	for (let name in [ 'meowx_mesh', 'meowx_mesh_lan', 'meowx_lan_mesh', 'meowx_mesh_wg', 'meowx_mesh_relay', 'meowx_mesh_snat', 'meowx_mesh_dnat' ]) {
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

// 设备中继的 UDP 端口：在 wan 上放行（port = null 撤掉）。没变就不动、不重载 fw4。返回错误文字（成功 null）
function relay_firewall(port) {
	const fw = cursor();
	fw.load('firewall');
	const has = fw.get('firewall', 'meowx_mesh_relay') != null;
	if (port) {
		if (has && fw.get('firewall', 'meowx_mesh_relay', 'dest_port') == `${port}`) {
			return null;
		}
		fw.set('firewall', 'meowx_mesh_relay', 'rule');
		fw.set('firewall', 'meowx_mesh_relay', 'name', 'MeowX-Mesh-Relay');
		fw.set('firewall', 'meowx_mesh_relay', 'src', 'wan');
		fw.set('firewall', 'meowx_mesh_relay', 'proto', 'udp');
		fw.set('firewall', 'meowx_mesh_relay', 'dest_port', `${port}`);
		fw.set('firewall', 'meowx_mesh_relay', 'target', 'ACCEPT');
	} else {
		if (!has) {
			return null;
		}
		fw.delete('firewall', 'meowx_mesh_relay');
	}
	fw.save('firewall');
	fw.commit('firewall');
	const r = run('fw4 -q reload');
	if (r.code != 0) {
		return 'fw4 重载失败：' + (r.out || `exit ${r.code}`);
	}
	log(port ? `设备中继：放行 UDP ${port}` : '设备中继：撤掉 UDP 端口放行');
	return null;
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
	return !!access(PANEL_PATH);
}

// 登录的主控（只取地址：base = 主控、sub_base = 订阅域名，老内核没有 sub_base）；没登录给 null
function panel_hosts() {
	let st = null;
	try {
		st = json(readfile(PANEL_PATH) ?? 'null');
	} catch (e) {
		st = null;
	}
	return type(st) == 'object' && st.base ? { base: st.base, sub_base: st.sub_base } : null;
}

// 白名单直连这一刻生效没有（拉订阅的请求头、运行配置里留不留喵窝版节点都看它）
function direct_now() {
	const s = settings();
	return direct_on({ enabled: s.enabled, whitelist: s.whitelist_direct, logged_in: panel_logged_in(), state: load_state() });
}

// 应用 / 退出 / 拨开关之后调：生效与否和上次记下的（mesh.json 的 direct）不一样了，就在后台让 init 重拉在用的本主控订阅
// （带新的 X-MeowX-Mesh）、拉不到也按新状态重新生成运行配置。设置在应用前就已经存好，所以比的是上次记下的结果、不是应用前现算的
function direct_changed() {
	const after = direct_now();
	const st = load_state();
	if (after != !!st.direct) {
		st.direct = after;
		save_state(st);
		log(`白名单节点经喵窝连线：${after ? '生效' : '不生效'}，重拉订阅 / 重载`);
		system('(/etc/init.d/meowx mesh_refresh >/dev/null 2>&1 &)');
	}
	return after;
}

// ---------- 设备中继 ----------

// tailscale 版本号不低于 min（认不出来算低，同 meowx-core 的 versionAtLeast）
function version_at_least(v, min) {
	const parse = (x) => {
		const m = match(`${x ?? ''}`, /^v?([0-9]+)\.([0-9]+)(\.([0-9]+))?/);
		return m ? [ int(m[1]), int(m[2]), int(m[4] ?? 0) ] : null;
	};
	const a = parse(v), b = parse(min);
	if (!a || !b) {
		return false;
	}
	for (let i = 0; i < 3; i++) {
		if (a[i] != b[i]) {
			return a[i] > b[i];
		}
	}
	return true;
}

// 静态包的架构（manifest 里的键）：按 /etc/openwrt_release 的 DISTRIB_ARCH。ARMv7 以上的 32 位 ARM 共用 GOARM=7 那一个；
// 认不出的（arm1176 / arm926、mips64、i386…）给 null，不提供静态包
function static_arch() {
	const m = match(readfile('/etc/openwrt_release') ?? '', /DISTRIB_ARCH='?([A-Za-z0-9_.+-]+)'?/);
	const a = m ? m[1] : '';
	if (match(a, /^aarch64/)) {
		return 'aarch64';
	}
	if (match(a, /^x86_64/)) {
		return 'x86_64';
	}
	if (match(a, /^arm_cortex-a[0-9]+/)) {
		return 'armv7';
	}
	if (match(a, /^mipsel_/)) {
		return 'mipsel';
	}
	if (match(a, /^mips_/)) {
		return 'mips';
	}
	if (match(a, /^riscv64/)) {
		return 'riscv64';
	}
	return null;
}

// 上次 tick 的输出（内存盘，带 at）
function tick_last() {
	let v = null;
	try {
		v = json(readfile(TICK_LAST) ?? 'null');
	} catch (e) {
		v = null;
	}
	return type(v) == 'object' ? v : null;
}

// 每分钟一次的 tick：入网时加、退出时删。写临时文件再改名（目录的修改时间变了 busybox crond 才重新读）
function cron_sync(on) {
	const cur = readfile(CRONTAB) ?? '';
	const lines = filter(split(cur, '\n'), (l) => l != '' && index(l, CRON_TAG) < 0);
	if (on) {
		push(lines, `* * * * * /usr/bin/ucode -S ${SELF} tick >/dev/null 2>&1 ${CRON_TAG}`);
	}
	const next = length(lines) ? join('\n', lines) + '\n' : '';
	if (next == cur) {
		return;
	}
	mkdir('/etc/crontabs');
	writefile(CRONTAB + '.mmx-tmp', next);
	rename(CRONTAB + '.mmx-tmp', CRONTAB);
	if (on && system('pidof crond >/dev/null 2>&1') != 0) {
		system('/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron start >/dev/null 2>&1');
	}
}

// 本机在主控设备列表里的编号（tailscale status 的 Self.ID，Headscale 下是数字）
function self_device_id(st) {
	st ??= ts_status();
	const id = st?.Self?.ID;
	return (st?.BackendState == 'Running' && id && match(id, /^[0-9]+$/)) ? id : null;
}

// tick：meowx-core 报路径 / 报中继 / tailscale set，这里按它的 firewall 开 / 撤 UDP 端口。
// force = 入网后、改中继设置后立刻对账；during_apply = 在 apply 里调（cron 那一轮碰上正在应用就跳过）
function tick(force, during_apply) {
	const s = settings();
	if (!s.enabled || !installed() || !panel_logged_in()) {
		// 喵窝关着（cron 残留）：撤掉端口与定时任务
		const err = relay_firewall(null);
		if (!s.enabled) {
			cron_sync(false);
		}
		return { success: true, skipped: true, error: err };
	}
	if (!during_apply && applying()) {
		return { success: true, skipped: true, reason: 'applying' };
	}
	mkdir(TICK_DIR);
	let cmd = `${CORE} panel mesh tick --tailscale ${TAILSCALE} --socket ${TS_SOCKET} --state ${TICK_DIR}`;
	if (force) {
		cmd += ' --force';
	}
	const fw_err = trim(readfile(TICK_FW_ERROR) ?? '');
	if (fw_err) {
		cmd += ' --fw-error ' + shell_quote(fw_err);
	}
	const p = popen(cmd + ' 2>/dev/null');
	const raw = p ? trim(p.read('all') ?? '') : '';
	if (p) {
		p.close();
	}
	let out = null;
	try {
		out = json(raw || 'null');
	} catch (e) {
		out = null;
	}
	if (type(out) != 'object') {
		return { success: false, error: '内核没有回应：' + substr(raw, 0, 200) };
	}
	if (out.success === false) {
		// 老内核没有 tick（unknown mesh command）：别动防火墙
		if (match(out.error ?? '', /unknown mesh command/)) {
			out.error = '内核版本太旧，没有设备中继（升级 MeowX）';
		}
		return out;
	}
	if (type(out.firewall) == 'object') {
		const port = int(out.firewall.relay_port ?? 0);
		const err = relay_firewall(port > 0 && port < 65536 ? port : null);
		if (err) {
			writefile(TICK_FW_ERROR, err + '\n');
			log(err);
			out.fw_error = err;
		} else {
			unlink(TICK_FW_ERROR);
		}
	}
	out.at = time();
	writefile(TICK_LAST, sprintf('%J\n', out));
	return out;
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
		ts_static: uci.get('meowx', 'mesh', 'ts_static') ?? null,
		static_version: TS_STATIC_VERSION,
		static_arch: static_arch(),
		relay_min_version: RELAY_MIN_VERSION,
		relay_last: tick_last(),
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
	out.version_ok = version_at_least(out.version, RELAY_MIN_VERSION);
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
			const all_peers = values(st.Peer ?? {});
			const relay_target = relay_target_checker();
			for (let k, p in st.Peer ?? {}) {
				push(out.peers, {
					name: p.HostName,
					dns_name: rtrim(p.DNSName ?? '', '.'),
					ip: (p.TailscaleIPs ?? [])[0],
					os: p.OS,
					online: p.Online,
					relay: p.Relay,
					direct: !!p.CurAddr,
					cur_addr: p.CurAddr,
					// 走设备中继（ip:port:vni:N）：先于直连判断（规格 mesh-peer-relay.md §2.2）
					peer_relay: p.PeerRelay || null,
					// 中继设备名：中继 IP 对上本机设备列表里某台上报的公网端点（mesh_relay_name.uc；认不出为 null，界面再用主控的）
					peer_relay_via: p.PeerRelay ? relay_via(p, all_peers, relay_target.check) : null,
					// 上报的公网端点（本机当中继时，界面按它给会话两端对上设备名）
					addrs: p.Addrs ?? [],
					// 最近没有往来（tailscale 的 Active）：界面显示「空闲」而不是「经中继」——Relay 只是对端的 home DERP，不代表正在走中继
					active: p.Active,
					routes: p.PrimaryRoutes ?? []
				});
			}
			relay_target.save();
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
	// tailscale up --reset 会清掉中继设置：入网后无条件对账一次，之后 cron 每分钟一次
	cron_sync(true);
	tick(true, true);
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
	cron_sync(false);
	firewall_remove();
	local_rules_sync(false);
	unlink(TICK_LAST);
	unlink(TICK_FW_ERROR);
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
	direct_changed();
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
	direct_changed();
	return res;
}

// 喵窝页的主控信息（meowx-core panel mesh view：status 整理过的 access_scope / in_list / device_limit / servers，
// 在名单里时还有 devices 的 shared_devices）。老内核没有 view 子命令时退回只取 status。
// nodes = 当前运行配置里经喵窝连接的节点（生成运行配置时给它们写了 interface-name: tailscale0）
function panel() {
	const out = { success: true, settings: settings(), direct: direct_now(), panel_logged_in: panel_logged_in() };
	if (out.panel_logged_in) {
		let r = run_json('/usr/bin/meowx-core panel mesh view');
		if (r.json?.success === false && match(r.json.error ?? '', /unknown mesh command/)) {
			const st = run_json('/usr/bin/meowx-core panel mesh status');
			r = { json: st.json?.success === false ? st.json : { success: true, status: st.json } };
		}
		out.view = r.json ?? { success: false, error: r.out };
	}
	out.nodes = [];
	if (access(RUN_PROFILE)) {
		const r = run_json(`yq -M -o json '[.proxies[]? | select(.["interface-name"] == "${DEVICE}") | .name]' ${RUN_PROFILE}`);
		if (type(r.json) == 'array') {
			out.nodes = filter(r.json, (x) => type(x) == 'string');
		}
	}
	return out;
}

// 「白名单节点经喵窝连线」开关
function whitelist(value) {
	ensure_section();
	uci.set('meowx', 'mesh', 'whitelist_direct', value == '0' ? '0' : '1');
	uci.save('meowx');
	uci.commit('meowx');
	return { success: true, direct: direct_changed() };
}

// 拉订阅时 X-MeowX-Mesh 头的值（init 的 update_subscription 调）
function header(url, realtime_url) {
	return header_value(url, realtime_url, panel_hosts(), direct_now()) ?? '';
}

// 运行配置里的喵窝版节点（init 的 mixin_profile 调）
function nodes(mode) {
	let profile = null;
	try {
		profile = json(stdin.read('all') ?? 'null');
	} catch (e) {
		profile = null;
	}
	return mesh_nodes(profile, mode == 'on', DEVICE) ?? {};
}

// tailscale0 的喵窝地址 / 路由丢了：重启 tailscaled 重新配置（status 发现时在后台调，至多 HEAL_INTERVAL 一次）
function heal() {
	const s = settings();
	if (!s.enabled || !installed() || applying()) {
		return { success: true, skipped: true };
	}
	writefile(APPLY_FLAG, `${time()}\n`);
	cron_sync(!!panel_logged_in());   // 升级上来没有定时任务的，页面一打开就补上
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

// ---------- 设备中继：页面用 ----------

function core_json(args) {
	const r = run_json(`${CORE} panel mesh ${args}`);
	return type(r.json) == 'object' ? r.json : { success: false, error: r.out || '内核没有回应' };
}

// 中继一节：本机设备编号、主控里这台的中继配置与状态（relay get）、本机中继（LocalAPI）、版本、静态包
function relay() {
	const st = installed() ? ts_status() : null;
	const id = self_device_id(st);
	const version = tailscale_version();
	const out = {
		success: true,
		device_id: id,
		version: version,
		version_ok: version_at_least(version, RELAY_MIN_VERSION),
		min_version: RELAY_MIN_VERSION,
		ts_static: uci.get('meowx', 'mesh', 'ts_static') ?? null,
		static_version: TS_STATIC_VERSION,
		static_arch: static_arch(),
		last: tick_last(),
		local: st?.BackendState ? core_json(`relay local --socket ${TS_SOCKET}`) : null
	};
	if (id && panel_logged_in()) {
		out.relay = core_json(`relay get ${id}`);
	}
	return out;
}

function relay_set(raw) {
	let cfg;
	try {
		cfg = json(raw ?? '');
	} catch (e) {
		cfg = null;
	}
	if (type(cfg) != 'object' || type(cfg.enabled) != 'bool') {
		return { success: false, error: 'bad settings' };
	}
	const id = self_device_id();
	if (!id) {
		return { success: false, error: '本机还没有入网（tailscaled 不在运行）' };
	}
	const body = { enabled: cfg.enabled, port: int(cfg.port ?? 40000) };
	const eps = filter(map(type(cfg.static_endpoints) == 'array' ? cfg.static_endpoints : split(`${cfg.static_endpoints ?? ''}`, /[\s,，]+/), (x) => trim(`${x}`)), (x) => x != '');
	body.static_endpoints = eps;
	body.ddns_host = trim(`${cfg.ddns_host ?? ''}`);
	if (cfg.share == 'all' || cfg.share == 'self') {
		body.share = cfg.share;
	}
	const res = core_json(`relay set ${id} ${shell_quote(sprintf('%J', body))}`);
	if (res.success !== false) {
		log(`设备中继：${cfg.enabled ? '开启（UDP ' + body.port + '）' : '关闭'}`);
		system(`(/usr/bin/ucode -S ${SELF} tick force >/dev/null 2>&1 &)`);
	}
	return res;
}

// 主控汇总的路径（本机为一端）+ 上次 tick；主控读不到时带本机中继会话（只有外网地址与流量）。页面每 15 秒调一次，顺手在后台 tick
function paths() {
	const id = self_device_id();
	const out = { success: true, device_id: id, last: tick_last() };
	if (!id || !panel_logged_in()) {
		return out;
	}
	system(`(/usr/bin/ucode -S ${SELF} tick >/dev/null 2>&1 &)`);
	out.paths = core_json(`paths --device ${id}`);
	if (out.paths.success === false) {
		out.local = core_json(`relay local --socket ${TS_SOCKET}`);
	}
	return out;
}

// NAT 情况（tailscale netcheck；JSON 的警告打在 stderr）
function netcheck() {
	if (!installed()) {
		return { success: false, error: '还没有安装 tailscale' };
	}
	const p = popen(`${TAILSCALE} netcheck --format=json 2>/dev/null`);
	const raw = p ? trim(p.read('all') ?? '') : '';
	if (p) {
		p.close();
	}
	let r = null;
	try {
		r = json(raw || 'null');
	} catch (e) {
		r = null;
	}
	if (type(r) != 'object') {
		return { success: false, error: 'tailscale netcheck 没有结果' };
	}
	return {
		success: true,
		udp: r.UDP, ipv4: r.IPv4, ipv6: r.IPv6,
		global_v4: r.GlobalV4 || null, global_v6: r.GlobalV6 || null,
		mapping_varies: r.MappingVariesByDestIP, upnp: r.UPnP, pmp: r.PMP, pcp: r.PCP
	};
}

// ---------- MeowX 提供的 tailscale 静态包 ----------

function install_static() {
	if (access(INSTALL_FLAG)) {
		return { success: true, running: true };
	}
	if (!static_arch()) {
		return { success: false, error: '这台路由器的架构没有静态包' };
	}
	system(`mkdir -p /var/log/meowx /var/run; touch ${INSTALL_FLAG}; rm -f ${INSTALL_LOG}; ` +
		`( /usr/bin/ucode -S ${SELF} install_static_run > ${INSTALL_LOG} 2>&1; echo "exit $?" >> ${INSTALL_LOG}; rm -f ${INSTALL_FLAG} ) >/dev/null 2>&1 &`);
	log(`开始安装 MeowX 提供的 tailscale ${TS_STATIC_VERSION}`);
	return { success: true, running: true };
}

// 文件在 overlay 上实际占的空间（KB；在 /rom 里的删了也腾不出地方）
function overlay_kb(path) {
	const up = access('/overlay/upper') ? '/overlay/upper' + path : path;
	const st = stat(up);
	return st?.type == 'file' ? int(st.size / 1024) : 0;
}

function static_fail(msg) {
	print(msg + '\n');
	log('安装 tailscale 静态包失败：' + msg);
	unlink(TS_STATIC_TMP);
	exit(1);
}

// 后台跑（stdout 进安装日志）：1. 没装软件源的包先装（用它的 init 脚本、UCI 与升级保留规则）2. 按 manifest 下载、校验大小与 sha256、
// 试跑 3. 换掉 /usr/sbin/tailscaled，tailscale 链到它 4. 锁住软件源的包 5. UCI 记版本 6. 原来在跑就重启、对账
function install_static_run() {
	const pm = package_manager();
	const arch = static_arch();
	if (!arch) {
		static_fail('这台路由器的架构没有静态包');
	}
	if (!installed()) {
		if (!pm) {
			static_fail('找不到 opkg / apk');
		}
		print('先装软件源的 tailscale（要用它的启动脚本与配置）…\n');
		const r = run(pm == 'opkg' ? 'opkg update && opkg install tailscale' : 'apk update && apk add tailscale');
		print(r.out + '\n');
		if (r.code != 0 || !installed()) {
			static_fail('软件源的 tailscale 没装上');
		}
		system('/etc/init.d/tailscale stop >/dev/null 2>&1');
		if (!settings().enabled) {
			system('/etc/init.d/tailscale disable >/dev/null 2>&1');
		}
	}
	const base = `${TS_STATIC_BASE}/${TS_STATIC_VERSION}`;
	print(`读取 ${base}/manifest.json\n`);
	const mr = run_json(`curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 ${shell_quote(base + '/manifest.json')}`);
	const entry = mr.json?.files?.[arch];
	if (!entry?.sha256 || !entry?.size) {
		static_fail(`没拿到 ${arch} 的静态包信息：${substr(mr.out, 0, 200)}`);
	}
	const size_kb = int((entry.size + 1023) / 1024);
	const free_tmp = free_kb('/tmp');
	if (free_tmp < size_kb + 1024) {
		static_fail(sprintf('内存盘（/tmp）不够：下载要 %d MB，剩 %d MB', (size_kb + 1023) / 1024, free_tmp / 1024));
	}
	const free = free_kb('/overlay') || free_kb('/');
	const freed = overlay_kb(TAILSCALED) + overlay_kb(TAILSCALE);
	if (free + freed < size_kb + 512) {
		static_fail(sprintf('存储空间不够：静态包约 %d MB，换掉旧程序后还差 %d MB', (size_kb + 1023) / 1024, (size_kb + 512 - free - freed + 1023) / 1024));
	}
	print(sprintf('下载 %s（%d MB）…\n', entry.path, (size_kb + 1023) / 1024));
	unlink(TS_STATIC_TMP);
	const dr = run(`curl -fsSL --connect-timeout 15 --max-time 900 --retry 2 -o ${TS_STATIC_TMP} ${shell_quote(base + '/' + entry.path)}`);
	if (dr.code != 0) {
		static_fail('下载失败：' + dr.out);
	}
	if (stat(TS_STATIC_TMP)?.size != entry.size) {
		static_fail('下载的文件大小不对');
	}
	const sum = split(run(`sha256sum ${TS_STATIC_TMP}`).out, /[[:space:]]+/)[0];
	if (lc(sum ?? '') != lc(entry.sha256)) {
		static_fail('sha256 校验不过');
	}
	system(`chmod 755 ${TS_STATIC_TMP}`);
	const vr = run(`${TS_STATIC_TMP} --version`);
	if (vr.code != 0 || index(vr.out, TS_STATIC_VERSION) != 0) {
		static_fail('下载的程序在这台路由器上跑不起来（架构不对？）：' + substr(vr.out, 0, 200));
	}

	const was_running = system('/etc/init.d/tailscale running >/dev/null 2>&1') == 0;
	print('停掉 tailscaled、换上新程序…\n');
	system('/etc/init.d/tailscale stop >/dev/null 2>&1');
	// 空间够就先拷成 .new 再改名（中途失败旧程序还在）；不够才先删旧的
	let ok;
	if (free >= size_kb + 512) {
		ok = system(`cp ${TS_STATIC_TMP} ${TAILSCALED}.new && chmod 755 ${TAILSCALED}.new && mv -f ${TAILSCALED}.new ${TAILSCALED}`) == 0;
	} else {
		unlink(TAILSCALE);
		unlink(TAILSCALED);
		ok = system(`cp ${TS_STATIC_TMP} ${TAILSCALED} && chmod 755 ${TAILSCALED}`) == 0;
	}
	unlink(TS_STATIC_TMP);
	if (!ok) {
		unlink(`${TAILSCALED}.new`);
		print('换程序失败，重装软件源的 tailscale…\n');
		run(pm == 'opkg' ? 'opkg install --force-reinstall tailscale' : 'apk fix --reinstall tailscale');
		if (was_running) {
			system('/etc/init.d/tailscale start >/dev/null 2>&1');
		}
		static_fail('换程序失败（存储空间不够？），已重装软件源的 tailscale');
	}
	// 合体程序按程序名区分：叫 tailscale 时当命令行用
	unlink(TAILSCALE);
	symlink('tailscaled', TAILSCALE);

	// 锁住软件源的包，免得升级时被换回去
	if (pm == 'opkg') {
		system('opkg flag hold tailscale >/dev/null 2>&1');
	} else if (pm == 'apk') {
		const m = match(run('apk list --installed tailscale').out, /tailscale-([0-9][^[:space:]]*)/);
		if (m) {
			system(`apk add ${shell_quote('tailscale=' + m[1])} >/dev/null 2>&1`);
		}
	}
	ensure_section();
	uci.set('meowx', 'mesh', 'ts_static', TS_STATIC_VERSION);
	uci.save('meowx');
	uci.commit('meowx');
	log(`已装上 MeowX 提供的 tailscale ${TS_STATIC_VERSION}（${arch}）`);
	print(`已装上 tailscale ${TS_STATIC_VERSION}（${arch}）\n`);
	if (was_running) {
		system('/etc/init.d/tailscale start >/dev/null 2>&1');
		wait_daemon(20);
		if (wait_running(30)) {
			tick(true, false);
		}
	}
	exit(0);
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
// 给 init 脚本用的几个：直接打印文字
if (action == 'direct') {
	print(direct_now() ? 'on\n' : 'off\n');
	exit(0);
} else if (action == 'header') {
	print(header(ARGV[1], ARGV[2]) + '\n');
	exit(0);
}
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
} else if (action == 'panel') {
	result = panel();
} else if (action == 'whitelist') {
	result = whitelist(ARGV[1]);
} else if (action == 'nodes') {
	result = nodes(ARGV[1]);
} else if (action == 'tick') {
	result = tick(ARGV[1] == 'force', false);
} else if (action == 'cron') {
	const on = !!(settings().enabled && installed() && panel_logged_in());
	cron_sync(on);
	result = { success: true, cron: on };
} else if (action == 'relay') {
	result = relay();
} else if (action == 'relay_set') {
	result = relay_set(ARGV[1]);
} else if (action == 'paths') {
	result = paths();
} else if (action == 'netcheck') {
	result = netcheck();
} else if (action == 'install_static') {
	result = install_static();
} else if (action == 'install_static_run') {
	install_static_run();
} else {
	result = { success: false, error: 'usage: mesh_cli.uc status | save <JSON> | apply | install | leave | heal | panel | whitelist <0|1> | direct | header <url> [<realtime_url>] | nodes <on|off> | tick [force] | cron | relay | relay_set <JSON> | paths | netcheck | install_static' };
}
print(sprintf('%J\n', result));
