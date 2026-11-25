#!/usr/bin/ucode

// 喵窝白名单直连纯函数的单元测试（不装进包里）。在路由器上部署 /etc/meowx/ucode/mesh_direct.uc 之后跑：
//   ucode -S mesh_direct_test.uc
// 全部通过退出码 0，否则逐条打印失败的用例并退出 1

'use strict';

import { host_of, panel_subscription, direct_on, header_value, mesh_nodes, rule_target } from '/etc/meowx/ucode/mesh_direct.uc';

let passed = 0, failed = 0;

function eq(name, got, want) {
	if (sprintf('%J', got) == sprintf('%J', want)) {
		passed++;
	} else {
		failed++;
		printf('FAIL %s\n  got:  %J\n  want: %J\n', name, got, want);
	}
}

// 主机名
eq('host', host_of('https://Panel.Example.com:8443/x/abc?t=1'), 'panel.example.com');
eq('host v6', host_of('http://[2001:db8::1]:80/'), '[2001:db8::1]');
eq('host 不是地址', host_of('panel.example.com'), null);
eq('host 非字符串', host_of(null), null);

// 认本主控的订阅
const panel = { base: 'https://panel.example.com', sub_base: 'https://sub.example.com' };
eq('主控域名', panel_subscription('https://panel.example.com/x/abc', null, panel), true);
eq('订阅域名', panel_subscription('https://SUB.example.com/api/clash/subscribe?token=1', null, panel), true);
eq('实时通道地址是这个主控', panel_subscription('https://cdn.example.net/x/abc', 'https://panel.example.com', panel), true);
eq('别家机场', panel_subscription('https://airport.example.org/sub', null, panel), false);
eq('别的妙妙屋主控', panel_subscription('https://other.example.org/x/abc', 'https://other.example.org', panel), false);
eq('没有 sub_base（老内核）', panel_subscription('https://sub.example.com/x/1', null, { base: 'https://panel.example.com' }), false);
eq('没登录', panel_subscription('https://panel.example.com/x/1', null, null), false);

// 生效条件
const ok_state = { control_url: 'https://panel.example.com', error: null };
eq('全满足', direct_on({ enabled: true, whitelist: true, logged_in: true, state: ok_state }), true);
eq('喵窝关着', direct_on({ enabled: false, whitelist: true, logged_in: true, state: ok_state }), false);
eq('开关关了', direct_on({ enabled: true, whitelist: false, logged_in: true, state: ok_state }), false);
eq('开关缺省开', direct_on({ enabled: true, logged_in: true, state: ok_state }), true);
eq('没登录', direct_on({ enabled: true, whitelist: true, logged_in: false, state: ok_state }), false);
eq('入网失败', direct_on({ enabled: true, whitelist: true, logged_in: true, state: { control_url: 'x', error: '主控没有开放喵窝' } }), false);
eq('还没入网过', direct_on({ enabled: true, whitelist: true, logged_in: true, state: {} }), false);

// 请求头
eq('头 on', header_value('https://panel.example.com/x/1', null, panel, true), 'on');
eq('头 off', header_value('https://sub.example.com/x/1', null, panel, false), 'off');
eq('别家不带', header_value('https://airport.example.org/sub', null, panel, true), null);

// 运行配置
const profile = {
	proxies: [
		{ name: 'a', type: 'ss', server: '1.2.3.4' },
		{ name: 'po0 东京 · 喵窝', type: 'vless', server: '100.64.0.21', servername: 'tokyo.example.com', '_mmwx-mesh': true },
		{ name: 'b · 喵窝', type: 'trojan', server: '100.64.0.22', '_mmwx-mesh': true, 'interface-name': 'eth9' },
		{ name: 'c', type: 'ss', server: '5.6.7.8', '_mmwx-mesh': false },
	],
	'proxy-groups': [
		{ name: '节点选择', type: 'select', proxies: [ 'a', 'po0 东京 · 喵窝', 'DIRECT' ] },
		{ name: '只有喵窝', type: 'url-test', proxies: [ 'po0 东京 · 喵窝', 'b · 喵窝' ] },
		{ name: '还有 provider', type: 'select', proxies: [ 'b · 喵窝' ], use: [ 'p1' ] },
		{ name: 'include-all', type: 'select', proxies: [ 'b · 喵窝' ], 'include-all': true },
		{ name: '不相干', type: 'select', proxies: [ 'a' ] },
	]
};

eq('on', mesh_nodes(profile, true, 'tailscale0'), {
	proxies: [
		{ name: 'a', type: 'ss', server: '1.2.3.4' },
		{ name: 'po0 东京 · 喵窝', type: 'vless', server: '100.64.0.21', servername: 'tokyo.example.com', 'interface-name': 'tailscale0' },
		{ name: 'b · 喵窝', type: 'trojan', server: '100.64.0.22', 'interface-name': 'eth9' },
		{ name: 'c', type: 'ss', server: '5.6.7.8' },
	]
});

eq('off', mesh_nodes(profile, false, 'tailscale0'), {
	proxies: [
		{ name: 'a', type: 'ss', server: '1.2.3.4' },
		{ name: 'c', type: 'ss', server: '5.6.7.8' },
	],
	'proxy-groups': [
		{ name: '节点选择', type: 'select', proxies: [ 'a', 'DIRECT' ] },
		{ name: '只有喵窝', type: 'url-test', proxies: [ 'DIRECT' ] },
		{ name: '还有 provider', type: 'select', proxies: [], use: [ 'p1' ] },
		{ name: 'include-all', type: 'select', proxies: [], 'include-all': true },
		{ name: '不相干', type: 'select', proxies: [ 'a' ] },
	]
});

eq('没有喵窝节点', mesh_nodes({ proxies: [ { name: 'a' } ], 'proxy-groups': [] }, false, 'tailscale0'), null);
eq('没有 proxies', mesh_nodes({}, true, 'tailscale0'), null);
eq('off 但没有组', mesh_nodes({ proxies: [ { name: 'x', '_mmwx-mesh': true } ] }, false, 'tailscale0'), { proxies: [] });
eq('原配置不变', profile.proxies[1]['_mmwx-mesh'], true);

// 规则的目标
eq('目标 普通', rule_target('DOMAIN-SUFFIX,example.com,节点选择'), '节点选择');
eq('目标 带选项', rule_target('IP-CIDR,1.2.3.0/24,a,no-resolve'), 'a');
eq('目标 MATCH', rule_target('MATCH,节点选择'), '节点选择');
eq('目标 逻辑', rule_target('AND,((DOMAIN,a.com),(NETWORK,UDP)),po0 东京 · 喵窝'), 'po0 东京 · 喵窝');
eq('目标 NOT', rule_target('NOT,((DOMAIN-KEYWORD,ads)),b · 喵窝'), 'b · 喵窝');
eq('目标 空白', rule_target(' DOMAIN , x.com , a '), 'a');
eq('目标 认不出', rule_target('DOMAIN,x.com'), null);
eq('目标 非字符串', rule_target(null), null);

// off 时删掉指向被拿掉节点的规则（rules 与 sub-rules），不改成 DIRECT
const ruled = {
	proxies: [
		{ name: 'a', type: 'ss' },
		{ name: 'po0 东京 · 喵窝', type: 'vless', '_mmwx-mesh': true },
	],
	'proxy-groups': [ { name: 'G', type: 'select', proxies: [ 'a', 'po0 东京 · 喵窝' ] } ],
	rules: [
		'DOMAIN,direct.example.com,po0 东京 · 喵窝',
		'AND,((DOMAIN,a.com),(NETWORK,TCP)),po0 东京 · 喵窝',
		'OR,((DOMAIN,b.com),(DOMAIN,c.com)),G',
		'SUB-RULE,(NETWORK,TCP),sub1',
		'MATCH,G',
	],
	'sub-rules': {
		sub1: [ 'DOMAIN,x.com,po0 东京 · 喵窝', 'MATCH,a' ],
		sub2: [ 'MATCH,G' ],
	}
};
const off = mesh_nodes(ruled, false, 'tailscale0');
eq('off rules', off.rules, [ 'OR,((DOMAIN,b.com),(DOMAIN,c.com)),G', 'SUB-RULE,(NETWORK,TCP),sub1', 'MATCH,G' ]);
eq('off sub-rules', off['sub-rules'], { sub1: [ 'MATCH,a' ], sub2: [ 'MATCH,G' ] });
const on = mesh_nodes(ruled, true, 'tailscale0');
eq('on 不动规则', [ on.rules, on['sub-rules'] ], [ null, null ]);
const norules = mesh_nodes({ proxies: ruled.proxies, rules: [ 'MATCH,a' ], 'sub-rules': { s: [ 'MATCH,a' ] } }, false, 'tailscale0');
eq('没有指向它的规则不出补丁', [ norules.rules, norules['sub-rules'] ], [ null, null ]);

printf('%d passed, %d failed\n', passed, failed);
exit(failed > 0 ? 1 : 0);
