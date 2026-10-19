// GitHub 加速：把配置里指向 GitHub 内容的地址（面板、Geo 数据、规则集）换成加速地址。
// 只做地址换算，不碰文件、不联网，方便单测（测试在仓库的 meowx/tests/ghproxy_test.uc）。
//
// 加速地址分两类（换算规则参照 OpenClash 的 yml_rules_change.sh / openclash_geo.sh / openclash.lua）：
//   prefix   前缀型：<加速地址><原始完整地址>，如 https://ghfast.top/https://github.com/u/r/releases/download/…
//            raw / release 附件 / 源码包都能代理
//   jsdelivr jsDelivr：<加速地址>gh/<用户>/<仓库>@<分支>/<路径>，只能代理仓库里的文件，不能代理 release 附件与源码包；
//            少数仓库把 release 附件同步到了 release 分支（同 OpenClash 对 Loyalsoldier / xishang0128 的处理），按分支换算
//   direct   不加速：https://raw.githubusercontent.com/（测速表里的「直连」一行）

'use strict';

// 测速用的小文件：geoip.metadb 的校验和（79 字节，内容是 64 位十六进制），jsDelivr 与前缀型都能代理，
// 内容能校验——有的加速地址出错时回 200 + 一张网页
export const TEST_FILE = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb.sha256sum';

export const DIRECT_URL = 'https://raw.githubusercontent.com/';

export const PRESETS = [
	{ url: 'https://fastly.jsdelivr.net/', type: 'jsdelivr' },
	{ url: 'https://testingcf.jsdelivr.net/', type: 'jsdelivr' },
	{ url: 'https://cdn.jsdelivr.net/', type: 'jsdelivr' },
	{ url: 'https://ghfast.top/', type: 'prefix' },
	{ url: 'https://git.yylx.win/', type: 'prefix' },
	{ url: 'https://cdn.akaere.online/', type: 'prefix' },
	{ url: 'https://gh-proxy.com/', type: 'prefix' },
	{ url: 'https://gh.jasonzeng.dev/', type: 'prefix' },
	{ url: 'https://ghproxy.monkeyray.net/', type: 'prefix' },
	{ url: 'https://down.mxw.xx.kg/', type: 'prefix' },
	{ url: 'https://github.tbap.top/', type: 'prefix' },
	{ url: 'https://ghm.078465.xyz/', type: 'prefix' },
	{ url: 'https://gh.monlor.com/', type: 'prefix' },
	{ url: 'https://gh.idayer.com/', type: 'prefix' }
];

// 内核（meowC 的 mihomo）不写 geox-url / external-ui-url 时的缺省下载地址（config/config.go），
// 开了加速时补上再换算，否则这几样照样直连 GitHub
export const GEOX_DEFAULTS = {
	geosite: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
	mmdb: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
	geoip: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
	asn: 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb'
};
export const UI_DEFAULT = 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip';

const GITHUB_HOSTS = [
	'github.com',
	'raw.githubusercontent.com',
	'raw.github.com',
	'gist.githubusercontent.com',
	'gist.github.com',
	'codeload.github.com',
	'objects.githubusercontent.com'
];

// release 附件同步在某个分支里的仓库（键小写）：releases/latest/download/<文件> → jsDelivr gh/<仓库>@<分支>/<文件>
const RELEASE_BRANCHES = {
	'metacubex/meta-rules-dat': 'release',
	'loyalsoldier/v2ray-rules-dat': 'release',
	'xishang0128/geoip': 'release'
};

// 拆成 主机（小写）+ 主机之后的部分（路径 + 查询）；带账号密码（user:pass@）的也拆出来，好跳过
function split_url(u) {
	const m = match(u ?? '', /^[Hh][Tt][Tt][Pp][Ss]?:\/\/([^\/?#]*)(.*)$/);
	if (!m) {
		return null;
	}
	let authority = m[1];
	const at = index(authority, '@');
	const userinfo = at >= 0;
	if (userinfo) {
		authority = substr(authority, at + 1);
	}
	// 去掉端口（GitHub 与 jsDelivr 都不带端口，带了也不影响判断）
	const host = lc(replace(authority, /:[0-9]+$/, ''));
	return { host: host, rest: m[2], userinfo: userinfo };
}

function is_github_host(host) {
	return index(GITHUB_HOSTS, host) >= 0;
}

// 加速地址规范化：只认 http(s)://主机[/路径]，结尾补 /；不合法返回 null
export function normalize_mirror(u) {
	u = trim(u ?? '');
	if (!match(u, /^[Hh][Tt][Tt][Pp][Ss]?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?(\/[^[:space:]?#]*)?$/)) {
		return null;
	}
	return substr(u, -1) == '/' ? u : u + '/';
};

// 加速地址的类型：declared 是用户选的（prefix / jsdelivr），auto 或没选时按地址判断（同 OpenClash：主机带 jsdelivr 的是 jsDelivr 型）
export function mirror_type(u, declared) {
	if (declared == 'prefix' || declared == 'jsdelivr') {
		return declared;
	}
	const p = split_url(u);
	if (!p) {
		return null;
	}
	if (p.host == 'raw.githubusercontent.com' && (p.rest == '' || p.rest == '/')) {
		return 'direct';
	}
	if (index(p.host, 'jsdelivr') >= 0) {
		return 'jsdelivr';
	}
	return 'prefix';
};

// 还原成原始 GitHub 地址：本来就是 GitHub 的原样返回；jsDelivr 的 gh/ 地址换回 raw.githubusercontent.com；
// 前缀型（<任意主机>[/路径]/[https://]<GitHub 主机>/…）去掉前缀。不是 GitHub 内容返回 null
export function restore(u) {
	const p = split_url(u);
	if (!p) {
		return null;
	}
	if (is_github_host(p.host)) {
		return 'https://' + p.host + p.rest;
	}
	if (index(p.host, 'jsdelivr') >= 0) {
		// /gh/<用户>/<仓库>[@<版本>]/<路径>；没写版本 = 默认分支（raw 上写 HEAD）
		const m = match(p.rest, /^\/gh\/([^\/@]+)\/([^\/@]+)(@([^\/]+))?\/(.+)$/);
		if (!m) {
			return null;
		}
		return `https://raw.githubusercontent.com/${m[1]}/${m[2]}/${m[4] ?? 'HEAD'}/${m[5]}`;
	}
	// 前缀型：按段找第一个 GitHub 主机（可能写成 https:/、https://，也可能省掉协议头）
	const segs = split(p.rest, '/');
	for (let i = 1; i < length(segs); i++) {
		let j = i;
		if (lc(segs[j]) == 'https:' || lc(segs[j]) == 'http:') {
			j++;
			while (j < length(segs) && segs[j] == '') {
				j++;
			}
		}
		if (j < length(segs) - 1 && is_github_host(lc(segs[j]))) {
			return 'https://' + lc(segs[j]) + '/' + join('/', slice(segs, j + 1));
		}
	}
	return null;
};

// 原始地址在 jsDelivr 上的路径（<用户>/<仓库>@<分支>/<路径>）；jsDelivr 代理不了的返回 null
export function jsdelivr_path(orig) {
	const p = split_url(orig);
	if (!p) {
		return null;
	}
	let m, user, repo, ref, path;
	if (p.host == 'raw.githubusercontent.com' || p.host == 'raw.github.com') {
		// /<用户>/<仓库>/<分支>/<路径>，分支也可能写成 refs/heads/<分支>、refs/tags/<标签>
		m = match(p.rest, /^\/([^\/]+)\/([^\/]+)\/(refs\/(heads|tags)\/)?([^\/]+)\/(.+)$/);
		if (m) {
			user = m[1]; repo = m[2]; ref = m[5]; path = m[6];
		}
	} else if (p.host == 'github.com') {
		// /<用户>/<仓库>/raw/<分支>/<路径>
		m = match(p.rest, /^\/([^\/]+)\/([^\/]+)\/raw\/(refs\/(heads|tags)\/)?([^\/]+)\/(.+)$/);
		if (m) {
			user = m[1]; repo = m[2]; ref = m[5]; path = m[6];
		} else {
			// release 附件：只有附件同步到分支里的仓库、且是最新版（latest）才换得过去
			m = match(p.rest, /^\/([^\/]+)\/([^\/]+)\/releases\/(latest\/download|download\/latest)\/([^\/]+)$/);
			const branch = m ? RELEASE_BRANCHES[lc(m[1] + '/' + m[2])] : null;
			if (branch) {
				user = m[1]; repo = m[2]; ref = branch; path = m[4];
			}
		}
	}
	if (!user) {
		return null;
	}
	// jsDelivr 不认 @HEAD：不写版本就是默认分支
	return ref == 'HEAD' ? `${user}/${repo}/${path}` : `${user}/${repo}@${ref}/${path}`;
};

// 原始地址给前缀型用的写法：codeload 的源码包换成等价的 github.com/…/archive/…（加速站普遍只认 github.com 的写法）
function prefix_form(orig) {
	const m = match(orig, /^https:\/\/codeload\.github\.com\/([^\/]+)\/([^\/]+)\/(zip|tar\.gz)\/(.+)$/);
	if (m) {
		return `https://github.com/${m[1]}/${m[2]}/archive/${m[4]}.${m[3]}`;
	}
	return orig;
}

// 按选中的加速地址换算一个地址。sel = { url, type, fallback }：fallback 是 jsDelivr 代理不了时改用的前缀型加速地址
// （只有「自动选最快」选中 jsDelivr 时才有，没有就用原始地址）。
// 不是 GitHub 内容、带查询串或账号密码（可能是令牌，经第三方加速站会泄漏）的原样返回
export function convert(u, sel) {
	if (type(u) != 'string' || sel == null) {
		return u;
	}
	const orig = restore(u);
	if (orig == null) {
		return u;
	}
	const p = split_url(u);
	if (p.userinfo || index(u, '?') >= 0) {
		return u;
	}
	if (sel.type == 'direct') {
		return orig;
	}
	if (sel.type == 'jsdelivr') {
		const path = jsdelivr_path(orig);
		if (path != null) {
			return sel.url + 'gh/' + path;
		}
		return sel.fallback ? convert(orig, sel.fallback) : orig;
	}
	return sel.url + prefix_form(orig);
};

// 改写运行配置：cfg 是配置里 external-ui / external-ui-url / geox-url / rule-providers 这几项（JSON），
// 返回要合并回去的补丁（只含变了的地址）与改了几处。proxy-providers 与订阅地址不碰（可能带令牌）
export function rewrite_profile(cfg, sel) {
	const patch = {};
	let count = 0;
	if (sel == null || type(cfg) != 'object') {
		return { patch: patch, count: count };
	}
	const ui_url = cfg['external-ui-url'];
	const ui_src = (type(ui_url) == 'string' && ui_url != '') ? ui_url : (cfg['external-ui'] ? UI_DEFAULT : null);
	if (ui_src != null) {
		const next = convert(ui_src, sel);
		if (next != ui_url) {
			patch['external-ui-url'] = next;
			count++;
		}
	}
	const geox = type(cfg['geox-url']) == 'object' ? cfg['geox-url'] : {};
	for (let key in [ 'geosite', 'mmdb', 'geoip', 'asn' ]) {
		const current = geox[key];
		const src = (type(current) == 'string' && current != '') ? current : GEOX_DEFAULTS[key];
		const next = convert(src, sel);
		if (next != current) {
			patch['geox-url'] ??= {};
			patch['geox-url'][key] = next;
			count++;
		}
	}
	const providers = cfg['rule-providers'];
	if (type(providers) == 'object') {
		for (let name, provider in providers) {
			if (type(provider) != 'object' || type(provider.url) != 'string' || provider.url == '') {
				continue;
			}
			const next = convert(provider.url, sel);
			if (next != provider.url) {
				patch['rule-providers'] ??= {};
				patch['rule-providers'][name] = { url: next };
				count++;
			}
		}
	}
	return { patch: patch, count: count };
};

// 某个加速地址测速用的地址
export function test_url(mirror, mirror_type) {
	return convert(TEST_FILE, { url: mirror, type: mirror_type });
};

// 测速结果里挑一个：延迟最低且可达的；它是 jsDelivr 时另挑最快的前缀型当后备（release 附件用）。
// 最快的是直连、或全部不可达时返回 null（不加速）
export function pick_fastest(results) {
	const ok = filter(results ?? [], (r) => r.status == 'ok' && r.latency != null);
	if (length(ok) == 0) {
		return null;
	}
	const sorted = sort(ok, (a, b) => a.latency - b.latency);
	const best = sorted[0];
	if (best.type == 'direct') {
		return null;
	}
	let fallback = null;
	if (best.type == 'jsdelivr') {
		for (let r in sorted) {
			if (r.type == 'prefix') {
				fallback = { url: r.url, type: 'prefix' };
				break;
			}
		}
	}
	return { url: best.url, type: best.type, latency: best.latency, fallback: fallback };
};
