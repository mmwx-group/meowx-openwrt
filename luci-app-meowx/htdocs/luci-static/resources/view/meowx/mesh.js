'use strict';
'require baseclass';
'require ui';
'require tools.meowx as meowx';

// 「喵窝」页：路由器用官方 tailscale 程序加入主控的喵窝（Tailscale 协议），把局域网开放给同一管理员账号的其它设备。
// 点了就生效（同 po0 卡片）：开关 / 「保存并应用」把设置交给路由器后台入网，页面每 2 秒问一次状态直到应用完。
// 入网 key 由路由器向主控要（要先在「插件配置」里登录主控账户），防火墙、网段映射由 mesh_cli.uc 写进 fw4。

const POLL_MS = 2000;
const POLL_LIMIT = 60;   // 最多等 2 分钟（tailscale up 自己最长 60 秒）

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

function renderCard(initial) {
    const card = E('div', { class: 'mx-account mx-po0 mx-mesh' });
    let polling = false;

    const draw = (st) => {
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

            // 本账号的其它设备
            const peers = st.peers ?? [];
            if (s.enabled && st.backend == 'Running') {
                children.push(E('div', { class: 'mx-po0__group' }, _('Other devices (%d)').format(peers.length)));
                if (peers.length == 0) {
                    children.push(E('div', { class: 'mx-po0__empty' }, _('No other devices yet. Turn on "MeowNest" in MeowX signed in with the same admin account.')));
                } else {
                    children.push(E('div', { class: 'mx-po0__list' }, peers.map((p) => row(
                        [E('span', { class: 'mx-mesh__dot' + (p.online ? ' is-online' : '') }), ' ', p.name || p.dns_name],
                        [p.ip, (p.routes ?? []).join(', '), p.online ? (p.direct ? _('Direct') : (p.active === false ? _('Idle') : (p.relay ? _('Via relay %s').format(p.relay) : ''))) : _('Offline')].filter((x) => x).join(' · ')
                    ))));
                }
            }

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
        });
    }
});
