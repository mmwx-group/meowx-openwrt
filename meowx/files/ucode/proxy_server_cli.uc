#!/usr/bin/ucode

// 「绕过节点服务器地址」的命令行入口（init 脚本调用）：
//   apply    读运行配置，收齐节点的 server，域名经内核的 /dns/query 解析，整套换掉劫持表里的 proxy_server / proxy_server6，
//            把结果写进插件日志（内核刚起时等它的外部控制接口就绪，最多 30 秒）
//   fakeip   从 stdin 读配置（JSON），stdout 输出要合并进去的 dns.fake-ip-filter 补丁（JSON；不用改输出 {}）

'use strict';

import { readfile, writefile, open, popen, unlink, stdin, stat } from 'fs';
import { load_profile } from '/etc/meowx/ucode/include.uc';
import { collect_servers, classify, provider_file, answer_ips, controller_base, nft_script, fake_ip_filter_patch } from '/etc/meowx/ucode/proxy_server.uc';

const APP_LOG_PATH = '/var/log/meowx/app.log';
const TEMP_DIR = '/var/run/meowx';
// 同时发出的解析请求数（A、AAAA 各算一个），别一下子把小路由器打满
const BATCH = 16;
// 等内核外部控制接口就绪的次数（每次 1 秒）
const API_WAIT = 30;

function log(msg) {
	const t = localtime();
	const fd = open(APP_LOG_PATH, 'a');
	if (fd) {
		fd.write(sprintf('[%04d-%02d-%02d %02d:%02d:%02d] [Proxy] %s\n', t.year, t.mon, t.mday, t.hour, t.min, t.sec, msg));
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

function md5(text) {
	const out = read_command(`printf %s ${shell_quote(text)} | md5sum`);
	return out ? split(trim(out), ' ')[0] : null;
}

// proxy-provider 的缓存文件解成对象；文件不在、不是 YAML（如 base64 的节点链接列表）都给 null
function read_provider(provider) {
	const path = provider_file(provider, provider?.path ? null : md5(provider?.url ?? ''));
	if (!path || !stat(path)) {
		return null;
	}
	return parse_json(read_command(`yq -M -p yaml -o json ${shell_quote(path)} 2>/dev/null`));
}

function append(list, more) {
	for (let x in more) {
		push(list, x);
	}
	return list;
}

// 外部控制接口通了没有（密钥不对时回 401，也算通了，后面的解析会失败、记进日志）
function api_ready(api, auth) {
	const code = trim(read_command(`curl -s -m 2 ${api.tls ? '-k' : ''} ${auth} -o /dev/null -w '%{http_code}' ${shell_quote(api.base + '/version')} 2>/dev/null`) ?? '');
	return code == '200' || code == '401';
}

// 域名逐个经内核解析（A + AAAA），分批并发。返回 { ip4, ip6, unresolved }
function resolve_domains(api, auth, domains, dir) {
	const tasks = [];
	for (let d in domains) {
		push(tasks, { domain: d, qtype: 'A' });
		push(tasks, { domain: d, qtype: 'AAAA' });
	}
	const lines = [ '#!/bin/sh' ];
	for (let i = 0; i < length(tasks); i++) {
		const t = tasks[i];
		// 域名已按 [A-Za-z0-9_.-] 校验过，可以直接拼进地址
		const url = `${api.base}/dns/query?name=${t.domain}&type=${t.qtype}`;
		push(lines, `curl -s -m 5 ${api.tls ? '-k' : ''} ${auth} ${shell_quote(url)} > ${dir}/r.${i} 2>/dev/null &`);
		if ((i + 1) % BATCH == 0) {
			push(lines, 'wait');
		}
	}
	push(lines, 'wait', '');
	const script = `${dir}/resolve.sh`;
	writefile(script, join('\n', lines));
	system(['sh', script]);

	const ip4 = [], ip6 = [];
	const resolved = {};
	for (let i = 0; i < length(tasks); i++) {
		const t = tasks[i];
		const ips = answer_ips(parse_json(readfile(`${dir}/r.${i}`) ?? 'null'), t.qtype);
		for (let ip in ips) {
			push(t.qtype == 'A' ? ip4 : ip6, ip);
		}
		if (length(ips) > 0) {
			resolved[t.domain] = true;
		}
	}
	const unresolved = filter(domains, (d) => !resolved[d]);
	return { ip4: ip4, ip6: ip6, unresolved: unresolved };
}

function apply() {
	const profile = load_profile();
	const servers = collect_servers(profile, read_provider);
	const c = classify(servers);
	let ip4 = c.ip4, ip6 = c.ip6;
	let note = '';

	system(['mkdir', '-p', TEMP_DIR]);
	// 启动时与定时任务可能同时跑：一轮跑完再跑下一轮
	const lock = open(`${TEMP_DIR}/proxy_server.lock`, 'w');
	lock?.lock('x');
	const dir = trim(read_command(`mktemp -d ${TEMP_DIR}/proxy_server.XXXXXX`) ?? '');

	if (length(c.domains) > 0 && dir != '') {
		const api = controller_base(profile);
		if (!api) {
			note = `, ${length(c.domains)} domains skipped: no external controller in the profile`;
		} else {
			// 密钥写进临时目录（mktemp -d 建的，只有 root 能进）里的文件、经 -H @文件 带上，不出现在进程参数里
			let auth = '';
			const secret = profile?.secret;
			if (type(secret) == 'string' && secret != '') {
				writefile(`${dir}/header`, `Authorization: Bearer ${secret}\n`);
				auth = `-H @${dir}/header`;
			}
			let ready = false;
			for (let i = 0; i < API_WAIT; i++) {
				if (api_ready(api, auth)) {
					ready = true;
					break;
				}
				sleep(1000);
			}
			if (!ready) {
				note = `, ${length(c.domains)} domains skipped: the external controller is not reachable`;
			} else {
				const r = resolve_domains(api, auth, c.domains, dir);
				ip4 = uniq(append(append([], ip4), r.ip4));
				ip6 = uniq(append(append([], ip6), r.ip6));
				note = `, ${length(c.domains)} domains`;
				if (length(r.unresolved) > 0) {
					note += `, unresolved: ${join(' ', r.unresolved)}`;
				}
			}
		}
	}

	const nft_file = `${dir != '' ? dir : TEMP_DIR}/proxy_server.nft`;
	writefile(nft_file, nft_script(ip4, ip6));
	const ok = system(['nft', '-f', nft_file]) == 0;
	if (dir != '') {
		system(['rm', '-rf', dir]);
	} else {
		unlink(nft_file);
	}
	lock?.lock('u');
	lock?.close();

	if (ok) {
		log(`Bypass proxy server address: ${length(ip4)} IPv4 / ${length(ip6)} IPv6 from ${length(servers)} servers${note}.`);
	} else {
		log(`Bypass proxy server address: failed to update the nftables sets (is the hijack table there?).`);
	}
	return ok;
}

function fakeip() {
	const profile = parse_json(stdin.read('all') ?? 'null');
	const c = classify(collect_servers(profile, read_provider));
	printf('%J\n', fake_ip_filter_patch(profile, c.domains) ?? {});
}

switch (ARGV[0]) {
case 'apply':
	exit(apply() ? 0 : 1);
case 'fakeip':
	fakeip();
	break;
default:
	print('usage: proxy_server_cli.uc apply|fakeip\n');
	exit(1);
}
