'use strict';
'require form';
'require view';
'require uci';
'require tools.meowx as meowx';

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('meowx')
        ]);
    },
    render: function (data) {
        let m, s, o, so;

        m = new form.Map('meowx');

        s = m.section(form.NamedSection, 'config', 'config', _('Profile'));

        o = s.option(form.FileUpload, '_upload_profile', _('Upload Profile'));
        o.browser = true;
        o.enable_download = true;
        o.root_directory = meowx.profilesDir;
        o.write = function (section_id, formvalue) {
            return true;
        };

        s = m.section(form.GridSection, 'subscription', _('Subscription'));
        s.renderSectionAdd = function () {
            // 加订阅只要一个链接（同客户端导入订阅），表格自带的「添加」要先填名字，换掉
            return meowx.renderQuickAdd(function () { return meowx.reloadMap(m); });
        };
        s.addremove = true;
        s.anonymous = true;
        s.sortable = true;
        s.modaltitle = _('Edit Subscription');

        // 列表里一格显示订阅名 + 用量 + 到期（同客户端「我的」里的订阅行），名字只在编辑弹窗里改
        // 每次渲染现读（切换后表单原地重画，不能用渲染开始时记下的值）
        const current = function () { return uci.get('meowx', 'config', 'profile') || ''; };
        o = s.option(form.DummyValue, '_info', _('Subscription'));
        o.modalonly = false;
        // 表格格子里显示的是 textvalue（不是 cfgvalue），返回节点直接放进去
        o.textvalue = function (section_id) {
            const section = uci.get('meowx', section_id) || {};
            return E('div', { class: 'mx-subrow' }, [
                E('div', { class: 'mx-subrow__title' }, E('span', { class: 'mx-subrow__name' }, meowx.subscriptionName(section))),
                meowx.renderUsage(section, function () {
                    return meowx.refreshSubscription(section_id).then(function () { return meowx.reloadMap(m); });
                })
            ]);
        };

        o = s.option(form.Button, '_use');
        o.editable = true;
        o.modalonly = false;
        o.inputstyle = 'action';
        o.inputtitle = _('Use');
        // LuCI 的表单按钮自己会转圈、禁止重复点（调 onclick 之前就把按钮禁用了），这里不能再套 busy()
        o.onclick = function (ev, section_id) {
            return meowx.switchProfile('subscription:' + section_id).then(function () { return meowx.reloadMap(m); });
        };
        o.renderWidget = function (section_id, option_index, cfgvalue) {
            if (current() == 'subscription:' + section_id) {
                return E('span', { class: 'mx-subrow__inuse' }, _('In Use'));
            }
            return form.Button.prototype.renderWidget.apply(this, arguments);
        };

        o = s.option(form.Value, 'name', _('Subscription Name'));
        o.modalonly = true;
        o.placeholder = _('Name is taken from the subscription automatically');

        o = s.option(form.Value, 'info_url', _('Subscription Info Url'));
        o.modalonly = true;

        o = s.option(form.Value, 'url', _('Subscription Url'));
        o.modalonly = true;
        o.rmempty = false;

        o = s.option(form.Value, 'user_agent', _('User Agent'));
        o.default = 'meowx';
        o.modalonly = true;
        o.rmempty = false;
        o.value('meowx', _('MeowX (official client)'));
        o.value('clash');
        o.value('clash.meta');
        o.value('mihomo');

        o = s.option(form.ListValue, 'prefer', _('Prefer'));
        o.default = 'remote';
        o.modalonly = true;
        o.rmempty = false;
        o.value('remote', _('Remote'));
        o.value('local', _('Local'));

        return meowx.decorate(m.render());
    }
});
