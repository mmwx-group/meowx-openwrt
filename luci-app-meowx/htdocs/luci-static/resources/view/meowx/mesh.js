'use strict';
'require baseclass';
'require ui';
'require tools.meowx as meowx';

// 「喵窝」页：路由器用官方 tailscale 程序加入主控的喵窝（Tailscale 协议），把局域网开放给同一管理员账号的其它设备。
// 点了就生效（同 po0 卡片）：开关 / 「保存并应用」把设置交给路由器后台入网，页面每 2 秒问一次状态直到应用完。
// 入网 key 由路由器向主控要（要先在「插件配置」里登录主控账户），防火墙、网段映射由 mesh_cli.uc 写进 fw4。
// 主控那边的信息（访问范围、设备上限、同网络的设备 / 站点、可经喵窝连接的服务器）与「白名单节点经喵窝连线」开关
// 放在单独一块（renderPanel）：要向主控发请求，只在打开页面、切回来、应用完时取一次，不进 2 秒一次的轮询。
// 设备中继（规格 miaomiaowuC/Design/mesh-peer-relay.md §2.4 / §5.2）：主控 status 带 device_relay.enabled 时显示中继一节
// （renderRelay，开关 / 端口 / 静态地址 / DDNS / 共享范围、状态、NAT 与端口映射提示、正在经本机中继的会话）；
// 页面看得见时每 15 秒取一次主控汇总的路径（mesh_cli paths，顺手在路由器后台 tick 一次），「其它设备」按它显示经哪台中继。

const POLL_MS = 2000;
const POLL_LIMIT = 60;   // 最多等 2 分钟（tailscale up 自己最长 60 秒）
const PATHS_MS = 15000;

function mb(kb) {
    return Math.max(0, Math.round((kb ?? 0) / 1024));
}

function stateLabel(st) {
    if (st.applying) {
        return [_('Applying…'), ''];
    }
    if (!st.settings?.enabled) {
        return [_('Off'), ''];
    }
    if (st.backend == 'Running' && st.self?.online !== false) {
        return [_('Connected'), 'is-running'];
    }
    if (st.backend == 'NeedsLogin' || st.backend == 'NeedsMachineAuth') {
        return [_('Not joined'), ''];
    }
    if (st.backend == 'Starting') {
        return [_('Connecting…'), ''];
    }
    return [_('Not connected'), ''];
}

function row(main, sub, extra) {
    return E('div', { class: 'mx-po0__row' }, [
        E('div', { class: 'mx-po0__main' }, [
            E('div', { class: 'mx-po0__addr' }, main),
            sub ? E('div', { class: 'mx-po0__token' }, sub) : ''
        ]),
        extra ?? ''
    ]);
}

// 访问范围（主控 status 的 access_scope；旧主控没有 = 不显示）
function scopeLabel(scope) {
    switch (scope) {
    case 'servers': return _('Access: servers only');
    case 'sites': return _('Access: servers + admin sites');
    case 'full': return _('Access: full');
    }
    return null;
}

// 主控那边的喵窝信息 + 白名单直连开关。info = mesh_cli.uc panel 的结果；null = 还在取
function renderPanel(box, info, refresh) {
    if (!info) {
        box.replaceChildren(E('div', { class: 'mx-po0__group' }, [E('span', { class: 'spinning' }, _('Loading MeowNest info from the panel…'))]));
        return;
    }
    const view = info.view ?? {};
    const status = view.status ?? {};
    const children = [];
    if (view.success === false) {
        children.push(E('div', { class: 'mx-po0__note' }, _('Could not read MeowNest info from the panel: %s').format(view.error || _('Operation failed'))));
        box.replaceChildren(...children);
        return;
    }
    // 老内核的 status 没整理过、没有 in_list：照同一个规则现算（available，或原因不是 not_admin）
    const inList = status.in_list ?? (!!status.available || (!!status.reason && status.reason != 'not_admin'));
    if (!inList) {
        if (status.reason == 'not_admin') {
            children.push(E('div', { class: 'mx-po0__note' }, _('This account is not on the panel\'s MeowNest list.')));
        }
        box.replaceChildren(...children);
        return;
    }

    // 访问范围 · 已加入谁的喵窝 · 设备上限
    const meta = [scopeLabel(status.access_scope),
        status.joined_admin ? _('Joined %s\'s MeowNest').format(status.joined_admin) : null,
        status.device_limit > 0 ? _('Device limit: %d').format(status.device_limit) : _('Device limit: unlimited')
    ].filter((x) => x);
    children.push(E('div', { class: 'mx-po0__note' }, meta.join(' · ')));

    // 白名单节点经喵窝连线（缺省开）
    const s = info.settings ?? {};
    const box2 = E('input', { type: 'checkbox' });
    box2.checked = s.whitelist_direct !== false;
    const err = E('div', { class: 'mx-account__error', hidden: '' });
    box2.addEventListener('change', () => meowx.busy(box2, () => meowx.mesh('whitelist', { whitelist: box2.checked }).then((res) => {
        if (!res?.success) {
            err.textContent = res?.error || _('Operation failed');
            err.hidden = false;
            return;
        }
        refresh();
    }, (e) => {
        err.textContent = String(e?.message ?? e);
        err.hidden = false;
    })));
    children.push(E('label', { class: 'mx-mesh__check' }, [box2, E('span', {}, _('Whitelisted nodes connect through MeowNest'))]));
    children.push(E('div', { class: 'mx-po0__note' }, _('Whitelisted server nodes in the subscription connect through MeowNest instead, without taking a slot in the server\'s IP whitelist. MeowNest must be on.')));
    const nodes = info.nodes ?? [];
    if (info.direct) {
        children.push(E('div', { class: 'mx-po0__note' }, nodes.length > 0
            ? _('In use: %d node(s) connect through MeowNest: %s').format(nodes.length, nodes.join(', '))
            : _('In use. The current subscription has no whitelisted nodes for MeowNest (the panel decides which servers get one).')));
    } else if (box2.checked) {
        children.push(E('div', { class: 'mx-po0__note' }, _('Takes effect once MeowNest is on and joined.')));
    }
    children.push(err);

    // 可经喵窝连接的服务器（主控预留的 servers，有才显示）
    const servers = status.servers ?? [];
    if (servers.length > 0) {
        children.push(E('div', { class: 'mx-po0__group' }, _('Servers reachable through MeowNest (%d)').format(servers.length)));
        children.push(E('div', { class: 'mx-po0__list' }, servers.map((x) => row(x.name, x.mesh_ip))));
    }

    // 同网络的设备（共享设备，只读）：sites 范围下只有站点路由器（只有网段，没有地址）
    const shared = view.devices?.shared_devices ?? [];
    if (shared.length > 0) {
        children.push(E('div', { class: 'mx-po0__group' }, _('Devices in the same network (%d)').format(shared.length)));
        children.push(E('div', { class: 'mx-po0__list' }, shared.map((d) => d.kind == 'site'
            ? row(_('Site · %s').format(d.username || d.name || '?'), (d.routes ?? []).join(', '), E('span', { class: 'mx-badge' }, _('Site')))
            : row([E('span', { class: 'mx-mesh__dot' + (d.online ? ' is-online' : '') }), ' ', d.name || d.dns_name],
                [d.ipv4, (d.routes ?? []).join(', '), d.username].filter((x) => x).join(' · ')))));
    }
    if (view.devices_error) {
        children.push(E('div', { class: 'mx-po0__note' }, _('Could not read the device list: %s').format(view.devices_error)));
    } else if (view.devices?.error) {
        children.push(E('div', { class: 'mx-po0__note' }, view.devices.error));
    }
    box.replaceChildren(...children);
}


// peer_relay 的「ip:port:vni:N」（或 ip:port:N）→ ip:port
function relayAddr(v) {
    return String(v ?? '').replace(/(:vni)?:[0-9]+$/, '');
}

// 设备名的短名（去掉 MagicDNS 后缀）
function shortName(v) {
    return String(v ?? '').replace(/\.$/, '').split('.')[0];
}

// 「ip:port」/「[ip]:port」→ { ip, port }
function splitAddr(a) {
    const m = String(a ?? '').match(/^\[([^\]]+)\]:(\d+)$/) || String(a ?? '').match(/^([^:]+):(\d+)$/);
    return m ? { ip: m[1].toLowerCase(), port: +m[2] } : null;
}

// 本机当中继时会话一端的外网地址 → 设备名：地址与端口都对上设备上报的端点的那台，否则 IP 只对上一台的那台；
// 同一公网 IP 后面不止一台又分不出时不认（显示地址）
function endpointName(endpoint, peers) {
    const e = splitAddr(endpoint);
    if (!e) {
        return null;
    }
    const hits = (port) => peers.filter((p) => (p.addrs ?? []).some((a) => {
        const x = splitAddr(a);
        return x?.ip == e.ip && (!port || x.port == e.port);
    }));
    const exact = hits(true);
    if (exact.length == 1) {
        return shortName(exact[0].name || exact[0].dns_name);
    }
    const byIp = hits(false);
    return byIp.length == 1 ? shortName(byIp[0].name || byIp[0].dns_name) : null;
}

function linksOf(paths) {
    return paths?.paths?.success !== false ? (paths?.paths?.links ?? []) : [];
}

// 一条主控记录的路径文字（direct / peer_relay / derp；没有记录不显示）
function linkPathText(l) {
    if (!l) {
        return '';
    }
    if (l.path == 'direct') {
        return _('Direct');
    }
    if (l.path == 'peer_relay') {
        if (l.via?.name) {
            return (l.via.owner == 'other' ? _('Via %s relay (someone else\'s)') : _('Via %s relay')).format(l.via.name);
        }
        return _('Via device relay');
    }
    if (l.path == 'derp') {
        return _('Via relay server %s').format(l.derp?.name || l.derp?.region_code || '');
    }
    return '';
}

// 本机看到的对端路径（类型以本机实时值为准）：中继设备名先用本机认出的（mesh_cli 的 peer_relay_via：中继 IP 对上
// 某台设备上报的公网端点），再用主控 links 的 via.name，都没有只写「经设备中继」（不带 IP）；中继服务器名从主控补，
// 没有就写区域代码。本机判不出（PeerRelay 为空、没流量）时写「空闲」，不拿主控的旧记录顶上
function peerPathText(p, paths) {
    if (!p.online) {
        return _('Offline');
    }
    const links = linksOf(paths);
    if (p.peer_relay) {
        const addr = relayAddr(p.peer_relay);
        if (p.peer_relay_via) {
            return _('Via %s relay').format(shortName(p.peer_relay_via));
        }
        const l = links.find((x) => x.path == 'peer_relay' && x.via_addr == addr)
            ?? links.find((x) => p.ip && x.b?.ip == p.ip && x.path == 'peer_relay');
        return l?.via?.name ? linkPathText(Object.assign({}, l, { path: 'peer_relay' })) : _('Via device relay');
    }
    if (p.direct) {
        return _('Direct');
    }
    if (p.active === false) {
        return _('Idle');
    }
    if (p.relay) {
        const l = links.find((x) => x.path == 'derp' && x.derp?.region_code == p.relay);
        return _('Via relay server %s').format(l?.derp?.name || p.relay);
    }
    return '';
}

function agoText(ts) {
    const t = Date.parse(ts ?? '');
    if (!t) {
        return '';
    }
    const min = Math.max(0, Math.round((Date.now() - t) / 60000));
    return _('%d min ago').format(min);
}

// 本账号的其它设备：本机 tailscale 的对端 + 主控 links 里本机看不到的那一端（服务器视角等），后者过期的灰显
function renderPeers(box, st, paths) {
    const s = st.settings ?? {};
    if (!(s.enabled && st.backend == 'Running')) {
        box.replaceChildren();
        return;
    }
    const peers = st.peers ?? [];
    const ips = new Set(peers.map((p) => p.ip));
    const extra = linksOf(paths).filter((l) => l.b?.ip && !ips.has(l.b.ip));
    const children = [E('div', { class: 'mx-po0__group' }, _('Other devices (%d)').format(peers.length))];
    if (peers.length == 0 && extra.length == 0) {
        children.push(E('div', { class: 'mx-po0__empty' }, _('No other devices yet. Turn on "MeowNest" in MeowX signed in with the same admin account.')));
    } else {
        children.push(E('div', { class: 'mx-po0__list' }, peers.map((p) => row(
            [E('span', { class: 'mx-mesh__dot' + (p.online ? ' is-online' : '') }), ' ', p.name || p.dns_name],
            [p.ip, (p.routes ?? []).join(', '), peerPathText(p, paths)].filter((x) => x).join(' · ')
        )).concat(extra.map((l) => {
            const r = row(l.b.name || l.b.ip, [l.b.ip, linkPathText(l), l.stale ? agoText(l.reported_at) : ''].filter((x) => x).join(' · '));
            if (l.stale) {
                r.style.opacity = '0.55';
            }
            return r;
        }))));
    }
    box.replaceChildren(...children);
}

const relayStates = {
    disabled: () => _('Off'),
    pending: () => _('Waiting for this router to apply…'),
    active: () => _('Relaying'),
    version_too_old: () => _('tailscale too old'),
    error: () => _('Error'),
    offline: () => _('Offline')
};

// 中继一节。ctx = { st（mesh status）, relay（mesh_cli relay）, paths（mesh_cli paths）, net（netcheck）, status（主控 status）, refresh, installStatic }
function renderRelay(box, ctx) {
    const st = ctx.st ?? {};
    const info = ctx.relay;
    const dr = ctx.status?.device_relay;
    if (!dr?.enabled || !(st.settings?.enabled && st.backend == 'Running')) {
        box.replaceChildren();
        return;
    }
    const children = [
        E('div', { class: 'mx-po0__group' }, _('Device relay')),
        E('div', { class: 'mx-po0__note' }, _('Relay traffic for MeowNest devices that cannot connect directly, over one UDP port of this router — faster than relay servers. Traffic stays end-to-end encrypted; this router cannot see it.'))
    ];
    if (!info) {
        children.push(E('div', { class: 'mx-po0__group' }, [E('span', { class: 'spinning' }, _('Loading…'))]));
        box.replaceChildren(...children);
        return;
    }
    const last = info.last ?? ctx.paths?.last;
    const minVer = dr.min_version || info.min_version || '1.86.0';
    const unsupported = !info.version_ok || last?.relay_supported === false || info.local?.supported === false;
    // tailscale 太旧 / 没编进中继服务器：给 MeowX 提供的静态包
    if (unsupported || (info.ts_static && info.ts_static != info.static_version)) {
        children.push(E('div', { class: unsupported ? 'mx-account__error' : 'mx-po0__note' }, unsupported
            ? _('This tailscale (%s) cannot act as a device relay: it needs %s or later, built with the relay server.').format(info.version || '?', minVer)
            : _('An update of the tailscale provided by MeowX is available: %s.').format(info.static_version)));
        if (st.installing) {
            children.push(E('div', { class: 'mx-po0__group' }, [E('span', { class: 'spinning' }, _('Installing tailscale…'))]));
        } else if (info.static_arch) {
            children.push(E('div', { class: 'mx-account__actions' }, [E('button', {
                type: 'button', class: 'cbi-button cbi-button-action',
                click: (ev) => meowx.busy(ev.currentTarget, ctx.installStatic)
            }, _('Install the tailscale provided by MeowX (%s)').format(info.static_version))]));
            children.push(E('div', { class: 'mx-po0__note' }, _('Built from the official source with unused features removed (about 15–20 MB of storage). The tailscale package from the software source is kept on hold so upgrades do not replace it.')));
        } else {
            children.push(E('div', { class: 'mx-po0__note' }, _('No static package for this router\'s architecture. Upgrade tailscale in the software source instead.')));
        }
    }
    if (!info.device_id) {
        box.replaceChildren(...children);
        return;
    }
    const r = info.relay ?? {};
    if (r.success === false) {
        children.push(E('div', { class: 'mx-account__error' }, _('Could not read the relay settings from the panel: %s').format(r.error || _('Operation failed'))));
    }

    // 表单（主控保存的配置是唯一依据）
    const enabled = E('input', { type: 'checkbox' });
    enabled.checked = !!r.enabled;
    const port = E('input', { type: 'number', min: '1024', max: '65535', class: 'mx-quickadd__input', value: String(r.port || 40000) });
    const eps = E('input', {
        type: 'text', class: 'mx-quickadd__input', autocomplete: 'off', spellcheck: 'false',
        placeholder: _('Optional, public IP:port, comma separated, e.g. 203.0.113.7:40000'), value: (r.static_endpoints ?? []).join(', ')
    });
    const ddns = E('input', {
        type: 'text', class: 'mx-quickadd__input', autocomplete: 'off', spellcheck: 'false',
        placeholder: _('Optional, resolved every 5 minutes, e.g. home.example.com'), value: r.ddns_host ?? ''
    });
    const share = E('select', { class: 'cbi-input-select' }, [
        E('option', { value: 'self' }, _('Only my devices')),
        E('option', { value: 'all' }, _('Everyone in the network'))
    ]);
    share.value = r.share == 'all' ? 'all' : 'self';
    const err = E('div', { class: 'mx-account__error', hidden: '' });
    const save = (button) => meowx.busy(button, () => meowx.mesh('relay_set', {
        enabled: enabled.checked, port: +port.value || 40000,
        static_endpoints: eps.value.split(/[\s,，]+/).map((x) => x.trim()).filter((x) => x),
        ddns_host: ddns.value.trim(), share: dr.can_share ? share.value : (r.share || 'self')
    }).then((res) => {
        if (res?.success === false) {
            err.textContent = res.error || _('Operation failed');
            err.hidden = false;
            return;
        }
        err.hidden = true;
        // 路由器在后台按新配置对账（tailscale set + 补报），几秒后再取一次
        setTimeout(ctx.refresh, 8000);
        ctx.refresh();
    }, (e) => {
        err.textContent = String(e?.message ?? e);
        err.hidden = false;
    }));

    // 状态：以本机上次上报拿到的为准（3 分钟内），否则用主控的
    const fresh = last?.state && last.at && (Date.now() / 1000 - last.at) < 180;
    const state = fresh ? last.state : (r.state || (r.enabled ? 'pending' : 'disabled'));
    const message = fresh ? last.message : r.message;
    children.push(E('label', { class: 'mx-mesh__check' }, [enabled, E('span', {}, _('Act as a MeowNest relay')),
        E('span', { class: 'mx-po0__token' }, (relayStates[state]?.() ?? state) + (message ? ' · ' + message : ''))]));
    if (last?.error) {
        children.push(E('div', { class: 'mx-po0__note' }, last.error));
    }
    children.push(E('div', { class: 'mx-quickadd' }, [E('span', { class: 'mx-po0__token' }, _('UDP port')), port]));
    children.push(E('div', { class: 'mx-quickadd' }, [E('span', { class: 'mx-po0__token' }, _('Static addresses')), eps]));
    children.push(E('div', { class: 'mx-quickadd' }, [E('span', { class: 'mx-po0__token' }, _('DDNS host')), ddns]));
    if (dr.can_share) {
        children.push(E('div', { class: 'mx-quickadd' }, [E('span', { class: 'mx-po0__token' }, _('Who can use it')), share]));
    }
    children.push(E('div', { class: 'mx-account__actions' }, [E('button', {
        type: 'button', class: 'cbi-button cbi-button-action', click: (ev) => save(ev.currentTarget)
    }, _('Save'))]));
    children.push(err);

    // 端口映射与 NAT
    if (r.enabled) {
        children.push(E('div', { class: 'mx-po0__note' }, _('If this router is behind another router, forward UDP %d on the upstream router to this router. If the public address or port differs after forwarding, add the forwarded public IP:port to the static addresses so the panel can recognize this relay before sessions are reported.').format(+port.value || r.port || 40000)));
        const net = ctx.net;
        if (net?.success) {
            if (net.mapping_varies === true) {
                children.push(E('div', { class: 'mx-account__error' }, _('This network is hard to reach from outside (the NAT mapping changes per destination). Fill in a static address and set up port forwarding.')));
            }
            const seen = [net.global_v4, net.global_v6].filter((x) => x);
            if (seen.length > 0) {
                children.push(E('div', { class: 'mx-po0__note' }, _('Public address seen by the relay servers: %s').format(seen.join(', '))));
            }
        } else if (net === null) {
            children.push(E('div', { class: 'mx-po0__note' }, [E('span', { class: 'spinning' }, _('Checking NAT…'))]));
        }
    }

    // 正在经本机中继：主控按会话对出两端名称；主控读不到时用本机的会话（只有外网地址与流量）
    const relays = ctx.paths?.paths?.relays ?? [];
    const mine = relays.find((x) => String(x.device_id) == String(info.device_id));
    const sessions = mine?.sessions ?? [];
    const local = ctx.paths?.local ?? (ctx.paths?.paths?.success === false ? info.local : null);
    if (mine && (sessions.length > 0 || mine.unmatched_sessions > 0)) {
        children.push(E('div', { class: 'mx-po0__group' }, _('Relaying through this router (%d)').format(sessions.length)));
        const end = (x) => x?.type == 'other' ? _('Other user') : (x?.name || '?');
        children.push(E('div', { class: 'mx-po0__list' }, sessions.map((x) => row(end(x.a) + ' ↔ ' + end(x.b), meowx.formatBytes(x.bytes ?? 0)))));
        if (mine.unmatched_sessions > 0) {
            children.push(E('div', { class: 'mx-po0__note' }, _('Plus %d unrecognized connection(s)').format(mine.unmatched_sessions)));
        }
    } else if (local?.sessions?.length > 0) {
        children.push(E('div', { class: 'mx-po0__group' }, _('Relaying through this router (%d)').format(local.sessions.length)));
        // 两端按本机设备列表里各设备上报的公网端点对出名字，对不出的显示地址
        const peers = st.peers ?? [];
        children.push(E('div', { class: 'mx-po0__list' }, local.sessions.map((x) => {
            const c = x.clients ?? [];
            return row(c.map((y) => endpointName(y.endpoint, peers) || y.endpoint || '?').join(' ↔ '), meowx.formatBytes(c.reduce((n, y) => n + (y.bytes_tx ?? 0), 0)));
        })));
        children.push(E('div', { class: 'mx-po0__note' }, _('The panel is unreachable: showing this router\'s own sessions, with device names matched from this router\'s device list (addresses when no match).')));
    }
    box.replaceChildren(...children);
}

function renderCard(initial) {
    const card = E('div', { class: 'mx-account mx-po0 mx-mesh' });
    let polling = false;
    // 主控那边的信息：单独一块，重画卡片时原样带上
    const panelBox = E('div', { class: 'mx-mesh__panel' });
    let panelShown = false;
    // 设备中继一节与「其它设备」也各自一块：路径 15 秒一刷，不重画整张卡（填了一半的表单不丢）
    const relayBox = E('div', { class: 'mx-mesh__relay' });
    const peersBox = E('div', { class: 'mx-mesh__peers' });
    const rc = { st: initial ?? {}, relay: null, paths: null, net: undefined, status: null };
    const redrawRelay = () => {
        renderRelay(relayBox, rc);
        renderPeers(peersBox, rc.st, rc.paths);
    };
    const relayOn = () => !!rc.status?.device_relay?.enabled && rc.st.settings?.enabled && rc.st.backend == 'Running';
    rc.refresh = () => meowx.mesh('relay').then((r) => {
        rc.relay = r;
        redrawRelay();
        // NAT 情况：中继开着时每次打开页面查一次（有网络开销，不进轮询）
        if (r?.relay?.enabled && rc.net === undefined) {
            rc.net = null;
            meowx.mesh('netcheck').then((n) => { rc.net = n; redrawRelay(); }, () => { rc.net = { success: false }; });
        }
    }, () => { });
    const refreshPaths = () => {
        if (!rc.st.settings?.enabled || rc.st.backend != 'Running' || document.hidden || !card.isConnected || card.offsetParent === null) {
            return Promise.resolve();
        }
        // 对端的实时路径也跟着刷新（页面别处只在应用时轮询 status）
        return Promise.all([meowx.mesh('paths'), L.resolveDefault(meowx.mesh('status'), null)]).then(([res, next]) => {
            rc.paths = res;
            if (next?.settings && !rc.st.applying && !polling) {
                rc.st = Object.assign({}, rc.st, { peers: next.peers, backend: next.backend, relay_last: next.relay_last });
            }
            redrawRelay();
        }, () => { });
    };
    let pathsTimer = null;
    const startPaths = () => {
        if (!pathsTimer) {
            pathsTimer = setInterval(refreshPaths, PATHS_MS);
        }
        refreshPaths();
    };
    rc.installStatic = () => meowx.mesh('install_static').then((res) => {
        if (res?.success === false) {
            ui.addNotification(null, E('p', {}, res.error || _('Operation failed')), 'danger');
            return;
        }
        draw(Object.assign({}, rc.st, { installing: true }));
    });
    const refreshPanel = () => {
        panelShown = true;
        return meowx.mesh('panel').then((info) => {
            renderPanel(panelBox, info, refreshPanel);
            rc.status = info?.view?.status ?? null;
            if (relayOn()) {
                rc.refresh();
                startPaths();
            } else {
                redrawRelay();
            }
        }, (e) => renderPanel(panelBox, { view: { success: false, error: String(e?.message ?? e) } }, refreshPanel));
    };

    const draw = (st) => {
        rc.st = st;
        const s = st.settings ?? {};
        const error = E('div', { class: 'mx-account__error', hidden: '' });
        const fail = (res) => {
            error.textContent = res?.error || _('Operation failed');
            error.hidden = false;
        };
        const ready = st.panel_logged_in && st.installed;

        // 应用在路由器后台跑：每 2 秒问一次，跑完（applied_at 变了、不在应用中）就重画
        const poll = (before, wantInstall) => {
            if (polling) {
                return;
            }
            polling = true;
            let n = 0;
            const tick = () => meowx.mesh('status').then((next) => {
                n++;
                const done = wantInstall
                    ? !next.installing
                    : (!next.applying && (next.state?.applied_at ?? 0) != (before ?? 0));
                if (done || n >= POLL_LIMIT) {
                    polling = false;
                    draw(next);
                    if (!wantInstall) {
                        refreshPanel();
                    } else if (relayOn()) {
                        rc.refresh();
                    }
                    return;
                }
                draw(Object.assign({}, next, wantInstall ? {} : { applying: true }));
                setTimeout(tick, POLL_MS);
            }, () => {
                polling = false;
            });
            setTimeout(tick, POLL_MS);
        };

        // 设置：局域网候选网段（勾选）+ 其它网段（手填）+ 总是映射 + 设备名 + 访问路由器本身
        const chosen = new Set(s.networks ?? []);
        const candidates = st.lan ?? [];
        const checks = candidates.map((n) => {
            const box = E('input', { type: 'checkbox', value: n.cidr });
            box.checked = chosen.has(n.cidr);
            return [box, E('label', { class: 'mx-mesh__check' }, [box, E('span', {}, n.cidr), E('span', { class: 'mx-po0__token' }, n.iface)])];
        });
        const extra = E('input', {
            type: 'text', class: 'mx-quickadd__input', autocomplete: 'off', spellcheck: 'false',
            placeholder: _('Other subnets, comma separated, e.g. 192.168.2.0/24'),
            value: (s.networks ?? []).filter((c) => !candidates.some((n) => n.cidr == c)).join(', ')
        });
        const forceMap = E('input', { type: 'checkbox' });
        forceMap.checked = !!s.force_map;
        const routerAccess = E('input', { type: 'checkbox' });
        routerAccess.checked = !!s.router_access;
        const lanAccess = E('input', { type: 'checkbox' });
        lanAccess.checked = !!s.lan_access;
        const name = E('input', {
            type: 'text', class: 'mx-quickadd__input', autocomplete: 'off', spellcheck: 'false',
            placeholder: st.hostname || 'openwrt', value: s.hostname ?? ''
        });

        const collect = (enabled) => ({
            enabled: enabled,
            networks: checks.filter(([box]) => box.checked).map(([box]) => box.value)
                .concat(extra.value.split(/[\s,，]+/).map((v) => v.trim()).filter((v) => v)),
            force_map: forceMap.checked,
            router_access: routerAccess.checked,
            lan_access: lanAccess.checked,
            hostname: name.value.trim()
        });
        const save = (button, enabled) => meowx.busy(button, () =>
            meowx.mesh('save', collect(enabled)).then((res) => {
                if (!res?.success) {
                    return fail(res);
                }
                const before = st.state?.applied_at;
                draw(Object.assign({}, st, { applying: true, settings: Object.assign({}, s, collect(enabled)) }));
                poll(before, false);
            }, (err) => fail({ error: String(err?.message ?? err) })));

        const toggle = E('input', { type: 'checkbox', 'aria-label': _('MeowNest') });
        toggle.checked = !!s.enabled;
        toggle.disabled = !ready || !!st.applying;
        toggle.addEventListener('change', () => save(toggle, toggle.checked));   // busy() 会先禁用它

        const [label, cls] = stateLabel(st);
        const children = [
            E('div', { class: 'mx-po0__head' }, [
                E('div', { class: 'mx-po0__title' }, [
                    E('span', { class: 'mx-subcard__label' }, _('MeowNest')),
                    E('div', { class: 'mx-account__hint' }, _('Join the panel\'s MeowNest (Tailscale protocol) and expose this router\'s LAN to your other devices signed in with the same admin account, e.g. reach a NAS at home from your Mac outside. Admin accounts only.')),
                    ready ? E('div', { class: 'mx-status ' + cls }, [E('span', { class: 'mx-status__dot' }), E('span', {}, label)]) : ''
                ]),
                toggle
            ])
        ];

        if (!st.panel_logged_in) {
            children.push(E('div', { class: 'mx-po0__empty' }, _('Log in to the panel account on the App Config page first (an admin account of a panel with MeowNest turned on).')));
        } else if (!st.installed) {
            if (st.installing) {
                children.push(E('div', { class: 'mx-po0__group' }, [E('span', { class: 'spinning' }, _('Installing tailscale…'))]));
                if (!polling) {
                    poll(null, true);
                }
            } else {
                const enough = (st.free_kb ?? 0) >= (st.need_kb ?? 0);
                children.push(E('div', { class: 'mx-po0__empty' }, _('This router needs the official tailscale program (about %d MB of storage, %d MB free).').format(mb(st.need_kb), mb(st.free_kb))));
                children.push(E('div', { class: 'mx-account__actions' }, [
                    E('button', {
                        type: 'button',
                        class: 'cbi-button cbi-button-action',
                        disabled: enough ? null : '',
                        click: (ev) => meowx.busy(ev.currentTarget, () => meowx.mesh('install').then((res) => {
                            if (!res?.success) {
                                return fail(res);
                            }
                            draw(Object.assign({}, st, { installing: true }));
                        }))
                    }, _('Install tailscale'))
                ]));
                if (!enough) {
                    children.push(E('div', { class: 'mx-po0__note' }, _('Not enough storage. Free up space or use a router with more flash.')));
                }
            }
            if (st.install_log && !st.installing && /exit [1-9]/.test(st.install_log)) {
                children.push(E('pre', { class: 'mx-mesh__log' }, st.install_log));
            }
        } else {
            // 本机在喵窝里
            if (st.self?.ip && s.enabled) {
                children.push(E('div', { class: 'mx-po0__list' }, [
                    row(st.self.ip, [st.self.dns_name, st.self.relay ? _('Relay %s').format(st.self.relay) : ''].filter((x) => x).join(' · '),
                        st.version ? E('span', { class: 'mx-po0__token' }, 'tailscale ' + st.version) : '')
                ]));
            }
            if (st.state?.error && !st.applying) {
                children.push(E('div', { class: 'mx-account__error' }, st.state.error));
            }
            // 装 MeowX 提供的 tailscale（静态包）时：等它装完；失败的日志
            if (st.installing && !polling) {
                poll(null, true);
            }
            if (st.install_log && !st.installing && /exit [1-9]/.test(st.install_log)) {
                children.push(E('pre', { class: 'mx-mesh__log' }, st.install_log));
            }
            // 主控那边的喵窝信息 + 白名单直连开关（第一次画时去取）
            children.push(panelBox);
            if (!panelShown) {
                renderPanel(panelBox, null, refreshPanel);
                refreshPanel();
            }
            // 自检：tailscale0 的喵窝地址 / 路由丢了（后台会重启 tailscaled 修一次）
            if (s.enabled && !st.applying && st.tun && !st.tun.ok) {
                children.push(E('div', { class: 'mx-account__error' }, st.healing
                    ? _('tailscale0 has lost its MeowNest address or routes; restarting tailscaled to fix it…')
                    : (st.state?.warning || _('tailscale0 has lost its MeowNest address or routes.'))));
            }

            // 开放的网段（主控返回的结果：原样 / 映射段）
            const sites = st.state?.sites ?? [];
            if (s.enabled && sites.length > 0) {
                children.push(E('div', { class: 'mx-po0__group' }, _('Exposed subnets (%d)').format(sites.length)));
                children.push(E('div', { class: 'mx-po0__list' }, sites.map((x) => row(
                    x.mapped ? x.advertised : x.original,
                    x.mapped ? _('Mapped from %s (the subnet is already used in MeowNest; host part unchanged)').format(x.original) : _('As is'),
                    x.mapped ? E('span', { class: 'mx-badge' }, _('Mapped')) : ''
                ))));
            }

            // 设置
            children.push(E('div', { class: 'mx-po0__group' }, _('LAN subnets to expose')));
            if (checks.length > 0) {
                children.push(E('div', { class: 'mx-mesh__checks' }, checks.map(([, l]) => l)));
            }
            children.push(E('div', { class: 'mx-quickadd' }, [extra]));
            children.push(E('label', { class: 'mx-mesh__check' }, [forceMap, E('span', {}, _('Always map (use a block from the panel\'s mapping pool even without conflicts)'))]));
            children.push(E('label', { class: 'mx-mesh__check' }, [routerAccess, E('span', {}, _('Allow mesh devices to access this router itself (LuCI, SSH…)'))]));
            children.push(E('label', { class: 'mx-mesh__check' }, [lanAccess, E('span', {}, _('Let LAN devices reach other sites (subnets exposed by your other routers)'))]));
            children.push(E('div', { class: 'mx-po0__note' }, _('Turn this on at both sites for two-way access between their LANs. If this router is not the LAN gateway (side router), add static routes on the main router sending the other sites\' subnets to this router.')));
            children.push(E('div', { class: 'mx-po0__group' }, _('Device name')));
            children.push(E('div', { class: 'mx-quickadd' }, [name, E('button', {
                type: 'button',
                class: 'cbi-button cbi-button-action',
                disabled: st.applying ? '' : null,
                click: (ev) => save(ev.currentTarget, toggle.checked)
            }, s.enabled ? _('Save & Apply') : _('Save'))]));
            children.push(error);

            // 设备中继（主控开放了才有内容）
            children.push(relayBox);
            // 本账号的其它设备（路径按 §2.4：本机实时值 + 主控补名字）
            children.push(peersBox);
            redrawRelay();

            if (s.enabled || st.self?.id) {
                children.push(E('div', { class: 'mx-account__actions' }, [
                    E('button', {
                        type: 'button',
                        class: 'cbi-button cbi-button-negative',
                        click: () => ui.showModal(_('Leave MeowNest?'), [
                            E('p', {}, _('This router is removed from MeowNest on the panel and its exposed subnets are withdrawn. Turn the switch on again to rejoin.')),
                            E('div', { class: 'right' }, [
                                E('button', { type: 'button', class: 'cbi-button', click: ui.hideModal }, _('Cancel')),
                                ' ',
                                E('button', {
                                    type: 'button',
                                    class: 'cbi-button cbi-button-negative',
                                    click: (ev) => meowx.busy(ev.currentTarget, () => meowx.mesh('leave').then(() => {
                                        ui.hideModal();
                                        const before = st.state?.applied_at;
                                        draw(Object.assign({}, st, { applying: true }));
                                        poll(before, false);
                                    }))
                                }, _('Leave'))
                            ])
                        ])
                    }, _('Leave MeowNest'))
                ]));
            }
        }
        if (!children.includes(error)) {
            children.push(error);
        }
        children.push(E('div', { class: 'mx-po0__note' }, _('Devices reach the exposed subnets through MeowNest; when a subnet is already used by another router it is mapped to a block from the panel\'s mapping pool. Direct connections need UDP; when both ends are behind strict NAT, traffic goes through the relay chosen on the panel (end-to-end encrypted).')));
        card.replaceChildren(...children);
        // 打开页面时路由器正在应用（别的标签页点的、或刚开开关）：接着等它跑完
        if (st.applying && !polling) {
            poll(st.state?.applied_at, false);
        }
    };

    draw(initial ?? {});
    card.redraw = draw;
    card.refreshPanel = () => (panelShown ? refreshPanel() : Promise.resolve());
    card.stopPaths = () => {
        clearInterval(pathsTimer);
        pathsTimer = null;
    };
    card.startPaths = () => {
        if (relayOn()) {
            startPaths();
        }
    };
    return card;
}

return baseclass.extend({
    load: function () {
        return L.resolveDefault(meowx.mesh('status'), {});
    },
    render: function (status) {
        this.shown = JSON.stringify(status);
        this.card = renderCard(status);
        const map = E('div', { id: 'cbi-meowx', class: 'cbi-map' });
        return meowx.decorate(map, { hero: [E('div', { class: 'mx-cards' }, [this.card])] });
    },
    onShow: function () {
        // 在「插件配置」里登录 / 退出主控会改这页能不能用；状态没变就不重画（填了一半的网段不丢）
        return meowx.mesh('status').then((status) => {
            const key = JSON.stringify(status);
            if (key != this.shown) {
                this.shown = key;
                this.card.redraw(status);
            }
            this.card.refreshPanel();
            this.card.startPaths();
        });
    },
    onHide: function () {
        // 切走就停掉 15 秒一次的路径轮询
        this.card?.stopPaths();
    }
});
