'use strict';
'require baseclass';
'require tools.meowx as meowx';

// 「辅助功能」页：放不属于代理配置本身的小工具（目前是 po0 加白）。不是表单，没有要「保存并应用」的东西，
// 每个操作点了就生效。由 main.js 在页内切换时加载；切回来时 onShow 重取一次状态（在「插件配置」里登录 / 退出会改主控登记的 po0）
return baseclass.extend({
    load: function () {
        return Promise.all([
            meowx.panelStatus(),
            meowx.po0Status()
        ]);
    },
    render: function (data) {
        this.shown = JSON.stringify(data);
        this.cards = E('div', { class: 'mx-cards' }, meowx.renderPo0Card(data[1], !!data[0]?.logged_in));
        const map = E('div', { id: 'cbi-meowx', class: 'cbi-map' });
        return meowx.decorate(map, { hero: [this.cards] });
    },
    onShow: function () {
        // 状态没变就不重画（输入框里填了一半的地址 / token 不丢）
        return this.load().then((data) => {
            const key = JSON.stringify(data);
            if (key != this.shown) {
                this.shown = key;
                this.cards.replaceChildren(meowx.renderPo0Card(data[1], !!data[0]?.logged_in));
            }
        });
    }
});
