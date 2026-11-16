#!/usr/bin/ucode

// 主控实时通道（入口即时切换 + 订阅自动更新，规格 miaomiaowuC/Design/entry-realtime.md §6 / §7）的外壳一侧。
// 入口覆盖、加密通道、回执、落盘都在内核里（meowx-core component/panelrt），这里只负责把通道配置交给内核、接内核的订阅变更回调：
//   apply          把登录的主控（meowx-core panel realtime-config）与没登录的主控的只读凭证（订阅应答头 mmwx-realtime，
//                  存在 UCI 订阅段的 realtime_url / realtime）交给内核（PUT /meowx/realtime），回调设成
//                  /etc/init.d/meowx subscription_changed；一个通道都没有就停掉（DELETE）。内核刚起来时等它的控制接口，最多 30 秒
//   changed [键]   内核的订阅变更回调（环境变量 MEOWX_SUB_BASE / MEOWX_SUB_KEY / MEOWX_SUB_REV）：重拉这个主控来的、
//                  键相符（键为空 = 这个主控来的全部）且 rev 与本地不同的订阅，推送触发的重拉带 mmwx-refresh: push；
//                  在用的那份由 refresh_subscription 重载
//   clear <主控>   退出登录：清掉这个主控推来的入口覆盖（DELETE /meowx/entries?source=）

'use strict';

import { readfile, writefile, open, popen } from 'fs';
import { cursor } from 'uci';
import { load_profile } from '/etc/meowx/ucode/include.uc';
import { controller_base } from '/etc/meowx/ucode/proxy_server.uc';

const APP_LOG_PATH = '/var/log/meowx/app.log';
const TEMP_DIR = '/var/run/meowx';
const API_WAIT = 30;
const HOOK = [ '/etc/init.d/meowx', 'subscription_changed' ];

function log(msg) {
	const t = localtime();
	const fd = open(APP_LOG_PATH, 'a');
	if (fd) {
		fd.write(sprintf('[%04d-%02d-%02d %02d:%02d:%02d] [Realtime] %s\n', t.year, t.mon, t.mday, t.hour, t.min, t.sec, msg));
		fd.close();
	}
}

function shell_quote(value) {
	return "'" + replace(`${value ?? ''}`, "'", "'\\''") + "'";
}

function read_command(cmd) {
	const p = popen(cmd);
	if (!p) {
		return null;
	}
	const out = p.read('all');
	p.close();
	return out;
}

function parse_json(text) {
	try {
		return json(text);
	} catch (e) {
		return null;
	}
}

// 主控地址的主机名（小写，IPv6 去方括号）；登录的主控地址与订阅应答头给的 master_url 写法可能不同，一律按主机名比
function host_of(url) {
	const m = match(lc(`${url ?? ''}`), /^[a-z]+:\/\/(\[[^\]]+\]|[^\/:?#]+)/);
	if (!m) {
		return null;
	}
	let host = m[1];
	if (substr(host, 0, 1) == '[') {
		host = substr(host, 1, length(host) - 2);
	}
	return host;
}

// 内核控制接口：地址、密钥头（密钥写进只有 root 能进的临时目录、经 -H @文件 带上，不出现在进程参数里）
function core_api() {
	const profile = load_profile();
	const api = controller_base(profile);
	if (!api) {
		return null;
	}
	system([ 'mkdir', '-p', TEMP_DIR ]);
	const dir = trim(read_command(`mktemp -d ${TEMP_DIR}/realtime.XXXXXX`) ?? '');
	if (dir == '') {
		return null;
	}
	let auth = '';
	const secret = profile?.secret;
	if (type(secret) == 'string' && secret != '') {
		writefile(`${dir}/header`, `Authorization: Bearer ${secret}\n`);
		auth = `-H @${dir}/header`;
	}
	return { base: api.base, tls: api.tls, dir: dir, auth: auth };
}

function api_done(api) {
	if (api?.dir) {
		system([ 'rm', '-rf', api.dir ]);
	}
}

// 回 HTTP 状态码（字符串）；body 先写进临时文件、经 --data @文件 发（里面有登录 token）
function api_call(api, method, path, body) {
	let data = '';
	if (body != null) {
		writefile(`${api.dir}/body.json`, sprintf('%J', body));
		data = `-H 'Content-Type: application/json' --data @${api.dir}/body.json`;
	}
	return trim(read_command(`curl -s -m 10 ${api.tls ? '-k' : ''} ${api.auth} -X ${method} ${data} -o /dev/null -w '%{http_code}' ${shell_quote(api.base + path)} 2>/dev/null`) ?? '');
}

function api_ready(api) {
	for (let i = 0; i < API_WAIT; i++) {
		const code = trim(read_command(`curl -s -m 2 ${api.tls ? '-k' : ''} ${api.auth} -o /dev/null -w '%{http_code}' ${shell_quote(api.base + '/version')} 2>/dev/null`) ?? '');
		if (code == '200' || code == '401') {
			return true;
		}
		sleep(1000);
	}
	return false;
}

// 通道计划：登录的主控用登录态；没登录的主控每个连一条只读通道（同一主控多份订阅时优先在用的那份的凭证）。
// subs 告诉内核本地手上每份订阅的 rev，免得它连上时把没变的也通知一遍
function plan() {
	const login = parse_json(read_command('/usr/bin/meowx-core panel realtime-config 2>/dev/null') || 'null');
	const channels = [];
	let login_host = null;
	if (type(login?.base) == 'string' && type(login?.token) == 'string' && login.token != '') {
		push(channels, { base: login.base, token: login.token });
		login_host = host_of(login.base);
	}
	const uci = cursor();
	uci.load('meowx');
	const active = uci.get('meowx', 'config', 'profile') ?? '';
	const rt = {};
	const subs = [];
	uci.foreach('meowx', 'subscription', (s) => {
		const base = s.realtime_url;
		const host = host_of(base);
		if (!host) {
			return;
		}
		const channel_base = host == login_host ? login.base : base;
		if (s.sub_key && s.sub_rev) {
			push(subs, { base: channel_base, key: s.sub_key, rev: s.sub_rev });
		}
		if (host == login_host || !s.realtime) {
			return;
		}
		if (!rt[host] || active == 'subscription:' + s['.name']) {
			rt[host] = { base: base, rt: s.realtime };
		}
	});
	for (let host, c in rt) {
		push(channels, c);
	}
	return { channels: channels, subs: subs };
}

function apply() {
	const api = core_api();
	if (!api) {
		log('No external controller in the profile, realtime channel is off.');
		return false;
	}
	if (!api_ready(api)) {
		api_done(api);
		log('The external controller is not reachable, realtime channel is not configured.');
		return false;
	}
	const p = plan();
	let code;
	if (length(p.channels) == 0) {
		code = api_call(api, 'DELETE', '/meowx/realtime');
		log('No panel to connect (not logged in and no read-only credential from subscriptions).');
	} else {
		code = api_call(api, 'PUT', '/meowx/realtime', { channels: p.channels, hook: { exec: HOOK }, subs: p.subs });
		const kinds = map(p.channels, (c) => host_of(c.base) + (c.token ? ' (account)' : ' (read-only)'));
		const note = code == '200' ? '' : ' — the core refused it (HTTP ' + code + '), the core may be too old';
		log('Realtime channel: ' + join(', ', kinds) + note + '.');
	}
	api_done(api);
	return code == '200' || code == '204';
}

// 重拉这个主控来的、键相符且 rev 不同的订阅（一个一个来：refresh_subscription 按订阅加锁，在用的那份会重载内核）
function changed(argv_key) {
	const base = getenv('MEOWX_SUB_BASE') ?? '';
	const key = getenv('MEOWX_SUB_KEY') ?? argv_key ?? '';
	const rev = getenv('MEOWX_SUB_REV') ?? '';
	const host = host_of(base);
	if (!host) {
		return false;
	}
	const uci = cursor();
	uci.load('meowx');
	const targets = [];
	uci.foreach('meowx', 'subscription', (s) => {
		if (host_of(s.realtime_url) != host && host_of(s.url) != host) {
			return;
		}
		if (key != '' && (s.sub_key != key || (rev != '' && s.sub_rev == rev))) {
			return;
		}
		push(targets, s['.name']);
	});
	if (length(targets) == 0) {
		return true;
	}
	log('Subscription changed on ' + host + (key != '' ? ' (' + key + ')' : '') + ', refresh: ' + join(' ', targets) + '.');
	for (let id in targets) {
		system(`SUBSCRIPTION_PUSH=1 /etc/init.d/meowx refresh_subscription ${shell_quote(id)} > /dev/null 2>&1`);
	}
	return true;
}

function clear(source) {
	const api = core_api();
	if (!api) {
		return false;
	}
	const code = api_call(api, 'DELETE', '/meowx/entries?source=' + replace(`${source ?? ''}`, /[^A-Za-z0-9._~:\/\[\]-]/g, ''));
	api_done(api);
	return code == '200';
}

switch (ARGV[0]) {
case 'apply':
	exit(apply() ? 0 : 1);
case 'changed':
	exit(changed(ARGV[1]) ? 0 : 1);
case 'clear':
	exit(clear(ARGV[1]) ? 0 : 1);
default:
	print('usage: realtime_cli.uc apply | changed [key] | clear <panel base>\n');
	exit(1);
}
