'use strict';
'require baseclass';
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
        return meowx.decorate(map, { hero: [E('div', { class: 'mx-cards' }, [E('div', { class: 'mx-account' }, head), open, thanks])] });
    }
});
