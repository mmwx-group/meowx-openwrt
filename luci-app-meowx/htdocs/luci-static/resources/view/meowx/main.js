'use strict';
'require view';
'require tools.meowx as meowx';

// MeowX 只有这一个视图：顶部胶囊页签在页内切换六个页面（同系统页的选项卡），不跳页面、不闪。
// 页面第一次点开时加载渲染，之后留在页里隐藏：来回切不重新加载、没保存的修改不丢，「保存并应用」一起保存（同系统页）。
// 当前页签记在地址的 #锚点 里，后退键与刷新都停在原页。
const pages = [
    { id: 'config', title: _('App Config'), module: 'view.meowx.app' },
    { id: 'profile', title: _('Profile'), module: 'view.meowx.profile' },
    { id: 'mixin', title: _('Mixin Config'), module: 'view.meowx.mixin' },
    { id: 'proxy', title: _('Proxy Config'), module: 'view.meowx.proxy' },
    { id: 'editor', title: _('Editor'), module: 'view.meowx.editor' },
    { id: 'log', title: _('Log'), module: 'view.meowx.log' }
];

function pageFromHash() {
    const id = location.hash.replace(/^#/, '');
    return pages.some((p) => p.id == id) ? id : pages[0].id;
}

return view.extend({
    render: function () {
        this.panes = {};
        this.modules = {};
        this.tabs = E('div', { class: 'mx-tabs', role: 'tablist' }, [
            E('span', { class: 'mx-tabs__thumb', 'aria-hidden': 'true' }),
            ...pages.map((page) => E('button', {
                type: 'button',
                class: 'mx-tabs__item',
                role: 'tab',
                'data-page': page.id,
                click: () => this.show(page.id, true)
            }, page.title))
        ]);
        this.stage = E('div', { class: 'mx-stage' });
        window.addEventListener('hashchange', () => this.show(pageFromHash(), false));
        window.addEventListener('resize', () => this.moveThumb(false));
        const root = E('div', { class: 'mx-shell' }, [this.tabs, this.stage]);
        return this.show(pageFromHash(), false).then(() => {
            // LuCI 拿到 root 才插进页面，插进去之后才量得到页签宽度
            requestAnimationFrame(() => this.moveThumb(false));
            document.fonts?.ready.then(() => this.moveThumb(false));
            return root;
        });
    },

    // 切到某一页：没渲染过的先加载渲染；新页按页签顺序从左 / 右平推进来（同客户端切 Tab）
    show: function (id, fromClick) {
        if (this.current == id) {
            return Promise.resolve();
        }
        const previous = this.current;
        this.current = id;
        if (fromClick) {
            history.pushState(null, '', '#' + id);
        }
        this.tabs.querySelectorAll('.mx-tabs__item').forEach((item) => {
            const active = item.getAttribute('data-page') == id;
            item.classList.toggle('is-active', active);
            item.setAttribute('aria-selected', active ? 'true' : 'false');
        });
        this.moveThumb(!!previous);
        return this.pane(id).then((pane) => {
            if (this.current != id) {
                return;   // 加载期间又点了别的页签
            }
            const order = (pageId) => pages.findIndex((p) => p.id == pageId);
            const forward = previous == null || order(id) > order(previous);
            for (const [pageId, other] of Object.entries(this.panes)) {
                if (pageId != id) {
                    other.hidden = true;
                    other.classList.remove('mx-pane--from-left', 'mx-pane--from-right');
                }
            }
            pane.hidden = false;
            if (previous != null && !document.hidden) {
                pane.classList.remove('mx-pane--from-left', 'mx-pane--from-right');
                void pane.offsetWidth;   // 重新触发动画
                pane.classList.add(forward ? 'mx-pane--from-right' : 'mx-pane--from-left');
            }
        });
    },

    pane: function (id) {
        if (this.panes[id]) {
            return Promise.resolve(this.panes[id]);
        }
        if (!this.loading) {
            this.loading = {};
        }
        if (!this.loading[id]) {
            const page = pages.find((p) => p.id == id);
            const pane = E('div', { class: 'mx-pane', 'data-page': id, hidden: '' }, E('div', { class: 'spinning' }, _('Loading view…')));
            this.stage.appendChild(pane);
            this.loading[id] = L.require(page.module)
                .then((module) => {
                    this.modules[id] = module;
                    return Promise.resolve(module.load()).then((data) => module.render(data));
                })
                .then((node) => {
                    pane.replaceChildren(node);
                    this.panes[id] = pane;
                    return pane;
                }, (err) => {
                    pane.replaceChildren(E('p', { class: 'alert-message error' }, String(err?.message ?? err)));
                    this.panes[id] = pane;
                    return pane;
                });
        }
        return this.loading[id];
    },

    // 选中块滑到当前页签下面（客户端分段控件的滑块）
    moveThumb: function (animate) {
        const active = this.tabs.querySelector('.mx-tabs__item.is-active');
        const thumb = this.tabs.querySelector('.mx-tabs__thumb');
        if (!active || !thumb) {
            return;
        }
        thumb.classList.toggle('no-anim', !animate);
        thumb.style.width = active.offsetWidth + 'px';
        thumb.style.transform = `translateX(${active.offsetLeft}px)`;
        // 窄屏页签单行滑动：当前页签不在视野里时滚到中间
        if (this.tabs.scrollWidth > this.tabs.clientWidth) {
            this.tabs.scrollTo({ left: active.offsetLeft - (this.tabs.clientWidth - active.offsetWidth) / 2, behavior: animate ? 'smooth' : 'auto' });
        }
    },

    handleSaveApply: function (ev, mode) {
        const editor = this.current == 'editor' ? this.modules.editor : null;
        if (editor?.afterSaveApply) {
            return this.handleSave(ev).finally(() => editor.afterSaveApply(mode));
        }
        return this.super('handleSaveApply', [ev, mode]);
    }
});
