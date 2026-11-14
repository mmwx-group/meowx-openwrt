'use strict';

// 「绕过节点服务器地址」（代理配置 → 绕过），照 OpenClash 的「绕过服务器地址」（skip_proxy_address）：
// 当前配置里各节点的 server（proxies、proxy-providers 的缓存文件与 inline 里的）收进劫持表的
// proxy_server / proxy_server6 集合，局域网设备与路由器发往这些地址的流量不进内核——设备上自己也开着代理客户端时，
// 它连节点的流量不会被路由器再代理一层。域名经内核的 /dns/query 解析（proxy_server_cli.uc apply）。
// 这里只放纯函数，单测在 meowx/tests/proxy_server_test.uc。

export const RUN_DIR = '/etc/meowx/run';

function strip_brackets(s) {
	if (substr(s, 0, 1) == '[' && substr(s, -1) == ']') {
		return substr(s, 1, length(s) - 2);
	}
	return s;
};

// 'v4' / 'v6' / 'domain'；认不出（空、单个标签的本机名、带非法字符）给 null
export function server_kind(server) {
	if (type(server) != 'string') {
		return null;
	}
	const s = strip_brackets(trim(server));
	if (s == '') {
		return null;
	}
	const addr = iptoarr(s);
	if (addr) {
		return length(addr) == 4 ? 'v4' : 'v6';
	}
	if (match(s, /^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/)) {
		return 'domain';
	}
	return null;
};

export function servers_of(list) {
	const out = [];
	if (type(list) != 'array') {
		return out;
	}
	for (let p in list) {
		if (type(p) == 'object' && type(p.server) == 'string' && trim(p.server) != '') {
			push(out, trim(p.server));
		}
	}
	return out;
};

// proxy-provider 的缓存文件在哪：写了 path 按运行目录解（内核以 -d /etc/meowx/run 起）；
// 没写 path 的同内核的缺省位置 <运行目录>/proxies/<url 的 md5>（md5 由调用方算好传进来）
export function provider_file(provider, url_md5) {
	let path = provider?.path;
	if (type(path) == 'string' && path != '') {
		if (substr(path, 0, 1) == '/') {
			return path;
		}
		if (substr(path, 0, 2) == './') {
			path = substr(path, 2);
		}
		return `${RUN_DIR}/${path}`;
	}
	if (type(provider?.url) == 'string' && provider.url != '' && url_md5) {
		return `${RUN_DIR}/proxies/${url_md5}`;
	}
	return null;
};

// read_provider(provider)：读出并解好这个 provider 的缓存文件（对象），读不到给 null；传 null 只收 inline 的
export function collect_servers(profile, read_provider) {
	const all = servers_of(profile?.proxies);
	const providers = profile?.['proxy-providers'];
	if (type(providers) == 'object') {
		for (let name, provider in providers) {
			if (type(provider) != 'object') {
				continue;
			}
			let list = [];
			if (provider.type == 'inline') {
				list = servers_of(provider.payload);
			} else if (read_provider) {
				list = servers_of(read_provider(provider)?.proxies);
			}
			for (let s in list) {
				push(all, s);
			}
		}
	}
	return uniq(all);
};

// 分成 IPv4 / IPv6 / 要解析的域名（地址规整成标准写法，域名小写）
export function classify(servers) {
	const ip4 = [], ip6 = [], domains = [];
	for (let s in servers) {
		const kind = server_kind(s);
		const v = strip_brackets(trim(s));
		if (kind == 'v4') {
			push(ip4, arrtoip(iptoarr(v)));
		} else if (kind == 'v6') {
			push(ip6, arrtoip(iptoarr(v)));
		} else if (kind == 'domain') {
			push(domains, lc(v));
		}
	}
	return { ip4: uniq(ip4), ip6: uniq(ip6), domains: uniq(domains) };
};

// 内核 /dns/query 的应答里取地址：A 只要 IPv4、AAAA 只要 IPv6，CNAME 等跳过
export function answer_ips(reply, qtype) {
	const out = [];
	const answers = reply?.Answer;
	if (type(answers) != 'array') {
		return out;
	}
	for (let a in answers) {
		if (type(a?.data) != 'string') {
			continue;
		}
		const addr = iptoarr(a.data);
		if (!addr) {
			continue;
		}
		if ((qtype == 'A' && length(addr) == 4) || (qtype == 'AAAA' && length(addr) == 16)) {
			push(out, arrtoip(addr));
		}
	}
	return out;
};

// 内核的外部控制地址 → { base, tls }。0.0.0.0 / [::] / 只写端口的按本机回环连
export function controller_base(profile) {
	let addr = profile?.['external-controller'];
	let tls = false;
	if (type(addr) != 'string' || addr == '') {
		addr = profile?.['external-controller-tls'];
		tls = true;
	}
	if (type(addr) != 'string' || addr == '') {
		return null;
	}
	// 主机与端口按最后一个冒号分（IPv6 主机里也有冒号）；ucode 的 rindex 在冒号位于开头（只写端口）时给 -1，用正则
	const m = match(addr, /^(.*):([0-9]+)$/);
	if (!m) {
		return null;
	}
	let host = m[1];
	const port = m[2];
	if (host == '' || host == '0.0.0.0') {
		host = '127.0.0.1';
	} else if (host == '[::]' || host == '::') {
		host = '[::1]';
	} else if (index(host, ':') >= 0 && substr(host, 0, 1) != '[') {
		host = `[${host}]`;
	}
	return { base: `${tls ? 'https' : 'http'}://${host}:${port}`, tls: tls };
};

// 整套换掉两个集合（nft -f 一次提交，不会有一刻是空的）
export function nft_script(ip4, ip6) {
	let s = 'flush set inet meowx proxy_server\nflush set inet meowx proxy_server6\n';
	if (length(ip4) > 0) {
		s += `add element inet meowx proxy_server { ${join(', ', ip4)} }\n`;
	}
	if (length(ip6) > 0) {
		s += `add element inet meowx proxy_server6 { ${join(', ', ip6)} }\n`;
	}
	return s;
};

// 混入用：fake-ip 模式、过滤名单是黑名单（缺省）时，把节点域名并进 dns.fake-ip-filter——局域网设备向路由器查
// 节点域名时拿到真实地址，连过去才命中上面的绕过集合（拿着假地址照样进内核）。
// 返回要合并进配置的补丁（整份名单），不用改给 null
export function fake_ip_filter_patch(profile, domains) {
	const dns = profile?.dns;
	if (type(dns) != 'object' || dns['enhanced-mode'] != 'fake-ip') {
		return null;
	}
	if ((dns['fake-ip-filter-mode'] ?? 'blacklist') != 'blacklist') {
		return null;
	}
	const current = type(dns['fake-ip-filter']) == 'array' ? dns['fake-ip-filter'] : [];
	const merged = [];
	for (let x in current) {
		push(merged, x);
	}
	let added = 0;
	for (let d in domains) {
		if (index(merged, d) < 0) {
			push(merged, d);
			added++;
		}
	}
	if (added == 0) {
		return null;
	}
	return { dns: { 'fake-ip-filter': merged } };
};
