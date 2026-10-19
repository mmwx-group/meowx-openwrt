#!/usr/bin/ucode

// GitHub 加速换算的单元测试（不装进包里）。在路由器上部署 /etc/meowx/ucode/ghproxy.uc 之后跑：
//   ucode -S ghproxy_test.uc
// 全部通过退出码 0，否则逐条打印失败的用例并退出 1

'use strict';

import { convert, restore, jsdelivr_path, normalize_mirror, mirror_type, test_url, rewrite_profile, pick_fastest, TEST_FILE } from '/etc/meowx/ucode/ghproxy.uc';

let passed = 0, failed = 0;

function eq(name, got, want) {
	if (sprintf('%J', got) == sprintf('%J', want)) {
		passed++;
	} else {
		failed++;
		printf('FAIL %s\n  got:  %J\n  want: %J\n', name, got, want);
	}
}

const P = { url: 'https://ghfast.top/', type: 'prefix' };
const PP = { url: 'https://example.com/gh/', type: 'prefix' };   // 带路径的前缀型（自定义）
const J = { url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr' };
const JF = { url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr', fallback: P };   // 自动选中 jsDelivr，release 附件走前缀型
const D = { url: 'https://raw.githubusercontent.com/', type: 'direct' };

// [ 输入, { 选中的加速地址: 期望输出 } ]
const cases = [
	// raw.githubusercontent.com
	[ 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs',
		PP: 'https://example.com/gh/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs',
		J: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs',
		JF: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs',
		D: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs' } ],
	[ 'https://raw.githubusercontent.com/u/r/refs/heads/main/a/b.yaml', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/u/r/refs/heads/main/a/b.yaml',
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/a/b.yaml' } ],
	[ 'https://raw.githubusercontent.com/u/r/refs/tags/v1.2/x.txt', {
		J: 'https://fastly.jsdelivr.net/gh/u/r@v1.2/x.txt' } ],
	[ 'https://raw.githubusercontent.com/u/r/HEAD/x.txt', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/u/r/HEAD/x.txt',
		J: 'https://fastly.jsdelivr.net/gh/u/r/x.txt' } ],
	[ 'https://raw.github.com/u/r/main/x.txt', {
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/x.txt',
		P: 'https://ghfast.top/https://raw.github.com/u/r/main/x.txt' } ],
	[ 'HTTPS://Raw.GitHubUserContent.com/u/r/main/x', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/u/r/main/x',
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/x' } ],
	// github.com/<u>/<r>/raw/…
	[ 'https://github.com/u/r/raw/main/rules/x.list', {
		P: 'https://ghfast.top/https://github.com/u/r/raw/main/rules/x.list',
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/rules/x.list' } ],
	[ 'https://github.com/u/r/raw/refs/heads/dev/x.list', {
		J: 'https://fastly.jsdelivr.net/gh/u/r@dev/x.list' } ],
	// release 附件：附件同步在 release 分支的仓库 + latest → jsDelivr 走分支
	[ 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb', {
		P: 'https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
		J: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
		D: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb' } ],
	[ 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat', {
		J: 'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat' } ],
	[ 'https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb', {
		J: 'https://fastly.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb' } ],
	// 同一个仓库的指定版本：分支里只有最新的，jsDelivr 换不了
	[ 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/20240101/geoip.dat', {
		J: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/20240101/geoip.dat',
		JF: 'https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/20240101/geoip.dat' } ],
	// 其它仓库的 release 附件（面板）：jsDelivr 换不了 → 原始地址；自动选中 jsDelivr 时走后备的前缀型
	[ 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip', {
		P: 'https://ghfast.top/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip',
		J: 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip',
		JF: 'https://ghfast.top/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip' } ],
	// 源码包
	[ 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip', {
		P: 'https://ghfast.top/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip',
		J: 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip' } ],
	[ 'https://codeload.github.com/MetaCubeX/metacubexd/zip/refs/heads/gh-pages', {
		P: 'https://ghfast.top/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip',
		J: 'https://codeload.github.com/MetaCubeX/metacubexd/zip/refs/heads/gh-pages',
		JF: 'https://ghfast.top/https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip' } ],
	[ 'https://codeload.github.com/u/r/tar.gz/v1.0', {
		P: 'https://ghfast.top/https://github.com/u/r/archive/v1.0.tar.gz' } ],
	// gist
	[ 'https://gist.githubusercontent.com/u/abc123/raw/x.yaml', {
		P: 'https://ghfast.top/https://gist.githubusercontent.com/u/abc123/raw/x.yaml',
		J: 'https://gist.githubusercontent.com/u/abc123/raw/x.yaml' } ],
	// 已经是 jsDelivr：先还原再换算
	[ 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat',
		J: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat',
		D: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat' } ],
	[ 'https://cdn.jsdelivr.net/gh/u/r/a/b.txt', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/u/r/HEAD/a/b.txt',
		J: 'https://fastly.jsdelivr.net/gh/u/r/a/b.txt' } ],
	// 已经是前缀型：去掉前缀再换算
	[ 'https://gh-proxy.com/https://github.com/u/r/releases/download/v1/f.zip', {
		P: 'https://ghfast.top/https://github.com/u/r/releases/download/v1/f.zip',
		J: 'https://github.com/u/r/releases/download/v1/f.zip',
		D: 'https://github.com/u/r/releases/download/v1/f.zip' } ],
	[ 'https://ghfast.top/https://raw.githubusercontent.com/u/r/main/x.yaml', {
		P: 'https://ghfast.top/https://raw.githubusercontent.com/u/r/main/x.yaml',
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/x.yaml' } ],
	[ 'https://mirror.example/github.com/u/r/raw/main/x', {
		P: 'https://ghfast.top/https://github.com/u/r/raw/main/x' } ],
	[ 'https://example.org/proxy/https:/raw.githubusercontent.com/u/r/main/x', {
		J: 'https://fastly.jsdelivr.net/gh/u/r@main/x' } ],
	// 不是 GitHub 内容：不动
	[ 'https://example.com/rules/github.yaml', { P: 'https://example.com/rules/github.yaml', J: 'https://example.com/rules/github.yaml', D: 'https://example.com/rules/github.yaml' } ],
	[ 'https://cdn.jsdelivr.net/npm/foo@1.0.0/x.js', { P: 'https://cdn.jsdelivr.net/npm/foo@1.0.0/x.js', J: 'https://cdn.jsdelivr.net/npm/foo@1.0.0/x.js' } ],
	[ 'https://ghfast.top/', { P: 'https://ghfast.top/' } ],
	// 带查询串 / 账号密码（可能是令牌）：不动
	[ 'https://raw.githubusercontent.com/u/r/main/x?token=abc', { P: 'https://raw.githubusercontent.com/u/r/main/x?token=abc', J: 'https://raw.githubusercontent.com/u/r/main/x?token=abc' } ],
	[ 'https://user:pw@raw.githubusercontent.com/u/r/main/x', { P: 'https://user:pw@raw.githubusercontent.com/u/r/main/x', J: 'https://user:pw@raw.githubusercontent.com/u/r/main/x' } ]
];

const sels = { P: P, PP: PP, J: J, JF: JF, D: D };
for (let c in cases) {
	for (let k, want in c[1]) {
		eq(`convert(${c[0]}, ${k})`, convert(c[0], sels[k]), want);
	}
}

// 不加速（null）一律原样
eq('convert(null sel)', convert('https://github.com/u/r/raw/main/x', null), 'https://github.com/u/r/raw/main/x');
eq('convert(non-string)', convert(null, P), null);

// restore / jsdelivr_path
eq('restore github', restore('https://github.com/u/r/releases/download/v1/x'), 'https://github.com/u/r/releases/download/v1/x');
eq('restore jsdelivr', restore('https://gcore.jsdelivr.net/gh/u/r@main/x'), 'https://raw.githubusercontent.com/u/r/main/x');
eq('restore non-github', restore('https://example.com/x'), null);
eq('restore bad', restore('not a url'), null);
eq('jsdelivr_path archive', jsdelivr_path('https://github.com/u/r/archive/main.zip'), null);

// 加速地址规范化与类型判断
eq('normalize add slash', normalize_mirror(' https://foo.example.com '), 'https://foo.example.com/');
eq('normalize keep path', normalize_mirror('https://foo.example.com/gh/'), 'https://foo.example.com/gh/');
eq('normalize port', normalize_mirror('http://10.0.0.1:8080'), 'http://10.0.0.1:8080/');
eq('normalize ftp', normalize_mirror('ftp://foo.example.com/'), null);
eq('normalize space', normalize_mirror('https://foo.example.com/a b'), null);
eq('normalize query', normalize_mirror('https://foo.example.com/?x=1'), null);
eq('normalize empty', normalize_mirror(''), null);
eq('type auto jsdelivr', mirror_type('https://gcore.jsdelivr.net/', 'auto'), 'jsdelivr');
eq('type auto prefix', mirror_type('https://ghfast.top/', 'auto'), 'prefix');
eq('type auto direct', mirror_type('https://raw.githubusercontent.com/', 'auto'), 'direct');
eq('type declared', mirror_type('https://my.jsdelivr.example/', 'prefix'), 'prefix');
eq('type declared jsdelivr', mirror_type('https://jsd.example.com/', 'jsdelivr'), 'jsdelivr');

// 测速地址
eq('test_url direct', test_url('https://raw.githubusercontent.com/', 'direct'), TEST_FILE);
eq('test_url jsdelivr', test_url('https://cdn.jsdelivr.net/', 'jsdelivr'), 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb.sha256sum');
eq('test_url prefix', test_url('https://gh-proxy.com/', 'prefix'), 'https://gh-proxy.com/' + TEST_FILE);

// 自动选最快
eq('pick none', pick_fastest([ { url: 'a', type: 'prefix', status: 'timeout', latency: null } ]), null);
eq('pick direct fastest', pick_fastest([
	{ url: 'https://raw.githubusercontent.com/', type: 'direct', status: 'ok', latency: 100 },
	{ url: 'https://ghfast.top/', type: 'prefix', status: 'ok', latency: 300 } ]), null);
eq('pick prefix', pick_fastest([
	{ url: 'https://raw.githubusercontent.com/', type: 'direct', status: 'timeout', latency: null },
	{ url: 'https://ghfast.top/', type: 'prefix', status: 'ok', latency: 300 },
	{ url: 'https://gh-proxy.com/', type: 'prefix', status: 'ok', latency: 200 } ]),
	{ url: 'https://gh-proxy.com/', type: 'prefix', latency: 200, fallback: null });
eq('pick jsdelivr with fallback', pick_fastest([
	{ url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr', status: 'ok', latency: 80 },
	{ url: 'https://cdn.jsdelivr.net/', type: 'jsdelivr', status: 'ok', latency: 90 },
	{ url: 'https://ghfast.top/', type: 'prefix', status: 'ok', latency: 500 },
	{ url: 'https://gh-proxy.com/', type: 'prefix', status: 'unreachable', latency: null },
	{ url: 'https://git.yylx.win/', type: 'prefix', status: 'ok', latency: 400 } ]),
	{ url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr', latency: 80, fallback: { url: 'https://git.yylx.win/', type: 'prefix' } });
eq('pick jsdelivr no prefix', pick_fastest([
	{ url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr', status: 'ok', latency: 80 },
	{ url: 'https://ghfast.top/', type: 'prefix', status: 'timeout', latency: null } ]),
	{ url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr', latency: 80, fallback: null });

// 改写运行配置
const cfg = {
	'external-ui': 'ui',
	'geox-url': { geoip: 'https://example.com/geoip.dat', mmdb: 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb' },
	'rule-providers': {
		'cn域名': { type: 'http', behavior: 'domain', url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs' },
		'own': { type: 'http', url: 'https://rules.example.com/own.yaml' },
		'local': { type: 'file', path: './x.yaml' },
		'private': { type: 'http', url: 'https://raw.githubusercontent.com/u/r/main/x?token=abc' }
	}
};
eq('rewrite prefix', rewrite_profile(cfg, P), {
	patch: {
		'external-ui-url': 'https://ghfast.top/https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip',
		'geox-url': {
			geosite: 'https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
			mmdb: 'https://ghfast.top/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb',
			asn: 'https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb'
		},
		'rule-providers': { 'cn域名': { url: 'https://ghfast.top/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs' } }
	},
	count: 5
});
eq('rewrite jsdelivr', rewrite_profile({ 'external-ui-url': 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip', 'rule-providers': cfg['rule-providers'] }, J), {
	patch: {
		'geox-url': {
			geosite: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat',
			mmdb: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb',
			geoip: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat',
			asn: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb'
		},
		'rule-providers': { 'cn域名': { url: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs' } }
	},
	count: 5
});
// 没开面板（没有 external-ui）就不补面板地址
eq('rewrite no ui', rewrite_profile({}, P).patch['external-ui-url'], null);
eq('rewrite off', rewrite_profile(cfg, null), { patch: {}, count: 0 });

printf('%d passed, %d failed\n', passed, failed);
exit(failed == 0 ? 0 : 1);
