#!/usr/bin/ucode

// 认中继设备名的单元测试（不装进包里）。在路由器上部署 /etc/meowx/ucode/mesh_relay_name.uc 之后跑：
//   ucode -S mesh_relay_name_test.uc
// 全部通过退出码 0，否则逐条打印失败的用例并退出 1

'use strict';

import { split_addr, relay_endpoint, short_name, relay_via } from '/etc/meowx/ucode/mesh_relay_name.uc';

let passed = 0, failed = 0;

function eq(name, got, want) {
	if (sprintf('%J', got) == sprintf('%J', want)) {
		passed++;
	} else {
		failed++;
		printf('FAIL %s\n  got:  %J\n  want: %J\n', name, got, want);
	}
}

eq('v4 端点', split_addr('203.0.113.9:41641'), { ip: '203.0.113.9', port: 41641 });
eq('v6 端点', split_addr('[2001:db8::7]:41641'), { ip: '2001:db8::7', port: 41641 });
eq('坏端点', split_addr('2001:db8::7'), null);
eq('v4 + vni', relay_endpoint('203.0.113.9:40000:vni:12345'), { ip: '203.0.113.9', port: 40000, addr: '203.0.113.9:40000' });
eq('v4 不带 vni 字样', relay_endpoint('203.0.113.9:40000:12345'), { ip: '203.0.113.9', port: 40000, addr: '203.0.113.9:40000' });
eq('v6 + vni', relay_endpoint('[2001:db8::7]:40000:vni:9'), { ip: '2001:db8::7', port: 40000, addr: '[2001:db8::7]:40000' });
eq('v6 不带 vni 字样', relay_endpoint('[2001:db8::7]:40000:9'), { ip: '2001:db8::7', port: 40000, addr: '[2001:db8::7]:40000' });
eq('坏写法', relay_endpoint('garbage'), null);
eq('短名：HostName', short_name({ HostName: 'openwrt', DNSName: 'x.meowx.internal.' }), 'openwrt');
eq('短名：去掉 MagicDNS 后缀', short_name({ DNSName: 'home-nas.meowx.internal.' }), 'home-nas');

const home = { ID: '3', HostName: 'home-openwrt', Addrs: ['203.0.113.9:41641', '192.168.1.1:41641'] };
const laptop = { ID: '4', HostName: 'laptop', Addrs: ['203.0.113.9:52000'] };
const nas = { ID: '8', DNSName: 'nas-v6.meowx.internal.', Addrs: ['[2001:db8::7]:41641'] };
const office = { ID: '10', HostName: 'office', Addrs: ['198.51.100.20:41641'] };
const peers = [home, laptop, nas, office];
const only_home = (q) => q == home;

function via(relay, is_target) {
	const t = { ID: '9', HostName: 'po0', PeerRelay: relay };
	return relay_via(t, [...peers, t], is_target);
}

eq('唯一一台', via('198.51.100.20:40000:vni:1'), 'office');
eq('v6 唯一一台', via('[2001:db8::7]:40000:vni:1'), 'nas-v6');
eq('同一公网 IP 两台、不知道谁是中继：不认', via('203.0.113.9:40000:vni:1'), null);
eq('同一公网 IP 两台、只有一台授权给本机', via('203.0.113.9:40000:vni:1', only_home), 'home-openwrt');
eq('同一公网 IP 两台、都没授权：不认', via('203.0.113.9:40000:vni:1', (q) => false), null);
eq('同一公网 IP 两台、都授权：不认', via('203.0.113.9:40000:vni:1', (q) => true), null);
eq('同一公网 IP 两台、端口碰巧对上一台也不认（不看端口）', via('203.0.113.9:52000:vni:1'), null);
eq('对不上', via('192.0.2.1:40000:vni:1'), null);
eq('没走设备中继', via(''), null);
const self = { ID: '9', HostName: 'po0', PeerRelay: '192.0.2.1:40000:vni:1', Addrs: ['192.0.2.1:41641'] };
eq('对端自己不算', relay_via(self, [self]), null);

printf('%d passed, %d failed\n', passed, failed);
exit(failed > 0 ? 1 : 0);
