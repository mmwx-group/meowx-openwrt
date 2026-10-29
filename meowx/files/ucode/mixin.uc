#!/usr/bin/ucode

'use strict';

import { readfile } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { uci_bool, uci_int, uci_array, trim_all } from '/etc/meowx/ucode/include.uc';

const uci = cursor();
const ubus = connect();

const config = {};

const outbound_interface = uci.get('meowx', 'mixin', 'outbound_interface');
const outbound_interface_status = ubus.call('network.interface', 'status', { 'interface': outbound_interface });
const outbound_device = outbound_interface_status?.l3_device ?? outbound_interface_status?.device ?? '';

config['log-level'] = uci.get('meowx', 'mixin', 'log_level');
config['mode'] = uci.get('meowx', 'mixin', 'mode');
config['find-process-mode'] = uci.get('meowx', 'mixin', 'match_process');
config['interface-name'] = outbound_device;
config['ipv6'] = uci_bool(uci.get('meowx', 'mixin', 'ipv6'));
config['unified-delay'] = uci_bool(uci.get('meowx', 'mixin', 'unify_delay'));
config['tcp-concurrent'] = uci_bool(uci.get('meowx', 'mixin', 'tcp_concurrent'));
config['disable-keep-alive'] = uci_bool(uci.get('meowx', 'mixin', 'disable_tcp_keep_alive'));
config['keep-alive-idle'] = uci_int(uci.get('meowx', 'mixin', 'tcp_keep_alive_idle'));
config['keep-alive-interval'] = uci_int(uci.get('meowx', 'mixin', 'tcp_keep_alive_interval'));

config['external-ui'] = uci.get('meowx', 'mixin', 'ui_path');
config['external-ui-name'] = uci.get('meowx', 'mixin', 'ui_name');
config['external-ui-url'] = uci.get('meowx', 'mixin', 'ui_url');
config['external-controller'] = uci.get('meowx', 'mixin', 'api_listen');
config['external-controller-tls'] = uci.get('meowx', 'mixin', 'api_tls_listen');
config['tls'] = {};
config['tls']['certificate'] = uci.get('meowx', 'mixin', 'api_tls_cert');
config['tls']['private-key'] = uci.get('meowx', 'mixin', 'api_tls_key');
config['tls']['ech-key'] = uci.get('meowx', 'mixin', 'api_tls_ech_key');
config['secret'] = uci.get('meowx', 'mixin', 'api_secret');

config['allow-lan'] = uci_bool(uci.get('meowx', 'mixin', 'allow_lan'));
config['port'] = uci_int(uci.get('meowx', 'mixin', 'http_port'));
config['socks-port'] = uci_int(uci.get('meowx', 'mixin', 'socks_port'));
config['mixed-port'] = uci_int(uci.get('meowx', 'mixin', 'mixed_port'));
config['redir-port'] = uci_int(uci.get('meowx', 'mixin', 'redir_port'));
config['tproxy-port'] = uci_int(uci.get('meowx', 'mixin', 'tproxy_port'));

if (uci_bool(uci.get('meowx', 'mixin', 'authentication'))) {
	config['authentication'] = [];
	uci.foreach('meowx', 'authentication', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		push(config['authentication'], `${section.username}:${section.password}`);
	});
}

config['tun'] = {};
config['tun']['enable'] = uci_bool(uci.get('meowx', 'mixin', 'tun_enabled'));
config['tun']['device'] = uci.get('meowx', 'mixin', 'tun_device');
config['tun']['stack'] = uci.get('meowx', 'mixin', 'tun_stack');
config['tun']['mtu'] = uci_int(uci.get('meowx', 'mixin', 'tun_mtu'));
config['tun']['gso'] = uci_bool(uci.get('meowx', 'mixin', 'tun_gso'));
config['tun']['gso-max-size'] = uci_int(uci.get('meowx', 'mixin', 'tun_gso_max_size'));
if (uci_bool(uci.get('meowx', 'mixin', 'tun_dns_hijack'))) {
	config['tun']['dns-hijack'] = uci_array(uci.get('meowx', 'mixin', 'tun_dns_hijacks'));
}

config['dns'] = {};
config['dns']['enable'] = uci_bool(uci.get('meowx', 'mixin', 'dns_enabled'));
config['dns']['cache-algorithm'] = uci.get('meowx', 'mixin', 'dns_cache_algorithm');
config['dns']['listen'] = uci.get('meowx', 'mixin', 'dns_listen');
config['dns']['ipv6'] = uci_bool(uci.get('meowx', 'mixin', 'dns_ipv6'));
config['dns']['enhanced-mode'] = uci.get('meowx', 'mixin', 'dns_mode');
config['dns']['fake-ip-range'] = uci.get('meowx', 'mixin', 'fake_ip_range');
config['dns']['fake-ip-range6'] = uci.get('meowx', 'mixin', 'fake_ip6_range');
config['dns']['fake-ip-ttl'] = uci_int(uci.get('meowx', 'mixin', 'fake_ip_ttl'));
if (uci_bool(uci.get('meowx', 'mixin', 'fake_ip_filter'))) {
	config['dns']['fake-ip-filter'] = uci_array(uci.get('meowx', 'mixin', 'fake_ip_filters'));
}
config['dns']['fake-ip-filter-mode'] = uci.get('meowx', 'mixin', 'fake_ip_filter_mode');

config['dns']['respect-rules'] = uci_bool(uci.get('meowx', 'mixin', 'dns_respect_rules'));
config['dns']['prefer-h3'] = uci_bool(uci.get('meowx', 'mixin', 'dns_doh_prefer_http3'));
config['dns']['use-system-hosts'] = uci_bool(uci.get('meowx', 'mixin', 'dns_system_hosts'));
config['dns']['use-hosts'] = uci_bool(uci.get('meowx', 'mixin', 'dns_hosts'));
if (uci_bool(uci.get('meowx', 'mixin', 'hosts'))) {
	config['hosts'] = {};
	uci.foreach('meowx', 'hosts', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		config['hosts'][section.domain_name] = uci_array(section.ip);
	});
}
if (uci_bool(uci.get('meowx', 'mixin', 'dns_nameserver'))) {
	config['dns']['default-nameserver'] = [];
	config['dns']['proxy-server-nameserver'] = [];
	config['dns']['direct-nameserver'] = [];
	config['dns']['nameserver'] = [];
	config['dns']['fallback'] = [];
	uci.foreach('meowx', 'nameserver', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		push(config['dns'][section.type], ...uci_array(section.nameserver));
	})
}
if (uci_bool(uci.get('meowx', 'mixin', 'dns_proxy_server_nameserver_policy'))) {
	config['dns']['proxy-server-nameserver-policy'] = {};
	uci.foreach('meowx', 'proxy_server_nameserver_policy', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		config['dns']['proxy-server-nameserver-policy'][section.matcher] = uci_array(section.nameserver);
	});
}
config['dns']['direct-nameserver-follow-policy'] = uci_bool(uci.get('meowx', 'mixin', 'dns_direct_nameserver_follow_policy'));
if (uci_bool(uci.get('meowx', 'mixin', 'dns_nameserver_policy'))) {
	config['dns']['nameserver-policy'] = {};
	uci.foreach('meowx', 'nameserver_policy', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		config['dns']['nameserver-policy'][section.matcher] = uci_array(section.nameserver);
	});
}

config['sniffer'] = {};
config['sniffer']['enable'] = uci_bool(uci.get('meowx', 'mixin', 'sniffer'));
config['sniffer']['force-dns-mapping'] = uci_bool(uci.get('meowx', 'mixin', 'sniffer_sniff_dns_mapping'));
config['sniffer']['parse-pure-ip'] = uci_bool(uci.get('meowx', 'mixin', 'sniffer_sniff_pure_ip'));
if (uci_bool(uci.get('meowx', 'mixin', 'sniffer_force_domain_name'))) {
	config['sniffer']['force-domain'] = uci_array(uci.get('meowx', 'mixin', 'sniffer_force_domain_names'));
}
if (uci_bool(uci.get('meowx', 'mixin', 'sniffer_ignore_domain_name'))) {
	config['sniffer']['skip-domain'] = uci_array(uci.get('meowx', 'mixin', 'sniffer_ignore_domain_names'));
}
if (uci_bool(uci.get('meowx', 'mixin', 'sniffer_sniff'))) {
	config['sniffer']['sniff'] = {};
	config['sniffer']['sniff']['HTTP'] = {};
	config['sniffer']['sniff']['TLS'] = {};
	config['sniffer']['sniff']['QUIC'] = {};
	uci.foreach('meowx', 'sniff', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		config['sniffer']['sniff'][section.protocol]['port'] = uci_array(section.port);
		config['sniffer']['sniff'][section.protocol]['override-destination'] = uci_bool(section.overwrite_destination);
	});
}

config['profile'] = {};
config['profile']['store-selected'] = uci_bool(uci.get('meowx', 'mixin', 'selection_cache'));
config['profile']['store-fake-ip'] = uci_bool(uci.get('meowx', 'mixin', 'fake_ip_cache'));

if (uci_bool(uci.get('meowx', 'mixin', 'rule_provider'))) {
	config['rule-providers'] = {};
	uci.foreach('meowx', 'rule_provider', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		if (section.type == 'http') {
			config['rule-providers'][section.name] = {
				type: section.type,
				url: section.url,
				proxy: section.node,
				size_limit: section.file_size_limit,
				format: section.file_format,
				behavior: section.behavior,
				interval: section.update_interval,
			}
		} else if (section.type == 'file') {
			config['rule-providers'][section.name] = {
				type: section.type,
				path: section.file_path,
				format: section.file_format,
				behavior: section.behavior,
			}
		}
	})
}
if (uci_bool(uci.get('meowx', 'mixin', 'rule'))) {
	config['meowx-rules'] = [];
	uci.foreach('meowx', 'rule', (section) => {
		if (!uci_bool(section.enabled)) {
			return;
		}
		const rule = [ section.type, section.matcher, section.node, uci_bool(section.no_resolve) ? 'no-resolve' : null ];
		push(config['meowx-rules'], join(',', filter(rule, (item) => item != null && item != '')));
	})
}

// po0 直连（同客户端 Po0DirectRules）：开着 po0 加白时每台 po0 直连——局域网里的设备访问 / 上报 po0 也得用本机出口 IP，
// 按订阅规则经节点出去，po0 认的就成了节点的 IP。
// 地址是 IP 时 IP-CIDR /32（v6 /128）、no-resolve，是域名（主控配的「加白地址」）时 DOMAIN；列表由 meowx-core panel 维护
const po0_rules = [];
const po0 = json(readfile('/etc/meowx/po0.json') ?? 'null');
for (let u in (po0?.enabled ? po0.report_urls : null) ?? []) {
	const m = match(u, /^https:\/\/(\[[^\]]+\]|[^\/:?#]+)/);
	if (!m) {
		continue;
	}
	const host = lc(trim(m[1], '[]'));
	let rule;
	if (match(host, /^[0-9.]+$/)) {
		rule = `IP-CIDR,${host}/32,DIRECT,no-resolve`;
	} else if (index(host, ':') >= 0) {
		rule = `IP-CIDR6,${host}/128,DIRECT,no-resolve`;
	} else {
		rule = `DOMAIN,${host},DIRECT`;
	}
	if (index(po0_rules, rule) < 0) {
		push(po0_rules, rule);
	}
}

if (length(po0_rules) > 0) {
	config['meowx-rules'] = [ ...po0_rules, ...(config['meowx-rules'] ?? []) ];
}

// 阻止 QUIC（同客户端的「阻止 QUIC」）：发往 UDP 443 的一律拒绝，应用回落 TCP——有的线路 UDP 与 TCP 的落地出口不同，
// 走 QUIC 的 App 会被判到别的地区。排在全部规则最前；只在规则模式下生效
if (uci_bool(uci.get('meowx', 'mixin', 'block_quic'))) {
	config['meowx-rules'] = [ 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT', ...(config['meowx-rules'] ?? []) ];
}

const geoip_format = uci.get('meowx', 'mixin', 'geoip_format');
config['geodata-mode'] = geoip_format == null ? null : geoip_format == 'dat';
config['geodata-loader'] = uci.get('meowx', 'mixin', 'geodata_loader');
config['geox-url'] = {};
config['geox-url']['geosite'] = uci.get('meowx', 'mixin', 'geosite_url');
config['geox-url']['mmdb'] = uci.get('meowx', 'mixin', 'geoip_mmdb_url');
config['geox-url']['geoip'] = uci.get('meowx', 'mixin', 'geoip_dat_url');
config['geox-url']['asn'] = uci.get('meowx', 'mixin', 'geoip_asn_url');
config['geo-auto-update'] = uci_bool(uci.get('meowx', 'mixin', 'geox_auto_update'));
config['geo-update-interval'] = uci_int(uci.get('meowx', 'mixin', 'geox_update_interval'));

print(trim_all(config));