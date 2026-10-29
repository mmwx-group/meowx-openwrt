'use strict';
'require baseclass';
'require form';
'require uci';
'require ui';
'require tools.meowx as meowx';

// 「辅助功能」页：不属于代理配置本身的小工具——po0 加白与 GGY 加白（卡片，点了就生效）与 GitHub 加速（表单，「保存并应用」后生效；
// 2026-10 从「插件配置」挪过来）。由 main.js 在页内切换时加载；切回来时 onShow 重取两张卡的状态（在「插件配置」里登录 / 退出会改主控登记的 po0，
// 定时上报会更新 GGY 每个 token 上一次的结果）

function ghproxyTypeLabel(type) {
    return type == 'jsdelivr' ? 'jsDelivr' : (type == 'direct' ? _('Direct') : _('Prefix'));
}

// GitHub 加速的测速表（同 OpenClash 的加速地址表）：由路由器逐个测，延迟 ≤500 ms 绿、≤1000 ms 黄、更慢红，
// 失败显示「连接超时 / 无法访问」；每行「使用」把上面的选项换成这一行（保存并应用后生效）
function renderGhproxyTest(state, modeOption, sectionId) {
    const meta = E('span', { class: 'mx-ghproxy__meta' });
    const body = E('tbody');
    const current = function () {
        return modeOption.formvalue(sectionId) ?? modeOption.cfgvalue(sectionId) ?? 'off';
    };
    const use = function (value, url) {
        const select = modeOption.getUIElement(sectionId)?.node?.querySelector('select');
        if (!select) {
            return;
        }
        select.value = value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        draw();
        ui.addTimeLimitedNotification(null, E('p', _('Selected %s. Click "Save & Apply" at the bottom of the page to take effect.').format(url)), 5000, 'info');
    };
    const latencyCell = function (result) {
        if (!result) {
            return E('span', { class: 'mx-ghproxy__lat' }, '--');
        }
        if (result.status == 'ok') {
            const ms = +result.latency;
            return E('span', { class: 'mx-ghproxy__lat ' + (ms <= 500 ? 'is-fast' : ms <= 1000 ? 'is-medium' : 'is-slow') }, `${ms} ms`);
        }
        return E('span', { class: 'mx-ghproxy__lat is-error' }, result.status == 'timeout' ? _('Connection timed out') : _('Unreachable'));
    };
    const draw = function () {
        const results = {};
        for (const r of state.results ?? []) {
            results[r.url] = r;
        }
        const rows = [{ url: state.direct ?? 'https://raw.githubusercontent.com/', type: 'direct', value: 'off', title: _('No acceleration (direct)') }];
        for (const preset of state.presets ?? []) {
            rows.push({ url: preset.url, type: preset.type, value: preset.url });
        }
        for (const r of state.results ?? []) {
            if (r.custom) {
                rows.push({ url: r.url, type: r.type, value: 'custom', title: _('Custom Mirror') });
            }
        }
        const value = current();
        const auto = value == 'auto' ? state.auto : null;
        body.replaceChildren(...rows.map(function (row) {
            const inUse = row.value == value;
            const badges = [];
            if (auto?.url == row.url) {
                badges.push(E('span', { class: 'mx-ghproxy__badge' }, _('Auto selected')));
            }
            if (auto?.fallback?.url == row.url) {
                badges.push(E('span', { class: 'mx-ghproxy__badge is-muted' }, _('Release assets')));
            }
            return E('tr', { class: inUse ? 'is-current' : '' }, [
                E('td', { class: 'mx-ghproxy__url' }, [
                    row.title ? E('div', { class: 'mx-ghproxy__title' }, row.title) : '',
                    E('div', {}, row.url),
                    badges.length ? E('div', { class: 'mx-ghproxy__badges' }, badges) : ''
                ]),
                E('td', {}, ghproxyTypeLabel(row.type)),
                E('td', {}, latencyCell(results[row.url])),
                E('td', { class: 'mx-ghproxy__action' }, inUse
                    ? E('span', { class: 'mx-ghproxy__badge' }, _('In use'))
                    : E('button', { type: 'button', class: 'cbi-button', click: () => use(row.value, row.url) }, _('Use')))
            ]);
        }));
        meta.textContent = state.tested_at
            ? _('Last tested %s').format(meowx.relativeTime(state.tested_at))
            : _('Not tested yet. The router downloads the same small file through each mirror (5 seconds at most each).');
    };
    modeOption.onchange = function () {
        draw();
    };
    draw();
    return E('div', { class: 'mx-ghproxy' }, [
        E('div', { class: 'mx-ghproxy__bar' }, [
            E('button', {
                type: 'button',
                class: 'cbi-button cbi-button-action',
                click: function (ev) {
                    return meowx.busy(ev.currentTarget, function () {
                        return meowx.ghproxyTest().then(function (res) {
                            if (!res || res.error) {
                                throw new Error(res?.error ?? 'no response');
                            }
                            state = res;
                            draw();
                        }).catch(function (err) {
                            ui.addNotification(null, E('p', _('Speed test failed: %s').format(err?.message ?? err)), 'warning');
                        });
                    });
                }
            }, _('Test Now')),
            meta
        ]),
        E('div', { class: 'mx-ghproxy__scroll' }, E('table', { class: 'mx-ghproxy__table' }, [
            E('thead', {}, E('tr', {}, [
                E('th', {}, _('Mirror Address')),
                E('th', {}, _('Type')),
                E('th', {}, _('Latency')),
                E('th', {}, '')
            ])),
            body
        ]))
    ]);
}

function loadPo0() {
    return Promise.all([
        meowx.panelStatus(),
        meowx.po0Status(),
        meowx.ggyStatus()
    ]);
}

function renderCards(po0) {
    return [meowx.renderPo0Card(po0[1], !!po0[0]?.logged_in), meowx.renderGgyCard(po0[2])];
}

return baseclass.extend({
    load: function () {
        return Promise.all([
            loadPo0(),
            uci.load('meowx'),
            meowx.ghproxyStatus()
        ]);
    },
    render: function (data) {
        const po0 = data[0];
        this.shown = JSON.stringify(po0);
        this.cards = E('div', { class: 'mx-cards' }, renderCards(po0));

        let m, s, o;

        m = new form.Map('meowx');

        // GitHub 加速：面板、Geo 数据、规则集经加速地址下载（生成运行配置时改写，见 init 的 ghproxy_apply）
        const ghproxy = data[2] ?? {};
        s = m.section(form.NamedSection, 'ghproxy', 'ghproxy', _('GitHub Acceleration'),
            _('Download the web dashboard, GeoX data and rule sets hosted on GitHub through a mirror, so the first start does not time out. Third-party mirrors can change what they serve, and the dashboard is a web app running on your router, so this is off by default: turn it on only if you trust the mirror. Only these download addresses in the running config are rewritten (the subscription file is not changed); proxy providers and subscription addresses may contain tokens and never go through a mirror.'));

        o = s.option(form.ListValue, 'mode', _('Mirror'));
        o.value('off', _('No acceleration (direct)'));
        o.value('auto', _('Auto (fastest)'));
        for (const preset of ghproxy.presets ?? []) {
            o.value(preset.url, `${preset.url} · ${ghproxyTypeLabel(preset.type)}`);
        }
        o.value('custom', _('Custom Mirror'));
        o.default = 'off';
        o.rmempty = false;
        o.description = _('jsDelivr mirrors only serve files in repositories, so release assets such as the dashboard keep the original address. Auto tests the mirrors when the service starts (the result is kept for a day) and once a day, and uses the fastest reachable one (release assets then go through the fastest prefix mirror); when none is reachable it downloads directly.');
        const modeOption = o;

        o = s.option(form.Value, 'custom_url', _('Custom Mirror Address'));
        o.depends('mode', 'custom');
        o.placeholder = 'https://example.com/';
        o.validate = function (section_id, value) {
            value = (value ?? '').trim();
            if (value == '') {
                return _('Please enter the mirror address');
            }
            return /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?(\/[^\s?#]*)?$/i.test(value) ? true : _('Invalid address, the format is http(s)://host[/path]');
        };

        o = s.option(form.ListValue, 'custom_type', _('Mirror Type'));
        o.depends('mode', 'custom');
        o.value('auto', _('Detect from address'));
        o.value('prefix', _('Prefix (mirror + full original URL)'));
        o.value('jsdelivr', _('jsDelivr (gh/user/repo@branch/path)'));
        o.default = 'auto';

        o = s.option(form.DummyValue, '_speedtest', _('Speed Test'));
        o.renderWidget = function (section_id) {
            return renderGhproxyTest(ghproxy, modeOption, section_id);
        };

        return meowx.decorate(m.render(), { hero: [this.cards] });
    },
    onShow: function () {
        // 状态没变就不重画（输入框里填了一半的地址 / token 不丢）
        return loadPo0().then((po0) => {
            const key = JSON.stringify(po0);
            if (key != this.shown) {
                this.shown = key;
                this.cards.replaceChildren(...renderCards(po0));
            }
        });
    }
});
