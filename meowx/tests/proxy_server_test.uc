#!/usr/bin/ucode

// 「绕过节点服务器地址」纯函数的单元测试（不装进包里）。在路由器上部署 /etc/meowx/ucode/proxy_server.uc 之后跑：
//   ucode -S proxy_server_test.uc
// 全部通过退出码 0，否则逐条打印失败的用例并退出 1

'use strict';

import { server_kind, servers_of, provider_file, collect_servers, classify, answer_ips, controller_base, nft_script, fake_ip_filter_patch } from '/etc/meowx/ucode/proxy_server.uc';

let passed = 0, failed = 0;

function eq(name, got, want) {
	if (sprintf('%J', got) == sprintf('%J', want)) {
		passed++;
	} else {
		failed++;
		printf('FAIL %s\n  got:  %J\n  want: %J\n', name, got, want);
	}
}

// 认地址
eq('v4', server_kind('1.2.3.4'), 'v4');
eq('v4 带空白', server_kind(' 1.2.3.4 '), 'v4');
eq('v6', server_kind('2001:db8::1'), 'v6');
eq('v6 方括号', server_kind('[2001:db8::1]'), 'v6');
eq('域名', server_kind('hk-1.example.com'), 'domain');
eq('下划线域名', server_kind('a_b.example.com'), 'domain');
eq('单个标签不管', server_kind('localhost'), null);
eq('空', server_kind(''), null);
eq('非字符串', server_kind(443), null);
eq('非法字符', server_kind('a b.example.com'), null);
eq('不能拼进 shell 的', server_kind("x'.example.com"), null);

// 收集
const profile = {
	proxies: [
		{ name: 'a', type: 'ss', server: '1.2.3.4' },
		{ name: 'b', type: 'vless', server: 'HK.Example.com' },
		{ name: 'c', type: 'trojan', server: '1.2.3.4' },
		{ name: 'd', type: 'direct' },
		{ name: 'e', type: 'hysteria2', server: '[2001:db8::10]' },
	],
	'proxy-providers': {
		inline1: { type: 'inline', payload: [ { name: 'f', server: 'jp.example.net' }, { name: 'g', server: '5.6.7.8' } ] },
		file1: { type: 'http', url: 'https://sub.example.com/x', path: './providers/proxy/p1.yaml' },
		file2: { type: 'file', path: '/etc/meowx/run/p2.yaml' },
	}
};
const files = {
	'./providers/proxy/p1.yaml': { proxies: [ { name: 'h', server: 'us.example.org' } ] },
	'/etc/meowx/run/p2.yaml': null,   // 不是 YAML 或文件不在
};
eq('servers_of 跳过没有 server 的', servers_of(profile.proxies), [ '1.2.3.4', 'HK.Example.com', '1.2.3.4', '[2001:db8::10]' ]);
eq('collect 只收 inline', collect_servers(profile, null), [ '1.2.3.4', 'HK.Example.com', '[2001:db8::10]', 'jp.example.net', '5.6.7.8' ]);
eq('collect 带缓存文件', collect_servers(profile, (p) => files[p.path]), [ '1.2.3.4', 'HK.Example.com', '[2001:db8::10]', 'jp.example.net', '5.6.7.8', 'us.example.org' ]);
eq('collect 空配置', collect_servers({}, null), []);
eq('collect null', collect_servers(null, null), []);

// 分类
eq('classify', classify([ '1.2.3.4', 'HK.Example.com', '[2001:DB8::10]', '2001:db8:0:0::10', 'hk.example.com', 'localhost' ]),
	{ ip4: [ '1.2.3.4' ], ip6: [ '2001:db8::10' ], domains: [ 'hk.example.com' ] });

// provider 缓存文件的位置
eq('相对路径', provider_file({ path: './providers/proxy/a.yaml' }), '/etc/meowx/run/providers/proxy/a.yaml');
eq('不带 ./ 的相对路径', provider_file({ path: 'p/a.yaml' }), '/etc/meowx/run/p/a.yaml');
eq('绝对路径', provider_file({ path: '/etc/meowx/run/a.yaml' }), '/etc/meowx/run/a.yaml');
eq('没写 path 按 url 的 md5', provider_file({ url: 'https://x' }, 'abc123'), '/etc/meowx/run/proxies/abc123');
eq('都没有', provider_file({}, null), null);

// /dns/query 应答
const reply = { Answer: [ { type: 5, data: 'cdn.example.com.' }, { type: 1, data: '9.9.9.9' }, { type: 28, data: '2001:db8::9' } ] };
eq('A', answer_ips(reply, 'A'), [ '9.9.9.9' ]);
eq('AAAA', answer_ips(reply, 'AAAA'), [ '2001:db8::9' ]);
eq('没有 Answer', answer_ips({ Status: 3 }, 'A'), []);
eq('null', answer_ips(null, 'A'), []);

// 外部控制地址
eq('0.0.0.0', controller_base({ 'external-controller': '0.0.0.0:9090' }), { base: 'http://127.0.0.1:9090', tls: false });
eq('[::]', controller_base({ 'external-controller': '[::]:9090' }), { base: 'http://[::1]:9090', tls: false });
eq('只写端口', controller_base({ 'external-controller': ':9090' }), { base: 'http://127.0.0.1:9090', tls: false });
eq('本机地址', controller_base({ 'external-controller': '192.168.1.1:9090' }), { base: 'http://192.168.1.1:9090', tls: false });
eq('只有 tls', controller_base({ 'external-controller-tls': '0.0.0.0:9443' }), { base: 'https://127.0.0.1:9443', tls: true });
eq('没有', controller_base({}), null);
eq('端口不对', controller_base({ 'external-controller': '127.0.0.1:abc' }), null);

// nft
eq('nft 有地址', nft_script([ '1.2.3.4', '5.6.7.8' ], [ '2001:db8::1' ]),
	'flush set inet meowx proxy_server\nflush set inet meowx proxy_server6\nadd element inet meowx proxy_server { 1.2.3.4, 5.6.7.8 }\nadd element inet meowx proxy_server6 { 2001:db8::1 }\n');
eq('nft 空', nft_script([], []), 'flush set inet meowx proxy_server\nflush set inet meowx proxy_server6\n');

// fake-ip-filter 补丁
eq('fake-ip 黑名单：追加、不重复', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip', 'fake-ip-filter': [ '+.lan', 'a.example.com' ] } }, [ 'a.example.com', 'b.example.com' ]),
	{ dns: { 'fake-ip-filter': [ '+.lan', 'a.example.com', 'b.example.com' ] } });
eq('fake-ip 没有名单', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip' } }, [ 'b.example.com' ]),
	{ dns: { 'fake-ip-filter': [ 'b.example.com' ] } });
eq('显式黑名单', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip', 'fake-ip-filter-mode': 'blacklist' } }, [ 'b.example.com' ]),
	{ dns: { 'fake-ip-filter': [ 'b.example.com' ] } });
eq('白名单不加', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip', 'fake-ip-filter-mode': 'whitelist' } }, [ 'b.example.com' ]), null);
eq('规则模式不加', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip', 'fake-ip-filter-mode': 'rule' } }, [ 'b.example.com' ]), null);
eq('redir-host 不加', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'redir-host' } }, [ 'b.example.com' ]), null);
eq('没有 dns', fake_ip_filter_patch({}, [ 'b.example.com' ]), null);
eq('全已在名单', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip', 'fake-ip-filter': [ 'b.example.com' ] } }, [ 'b.example.com' ]), null);
eq('没有域名', fake_ip_filter_patch({ dns: { 'enhanced-mode': 'fake-ip' } }, []), null);

printf('%d passed, %d failed\n', passed, failed);
exit(failed > 0 ? 1 : 0);
