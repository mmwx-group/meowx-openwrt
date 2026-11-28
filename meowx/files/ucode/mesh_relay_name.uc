'use strict';

// 喵窝设备中继：认出中继设备的名字（纯函数，mesh_cli.uc status 用；规格 miaomiaowuC/Design/mesh-peer-relay.md §2.4）。
// tailscale 只给中继地址（PeerRelay「ip:port:vni:N」，也认「ip:port:N」，IPv6「[ip]:port:…」），拿它的 IP 去对设备列表里
// 各设备上报的公网端点（Peer.Addrs）。同一公网 IP 后面常有好几台（家里路由器、电脑、手机共用出口）：对上不止一台时先只留
// 授权给本机的中继（is_target：对本机有 tailscale.com/cap/relay-target 能力），还不止一台再看端口也对上的，仍不止一台就不认
// （返回 null，界面写「经设备中继」，不猜）。

// 「ip:port」（IPv4）「[ip]:port」（IPv6）→ { ip, port }；拆不了为 null
export function split_addr(a) {
	a = '' + (a ?? '');
	let m = match(a, /^\[([^\]]+)\]:([0-9]+)$/);
	if (!m) {
		m = match(a, /^([0-9.]+):([0-9]+)$/);
	}
	return m ? { ip: lc(m[1]), port: +m[2] } : null;
};

// PeerRelay → 中继的 { ip, port, addr: 'ip:port' }；拆不了为 null
export function relay_endpoint(v) {
	v = '' + (v ?? '');
	let m = match(v, /^\[([^\]]+)\]:([0-9]+)(:vni)?:[0-9]+$/);
	if (m) {
		return { ip: lc(m[1]), port: +m[2], addr: `[${m[1]}]:${m[2]}` };
	}
	m = match(v, /^([0-9.]+):([0-9]+)(:vni)?:[0-9]+$/);
	return m ? { ip: lc(m[1]), port: +m[2], addr: `${m[1]}:${m[2]}` } : null;
};

// 设备名的短名：HostName，没有时取 DNSName 的第一段（去掉 MagicDNS 后缀）
export function short_name(p) {
	if (p?.HostName) {
		return p.HostName;
	}
	const dns = rtrim(p?.DNSName ?? '', '.');
	return dns ? split(dns, '.')[0] : null;
};

// target 是走设备中继的那台（tailscale status 的 Peer 条目），peers 是全部 Peer 条目；返回中继设备名或 null
export function relay_via(target, peers, is_target) {
	const r = relay_endpoint(target?.PeerRelay);
	if (!r) {
		return null;
	}
	let by_ip = [], by_port = [];
	for (let q in peers ?? []) {
		if (q == target || q?.ID == target?.ID) {
			continue;
		}
		let ip_hit = false, port_hit = false;
		for (let a in q?.Addrs ?? []) {
			const e = split_addr(a);
			if (e?.ip == r.ip) {
				ip_hit = true;
				if (e.port == r.port) {
					port_hit = true;
				}
			}
		}
		if (ip_hit) {
			push(by_ip, q);
		}
		if (port_hit) {
			push(by_port, q);
		}
	}
	if (length(by_ip) == 1) {
		return short_name(by_ip[0]);
	}
	if (length(by_ip) == 0) {
		return null;
	}
	if (is_target) {
		const targets = filter(by_ip, (q) => is_target(q));
		if (length(targets) == 1) {
			return short_name(targets[0]);
		}
		if (length(targets) > 1) {
			by_ip = targets;
		}
	}
	const hits = filter(by_port, (q) => index(by_ip, q) >= 0);
	return length(hits) == 1 ? short_name(hits[0]) : null;
};
