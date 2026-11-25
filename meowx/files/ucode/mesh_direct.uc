'use strict';

// 喵窝白名单直连（规格 miaomiaowuC/Design/meshnet-whitelist-direct.md §B，五端共用）：有入口 IP 白名单的服务器加入喵窝后，
// 主控给喵窝名单里的账号下发「喵窝版」节点（`_mmwx-mesh: true`，server 是那台服务器的喵窝地址 100.64.x.y），
// 客户端经喵窝连它，不占服务器的白名单名额。路由器上喵窝是官方 tailscaled、内核网卡 tailscale0，内核连 100.64.x.y
// 照路由表就走 tailscale0，不需要 dialer-proxy（内核编译时去掉了 tailscale 出站，写了反而报错）。
// 这里只放纯函数，单测在 meowx/tests/mesh_direct_test.uc；命令行入口在 mesh_cli.uc（direct / header / nodes）。

// 喵窝的内核网卡（mesh_cli.uc 的 DEVICE）
export const MESH_DEVICE = 'tailscale0';

// 地址里的主机名（小写，IPv6 带方括号）；不是 scheme://host 形式给 null
export function host_of(url) {
	if (type(url) != 'string') {
		return null;
	}
	const m = match(url, /^[A-Za-z][A-Za-z0-9+.-]*:\/\/(\[[^\]]+\]|[^\/:?#]+)/);
	return m ? lc(m[1]) : null;
};

// 这份订阅是不是登录的主控的：订阅地址的主机是主控域名或主控的订阅域名（panel.json 的 base / sub_base；老内核没有 sub_base），
// 或者上次拉取时主控给的实时通道地址（mmwx-realtime-url，订阅域名与主控不同时也是主控地址）就是这个主控。
// 别家机场（包括别的妙妙屋主控）的订阅不算
export function panel_subscription(url, realtime_url, panel) {
	const base = host_of(panel?.base);
	if (!base) {
		return false;
	}
	const host = host_of(url);
	if (host && (host == base || host == host_of(panel?.sub_base))) {
		return true;
	}
	return host_of(realtime_url) == base;
};

// 白名单直连这一刻生效没有（拉订阅时告诉主控 on / off、生成运行配置时留不留喵窝版节点，同一个判断）：
// 喵窝开关开着、「白名单节点经喵窝连线」没关、登录着主控、上一次入网成功（mesh.json 有控制地址、没有错误）。
// 入网成功就说明账号在喵窝名单里（主控不在名单时 apply 会失败）
export function direct_on(s) {
	return !!(s?.enabled && s?.whitelist !== false && s?.logged_in && s?.state?.control_url && !s?.state?.error);
};

// 拉这份订阅时 X-MeowX-Mesh 头的值：本主控的订阅给 'on' / 'off'，别家的给 null（不带这个头）
export function header_value(url, realtime_url, panel, on) {
	if (!panel_subscription(url, realtime_url, panel)) {
		return null;
	}
	return on ? 'on' : 'off';
};

// 组里除了 proxies 还有别的成员来源（proxy-provider、include-all…）：proxies 摘空了也不用补 DIRECT
function has_other_source(group) {
	if (type(group.use) == 'array' && length(group.use) > 0) {
		return true;
	}
	return !!(group['include-all'] || group['include-all-proxies'] || group['include-all-providers']);
};

// 规则的目标（出站）：按顶层逗号切开（括号里的逗号不算，逻辑规则的条件写在括号里），MATCH / FINAL 取第二段、其余取第三段；
// 认不出给 null
export function rule_target(rule) {
	if (type(rule) != 'string') {
		return null;
	}
	const fields = [];
	let depth = 0, start = 0;
	for (let i = 0; i < length(rule); i++) {
		const c = substr(rule, i, 1);
		if (c == '(') {
			depth++;
		} else if (c == ')') {
			depth--;
		} else if (c == ',' && depth == 0) {
			push(fields, trim(substr(rule, start, i - start)));
			start = i + 1;
		}
	}
	push(fields, trim(substr(rule, start)));
	const kind = uc(fields[0]);
	if (kind == 'MATCH' || kind == 'FINAL') {
		return length(fields) >= 2 ? fields[1] : null;
	}
	return length(fields) >= 3 ? fields[2] : null;
};

// 删掉目标是 removed 里节点的规则；一条都没删给 null
function drop_rules(list, removed) {
	if (type(list) != 'array') {
		return null;
	}
	const kept = filter(list, (r) => {
		const t = rule_target(r);
		return !(t != null && removed[t]);
	});
	return length(kept) == length(list) ? null : kept;
};

// 运行配置里处理喵窝版节点。profile 至少有 proxies（与 proxy-groups）；返回要合并回去的补丁 { proxies, ['proxy-groups'] }
// （列表整个替换），没有带 `_mmwx-mesh` 字段的节点时返回 null（不用改）。
//   on：保留，去掉 `_mmwx-mesh`，没写 interface-name 的写成 device（混入配置设了出站接口时全局 interface-name 会把连接绑到 WAN 上，
//       按节点写的优先；节点自己写了的不覆盖）
//   off：拿掉这些节点，并从各代理组的 proxies 里摘掉；组因此变空、又没有别的成员来源时补 DIRECT；rules 与 sub-rules 里
//        目标是这些节点的规则整行删掉（含 AND / OR / NOT 逻辑规则；删，不改成 DIRECT——内核遇到指向不存在的节点的规则会拒载整份配置）
// 写了 `_mmwx-mesh` 但不是 true 的节点照常保留，只去掉这个字段
export function mesh_nodes(profile, on, device) {
	const proxies = profile?.proxies;
	if (type(proxies) != 'array') {
		return null;
	}
	let found = false;
	for (let i = 0; i < length(proxies); i++) {
		if (type(proxies[i]) == 'object' && ('_mmwx-mesh' in proxies[i])) {
			found = true;
		}
	}
	if (!found) {
		return null;
	}
	const out = [];
	const removed = {};
	let removed_count = 0;
	for (let i = 0; i < length(proxies); i++) {
		const p = proxies[i];
		if (type(p) != 'object' || !('_mmwx-mesh' in p)) {
			push(out, p);
			continue;
		}
		const mesh = p['_mmwx-mesh'] === true;
		if (mesh && !on) {
			if (type(p.name) == 'string') {
				removed[p.name] = true;
				removed_count++;
			}
			continue;
		}
		const q = {};
		for (let k in p) {
			if (k != '_mmwx-mesh') {
				q[k] = p[k];
			}
		}
		if (mesh && device && (q['interface-name'] == null || q['interface-name'] == '')) {
			q['interface-name'] = device;
		}
		push(out, q);
	}
	const patch = { proxies: out };
	const groups = profile['proxy-groups'];
	if (removed_count > 0 && type(groups) == 'array') {
		const next = [];
		let changed = false;
		for (let i = 0; i < length(groups); i++) {
			const g = groups[i];
			if (type(g) != 'object' || type(g.proxies) != 'array') {
				push(next, g);
				continue;
			}
			let members = filter(g.proxies, (m) => !(type(m) == 'string' && removed[m]));
			if (length(members) == length(g.proxies)) {
				push(next, g);
				continue;
			}
			if (length(members) == 0 && !has_other_source(g)) {
				members = [ 'DIRECT' ];
			}
			const ng = {};
			for (let k in g) {
				ng[k] = g[k];
			}
			ng.proxies = members;
			push(next, ng);
			changed = true;
		}
		if (changed) {
			patch['proxy-groups'] = next;
		}
	}
	if (removed_count > 0) {
		const rules = drop_rules(profile.rules, removed);
		if (rules != null) {
			patch.rules = rules;
		}
		const subs = profile['sub-rules'];
		if (type(subs) == 'object') {
			const next = {};
			let changed = false;
			for (let name in subs) {
				const kept = drop_rules(subs[name], removed);
				next[name] = kept ?? subs[name];
				if (kept != null) {
					changed = true;
				}
			}
			if (changed) {
				patch['sub-rules'] = next;
			}
		}
	}
	return patch;
};
