#!/usr/bin/ucode

// GitHub 加速的命令行入口（init 脚本与 LuCI 后端调用）：
//   apply   从 stdin 读运行配置的相关几项（JSON），按当前设置换算，stdout 输出要合并回配置的补丁（JSON）
//   test    由路由器逐个测各加速地址（并发 curl），结果写进缓存，输出状态（JSON）
//   status  输出预设列表、当前设置与缓存的测速结果（JSON），不测速
//   cron    每天一次（只在「自动选最快」时挂）：重测；原来选中的已经不可达、新选的又不一样时输出 reload

'use strict';

import { readfile, writefile, open, popen, unlink, stdin } from 'fs';
import { cursor } from 'uci';
import { PRESETS, DIRECT_URL, normalize_mirror, mirror_type, test_url, rewrite_profile, pick_fastest } from '/etc/meowx/ucode/ghproxy.uc';

const CACHE_PATH = '/etc/meowx/ghproxy.json';
const APP_LOG_PATH = '/var/log/meowx/app.log';
const TEMP_DIR = '/var/run/meowx';
// 自动选择的结果缓存多久（秒）：服务启动时缓存还新就不再测
const CACHE_TTL = 86400;
// 单个地址的测速超时（秒，同 OpenClash）
const TEST_TIMEOUT = 5;

const uci = cursor();
uci.load('meowx');

function log(msg) {
	const t = localtime();
	const fd = open(APP_LOG_PATH, 'a');
	if (fd) {
		fd.write(sprintf('[%04d-%02d-%02d %02d:%02d:%02d] [GitHub] %s\n', t.year, t.mon, t.mday, t.hour, t.min, t.sec, msg));
		fd.close();
	}
}

function shell_quote(value) {
	return "'" + replace(`${value ?? ''}`, "'", "'\\''") + "'";
}

function settings() {
	return {
		mode: uci.get('meowx', 'ghproxy', 'mode') || 'off',
		custom_url: uci.get('meowx', 'ghproxy', 'custom_url') || '',
		custom_type: uci.get('meowx', 'ghproxy', 'custom_type') || 'auto'
	};
}

// 测速的候选：直连 + 预设 + 填了的自定义地址
function candidates(s) {
	const list = [ { url: DIRECT_URL, type: 'direct' } ];
	for (let p in PRESETS) {
		push(list, { url: p.url, type: p.type });
	}
	const custom = normalize_mirror(s.custom_url);
	if (custom && length(filter(list, (c) => c.url == custom)) == 0) {
		push(list, { url: custom, type: mirror_type(custom, s.custom_type), custom: true });
	}
	return list;
}

// 候选列表的指纹：自定义地址改了，缓存就不算数
function candidates_key(list) {
	return join(' ', map(list, (c) => c.type + '=' + c.url));
}

function read_cache() {
	return json(readfile(CACHE_PATH) ?? 'null');
}

// 并发 curl 测各候选。测速进程挪进 meowx 服务的 cgroup：服务跑着时路由器自己发出的流量会被送进内核，
// 只有这个 cgroup 里的会被放行（同 meowx-core panel 的做法），测的才是直连这些加速地址的延迟
function speed_test(list) {
	const cg = uci.get('meowx', 'routing', 'cgroup_name') || 'meowx';
	const script = `${TEMP_DIR}/ghproxy-test.${hexenc(readfile('/dev/urandom', 4))}.sh`;
	system(['mkdir', '-p', TEMP_DIR]);
	writefile(script, join('\n', [
		'#!/bin/sh',
		`cg=/sys/fs/cgroup/services/${cg}`,
		'if [ -d "$cg" ]; then mkdir -p "$cg/ghproxy" 2>/dev/null && echo $$ > "$cg/ghproxy/cgroup.procs" 2>/dev/null; fi',
		`[ -d /sys/fs/cgroup/net_cls/${cg} ] && echo $$ > /sys/fs/cgroup/net_cls/${cg}/cgroup.procs 2>/dev/null`,
		`dir=$(mktemp -d ${TEMP_DIR}/ghproxy.XXXXXX) || exit 1`,
		'i=0',
		'for url in "$@"; do',
		'\ti=$((i + 1))',
		`\t( curl -s -L -m ${TEST_TIMEOUT} --connect-timeout ${TEST_TIMEOUT} -o "$dir/body.$i" -w '%{http_code} %{time_total}' "$url" > "$dir/w.$i" 2>/dev/null; echo $? > "$dir/rc.$i" ) &`,
		'done',
		'wait',
		'n=0',
		'while [ "$n" -lt "$i" ]; do',
		'\tn=$((n + 1))',
		'\tvalid=0',
		'\thead -c 64 "$dir/body.$n" 2>/dev/null | grep -q -E "^[0-9a-f]{64}$" && valid=1',
		'\techo "$n $(cat "$dir/rc.$n" 2>/dev/null || echo 99) $(cat "$dir/w.$n" 2>/dev/null) $valid"',
		'done',
		'rm -rf "$dir"',
		''
	]));
	const urls = join(' ', map(list, (c) => shell_quote(test_url(c.url, c.type))));
	const process = popen(`sh ${script} ${urls}; rmdir /sys/fs/cgroup/services/${cg}/ghproxy 2>/dev/null`);
	const results = map(list, (c) => ({ url: c.url, type: c.type, custom: c.custom ?? false, latency: null, status: 'unreachable' }));
	if (process) {
		for (let line = process.read('line'); length(line); line = process.read('line')) {
			// 序号 curl 退出码 HTTP 状态码 耗时秒 内容是否正确
			const f = split(trim(line), ' ');
			const r = results[int(f[0]) - 1];
			if (!r) {
				continue;
			}
			const rc = int(f[1]);
			const code = int(f[2]);
			if (rc == 0 && code >= 200 && code < 300 && f[4] == '1') {
				r.status = 'ok';
				r.latency = int(+f[3] * 1000) || 1;
			} else if (rc == 28) {
				r.status = 'timeout';
			}
		}
		process.close();
	}
	unlink(script);
	return results;
}

// 测一轮并写缓存（加锁：启动、定时任务、界面上的「测速」不会同时跑两轮）
function run_test(s) {
	const list = candidates(s);
	const lock = open(`${TEMP_DIR}/ghproxy.lock`, 'w');
	lock?.lock('x');
	const results = speed_test(list);
	const auto = pick_fastest(results);
	const cache = { tested_at: time(), key: candidates_key(list), results: results, auto: auto };
	writefile(CACHE_PATH, sprintf('%J\n', cache));
	lock?.lock('u');
	lock?.close();
	const ok = length(filter(results, (r) => r.status == 'ok'));
	log(`Speed test: ${ok}/${length(results)} reachable${auto ? `, fastest: ${auto.url} (${auto.latency} ms)` : ''}.`);
	return cache;
}

// 当前设置实际用哪个加速地址：{ url, type, fallback } 或 null（不加速）。
// 「自动选最快」时用缓存里的结果，缓存没有 / 过期 / 候选变了才测
function resolve(s, quiet) {
	if (s.mode == 'off' || s.mode == '') {
		return null;
	}
	if (s.mode == 'auto') {
		let cache = read_cache();
		const key = candidates_key(candidates(s));
		if (!cache || cache.key != key || time() - (cache.tested_at ?? 0) >= CACHE_TTL || time() < (cache.tested_at ?? 0)) {
			quiet || log('Auto select: testing mirrors...');
			cache = run_test(s);
		}
		if (!cache.auto) {
			if (length(filter(cache.results ?? [], (r) => r.status == 'ok')) == 0) {
				quiet || log('Auto select: all mirrors are unreachable, use direct.');
			} else {
				quiet || log('Auto select: direct is the fastest, no mirror.');
			}
			return null;
		}
		quiet || log(`Auto select: ${cache.auto.url} (${cache.auto.latency} ms${cache.auto.fallback ? `, release files via ${cache.auto.fallback.url}` : ''}).`);
		return { url: cache.auto.url, type: cache.auto.type, fallback: cache.auto.fallback };
	}
	if (s.mode == 'custom') {
		const u = normalize_mirror(s.custom_url);
		if (!u) {
			quiet || log('Custom mirror address is invalid, use direct.');
			return null;
		}
		const t = mirror_type(u, s.custom_type);
		return t == 'direct' ? null : { url: u, type: t, fallback: null };
	}
	// 预设地址（或以后版本删掉的预设：按地址判断类型）
	const u = normalize_mirror(s.mode);
	if (!u) {
		return null;
	}
	const preset = filter(PRESETS, (p) => p.url == u)[0];
	const t = preset?.type ?? mirror_type(u, 'auto');
	return t == 'direct' ? null : { url: u, type: t, fallback: null };
}

function status(cache) {
	const s = settings();
	const res = {
		mode: s.mode,
		direct: DIRECT_URL,
		presets: PRESETS,
		tested_at: cache?.tested_at,
		results: cache?.results ?? [],
		auto: cache?.auto
	};
	return res;
}

const command = ARGV[0];
const s = settings();

if (command == 'apply') {
	const cfg = json(stdin.read('all') || 'null');
	const sel = resolve(s, false);
	if (sel == null) {
		print('{}\n');
	} else {
		const r = rewrite_profile(cfg, sel);
		log(`Use ${sel.type == 'jsdelivr' ? 'jsDelivr' : 'mirror'} ${sel.url}, rewrote ${r.count} GitHub URL(s).`);
		printf('%J\n', r.patch);
	}
} else if (command == 'test') {
	printf('%J\n', status(run_test(s)));
} else if (command == 'status') {
	printf('%J\n', status(read_cache()));
} else if (command == 'cron') {
	if (s.mode == 'auto') {
		const before = read_cache()?.auto;
		const cache = run_test(s);
		const still_ok = before == null ? true : length(filter(cache.results, (r) => r.url == before.url && r.status == 'ok')) > 0;
		if (!still_ok && cache.auto?.url != before?.url) {
			log(`Previous mirror ${before.url} is unreachable now, switch to ${cache.auto?.url ?? 'direct'}.`);
			print('reload\n');
		}
	}
} else {
	warn('usage: ghproxy_cli.uc apply|test|status|cron\n');
	exit(1);
}
