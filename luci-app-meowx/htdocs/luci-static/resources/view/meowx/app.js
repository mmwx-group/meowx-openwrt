'use strict';
'require form';
'require view';
'require uci';
'require poll';
'require tools.meowx as meowx';

// 首页主卡：与客户端的连接主卡同一套样子（运行中樱粉底 + 状态点涟漪，未运行中性底）
function renderHero(appVersion, coreVersion, running) {
    // 浅 / 深两张 Logo 都放上，按 .mx-dark 显示一张（深浅色是 decorate() 定的，此时还没定）
    const logo = E('span', { class: 'mx-hero__logo' }, [
        E('img', { class: 'mx-logo-light', alt: '', src: L.resource('view/meowx/logo-light.png') }),
        E('img', { class: 'mx-logo-dark', alt: '', src: L.resource('view/meowx/logo-dark.png') })
    ]);
    const meta = [];
    if (coreVersion) {
        meta.push(`${_('Core Version')} ${coreVersion}`);
    }
    if (appVersion) {
        meta.push(`${_('App Version')} ${appVersion}`);
    }
    const action = function (title, handler, primary) {
        return E('button', {
            type: 'button',
            class: 'cbi-button' + (primary ? ' mx-primary' : ''),
            click: function (ev) {
                return meowx.busy(ev.currentTarget, handler);
            }
        }, title);
    };
    const hero = E('div', { class: 'mx-hero' }, [
        logo,
        E('div', { class: 'mx-hero__main' }, [
            E('div', { class: 'mx-hero__title' }, 'MeowX'),
            E('div', { class: 'mx-status' }, [E('span', { class: 'mx-status__dot' }), E('span', { class: 'mx-status__text' })]),
            E('div', { class: 'mx-hero__meta' }, meta.join(' · '))
        ]),
        E('div', { class: 'mx-hero__actions' }, [
            action(_('Reload Service'), function () { return meowx.reload(); }, true),
            action(_('Restart Service'), function () { return meowx.restart(); }),
            action(_('Open Dashboard'), function () { return meowx.openDashboard(); }),
            action(_('Update Dashboard'), function () { return meowx.updateDashboard(); })
        ])
    ]);
    return updateHero(hero, running);
}

// 首页订阅卡（同 iOS 首页订阅条）：当前订阅名 + 用量 + 到期，点「更新于…」直接刷新；「切换订阅」弹出菜单，
// 选了就切过去并重启生效；还没有订阅时直接给「粘贴链接添加」。
function renderSubscriptionCard(profiles) {
    const card = E('div', { class: 'mx-subcard' });
    // 刷新订阅之后原地重画（名字、用量、更新时间会变）
    const reload = function () {
        uci.unload('meowx');
        return uci.load('meowx').then(function () {
            card.replaceWith(renderSubscriptionCard(profiles));
        });
    };
    const current = uci.get('meowx', 'config', 'profile') || '';
    const subscriptions = uci.sections('meowx', 'subscription');
    const head = E('div', { class: 'mx-subcard__head' }, [E('span', { class: 'mx-subcard__label' }, _('Subscription'))]);
    card.appendChild(head);

    if (subscriptions.length == 0 && profiles.length == 0) {
        card.appendChild(E('div', { class: 'mx-subcard__empty' }, _('No subscription yet')));
        card.appendChild(meowx.renderQuickAdd(function (section_id) {
            return section_id ? meowx.switchProfile('subscription:' + section_id).then(function () { location.reload(); }) : reload();
        }));
        return card;
    }

    // 切换菜单：本机订阅在前、上传的配置文件在后（客户端是本机订阅在前、账户下未下载的在后）
    const items = [];
    for (const sub of subscriptions) {
        items.push({ value: 'subscription:' + sub['.name'], title: meowx.subscriptionName(sub), group: _('Subscription') });
    }
    for (const file of profiles) {
        items.push({ value: 'file:' + file.name, title: file.name, group: _('Local Files') });
    }
    const menu = E('div', { class: 'mx-menu', role: 'menu' });
    let lastGroup = null;
    for (const item of items) {
        if (item.group != lastGroup) {
            menu.appendChild(E('div', { class: 'mx-menu__group' }, item.group));
            lastGroup = item.group;
        }
        menu.appendChild(E('button', {
            type: 'button',
            class: 'mx-menu__item' + (item.value == current ? ' is-current' : ''),
            role: 'menuitemradio',
            'aria-checked': item.value == current ? 'true' : 'false',
            click: function (ev) {
                menu.classList.remove('is-open');
                if (item.value == current) {
                    return;
                }
                // 切完整页刷新：下面表单里的「选择配置文件」还是旧值，不刷新的话点「保存并应用」会把它写回去
                return meowx.busy(switcher, function () {
                    return meowx.switchProfile(item.value).then(function () { location.reload(); });
                });
            }
        }, item.title));
    }
    menu.appendChild(E('a', { class: 'mx-menu__item mx-menu__link', href: L.url('admin/services/meowx/profile') }, _('Manage Subscriptions')));
    const switcher = E('button', {
            type: 'button',
        class: 'mx-subcard__switch',
        'aria-haspopup': 'menu',
        click: function (ev) {
            ev.stopPropagation();
            menu.classList.toggle('is-open');
        }
    }, current ? _('Switch Subscription') : _('Choose Subscription'));
    document.addEventListener('click', function (ev) {
        if (!menu.contains(ev.target)) {
            menu.classList.remove('is-open');
        }
    });
    head.appendChild(E('div', { class: 'mx-subcard__switch-wrap' }, [switcher, menu]));

    const active = current.startsWith('subscription:') ? uci.get('meowx', current.slice(13)) : null;
    if (active) {
        card.appendChild(E('div', { class: 'mx-subcard__name' }, meowx.subscriptionName(active)));
        card.appendChild(meowx.renderUsage(active, function () {
            return meowx.refreshSubscription(active['.name']).then(reload);
        }));
    } else if (current.startsWith('file:')) {
        card.appendChild(E('div', { class: 'mx-subcard__name' }, current.slice(5)));
        card.appendChild(E('div', { class: 'mx-subcard__hint' }, _('Local Files')));
    } else {
        card.appendChild(E('div', { class: 'mx-subcard__empty' }, _('No profile selected')));
    }
    return card;
}

function updateHero(hero, running) {
    hero.classList.toggle('is-running', !!running);
    hero.querySelector('.mx-status__text').textContent = running ? _('Running') : _('Not Running');
    return hero;
}

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('meowx'),
            meowx.version(),
            meowx.status(),
            meowx.listProfiles()
        ]);
    },
    render: function (data) {
        const subscriptions = uci.sections('meowx', 'subscription');
        const appVersion = data[1].app ?? '';
        const coreVersion = data[1].core ?? '';
        const running = data[2];
        const profiles = data[3];

        let m, s, o;

        m = new form.Map('meowx', _('MeowX'), `${_('Transparent Proxy with Mihomo on OpenWrt.')}`);

        const hero = renderHero(appVersion, coreVersion, running);
        poll.add(function () {
            return L.resolveDefault(meowx.status()).then(function (running) {
                updateHero(hero, running);
            });
        });

        s = m.section(form.NamedSection, 'config', 'config', _('App Config'));

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;

        o = s.option(form.ListValue, 'profile', _('Choose Profile'));
        o.optional = true;

        for (const profile of profiles) {
            o.value('file:' + profile.name, _('File:') + profile.name);
        };

        for (const subscription of subscriptions) {
            o.value('subscription:' + subscription['.name'], _('Subscription:') + subscription.name);
        };

        o = s.option(form.Value, 'start_delay', _('Start Delay'));
        o.datatype = 'uinteger';
        o.placeholder = _('Start Immidiately');

        o = s.option(form.Flag, 'scheduled_restart', _('Scheduled Restart'));
        o.rmempty = false;

        o = s.option(form.Value, 'scheduled_restart_cron', _('Scheduled Restart Cron'));
        o.retain = true;
        o.rmempty = false;
        o.depends('scheduled_restart', '1');

        o = s.option(form.Flag, 'test_profile', _('Test Profile'));
        o.rmempty = false;

        o = s.option(form.Flag, 'core_only', _('Core Only'));
        o.rmempty = false;

        s = m.section(form.NamedSection, 'procd', 'procd', _('procd Config'));

        s.tab('general', _('General Config'));

        o = s.taboption('general', form.Flag, 'fast_reload', _('Fast Reload'));
        o.rmempty = false;

        s.tab('rlimit', _('RLIMIT Config'));

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_soft', _('Number of Processes Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_hard', _('Number of Processes Hard Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_soft', _('Address Space Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_hard', _('Address Space Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_soft', _('Heap Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_hard', _('Heap Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_soft', _('Stack Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_hard', _('Stack Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_soft', _('Number of Open Files Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_hard', _('Number of Open Files Hard Limit'));
        o.datatype = 'uinteger';

        s.tab('environment_variable', _('Environment Variable Config'));

        o = s.taboption('environment_variable', form.Value, 'env_go_max_procs', 'GOMAXPROCS');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.Value, 'env_go_mem_limit', 'GOMEMLIMIT');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.DynamicList, 'env_safe_paths', _('Safe Paths'));
        o.load = function (section_id) {
            return this.super('load', section_id)?.split(':');
        };
        o.write = function (section_id, formvalue) {
            this.super('write', section_id, formvalue?.join(':'));
        };

        o = s.taboption('environment_variable', form.Flag, 'env_disable_loopback_detector', _('Disable Loopback Detector'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_gso', _('Disable GSO of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_ecn', _('Disable ECN of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_skip_system_ipv6_check', _('Skip System IPv6 Check'));
        o.rmempty = false;

        return meowx.decorate(m.render(), { hero: [hero, renderSubscriptionCard(profiles)] });
    }
});
