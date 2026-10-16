'use strict';
'require baseclass';
'require ui';
'require tools.meowx as meowx';

// 「关于」页：版本、开源地址、致谢。纯展示，没有要保存的东西
const repoURL = 'https://github.com/mmwx-group/meowx-openwrt';
const nikkiURL = 'https://github.com/nikkinikki-org/OpenWrt-nikki';
const coreURL = 'https://github.com/mmwx-group/meowC';
const mihomoURL = 'https://github.com/MetaCubeX/mihomo';

function link(url, text) {
    return E('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, text || url.replace(/^https:\/\//, ''));
}

// 整句翻译、链接用 %s 占位（LuCI 查翻译前会去掉首尾空白，句子拆成片段翻不上）
function sentence(text, nodes) {
    const parts = text.split('%s');
    return parts.flatMap((part, i) => i < nodes.length ? [part, nodes[i]] : [part]);
}

return baseclass.extend({
    load: function () {
        return meowx.version();
    },
    render: function (version) {
        const head = E('div', { class: 'mx-about__head' }, [
            E('span', { class: 'mx-hero__logo' }, [
                E('img', { class: 'mx-logo-light', alt: '', src: L.resource('view/meowx/logo-light.png') }),
                E('img', { class: 'mx-logo-dark', alt: '', src: L.resource('view/meowx/logo-dark.png') })
            ]),
            E('div', { class: 'mx-about__title' }, [
                E('div', { class: 'mx-about__name' }, 'MeowX for OpenWrt'),
                E('div', { class: 'mx-about__ver' }, _('Plugin %s · Core %s').format(version?.app || '-', version?.core || '-'))
            ])
        ]);
        const update = this.renderUpdate(version?.app);
        const open = E('div', { class: 'mx-account mx-about' }, [
            E('span', { class: 'mx-subcard__label' }, _('Open Source')),
            E('p', { class: 'mx-about__text' }, _('This project is open source under the GPL-3.0 license. Source code, issues and release notes are on GitHub:')),
            E('div', { class: 'mx-about__link' }, link(repoURL)),
            E('a', { class: 'cbi-button cbi-button-action mx-about__btn', href: repoURL, target: '_blank', rel: 'noopener noreferrer' }, _('View on GitHub'))
        ]);
        const thanks = E('div', { class: 'mx-account mx-about' }, [
            E('span', { class: 'mx-subcard__label' }, _('Acknowledgements')),
            E('p', { class: 'mx-about__text' }, sentence(
                _('MeowX for OpenWrt is built on %s. Its transparent proxy, mixin and service scripts all come from it. Many thanks to the nikki project and its authors.'),
                [link(nikkiURL, 'OpenWrt-nikki')])),
            E('p', { class: 'mx-about__text' }, sentence(
                _('The core is the MeowX fork of %s (source in %s), adding protocols such as Miu that upstream mihomo does not have.'),
                [link(mihomoURL, 'mihomo'), link(coreURL, 'meowC')]))
        ]);
        const map = E('div', { id: 'cbi-meowx', class: 'cbi-map' });
        return meowx.decorate(map, { hero: [E('div', { class: 'mx-cards' }, [E('div', { class: 'mx-account' }, [head, update]), open, thanks])] });
    },

    // 插件更新：打开「关于」时查一次 dl.miaomiaowux.com 的发布清单；有新版本给「更新到 x」按钮，路由器自己跑一遍
    // 一键安装脚本（opkg 装新 ipk 即升级，apk 带 --upgrade），装完自动刷新页面；失败时显示安装输出
    renderUpdate: function (installed) {
        const line = E('div', { class: 'mx-about__update' }, E('span', { class: 'mx-about__update-text' }, _('Checking for updates…')));
        const show = (text, button) => line.replaceChildren(...[E('span', { class: 'mx-about__update-text' }, text), button].filter(Boolean));
        const check = () => meowx.checkUpdate().then((res) => {
            if (!res?.success) {
                return show(_('Unable to check for updates'), E('button', { type: 'button', class: 'cbi-button', click: (ev) => meowx.busy(ev.currentTarget, check) }, _('Retry')));
            }
            if (!installed || meowx.compareVersion(res.latest, installed) <= 0) {
                return show(_('You are on the latest version'));
            }
            show(_('New version %s available').format(res.latest), E('button', {
                type: 'button',
                class: 'cbi-button cbi-button-action',
                click: (ev) => this.upgrade(ev.currentTarget, res.latest, installed, line)
            }, _('Update to %s').format(res.latest)));
        });
        check();
        return line;
    },

    upgrade: function (button, latest, installed, line) {
        if (!confirm(_('Update MeowX to %s? The page may be briefly unavailable while it installs; settings and subscriptions are kept.').format(latest))) {
            return;
        }
        return meowx.busy(button, () => meowx.upgrade().then(() => new Promise((resolve) => {
            // 升级会重载 rpcd，期间轮询可能失败：失败当作「还在装」，最多等 10 分钟
            const started = Date.now();
            const poll = () => meowx.upgradeStatus().then((st) => {
                if (st?.running && Date.now() - started < 600000) {
                    return setTimeout(poll, 2000);
                }
                resolve(st);
            }, () => setTimeout(poll, 3000));
            setTimeout(poll, 2000);
        })).then((st) => meowx.version().then((v) => {
            if (meowx.compareVersion(v?.app, installed) > 0) {
                ui.addNotification(null, E('p', _('Updated to %s, reloading the page…').format(v.app)), 'info');
                // LuCI 脚本地址里的 ?v= 只随 luci-base 变，插件升级后浏览器照样用缓存里的旧脚本：先把用过的 MeowX 脚本
                // 按原地址强制重新取一遍、写回缓存，再刷新页面
                const used = performance.getEntriesByType('resource').map((e) => e.name).filter((u) => /\/(view\/meowx|tools\/meowx)\b/.test(u));
                const query = (used.find((u) => u.includes('?v=')) || '').replace(/^[^?]*/, '');
                const modules = ['view/meowx/main', 'view/meowx/app', 'view/meowx/profile', 'view/meowx/mixin', 'view/meowx/proxy',
                    'view/meowx/editor', 'view/meowx/log', 'view/meowx/extras', 'view/meowx/about', 'tools/meowx'];
                const urls = [...new Set(used.concat(modules.map((m) => L.resource(m + '.js') + query)).map((u) => new URL(u, location.href).href))];
                Promise.all(urls.map((u) => fetch(u, { cache: 'reload', credentials: 'same-origin' }).catch(() => null)))
                    .finally(() => setTimeout(() => location.reload(), 800));
                return;
            }
            line.replaceChildren(
                E('span', { class: 'mx-about__update-text is-failed' }, _('Update failed')),
                E('pre', { class: 'mx-about__log' }, String(st?.log || '').trim() || _('No output')));
        })));
    }
});
