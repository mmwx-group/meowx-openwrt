'use strict';
'require form';
'require baseclass';
'require uci';
'require fs';
'require tools.meowx as meowx';

// 页面模块：由 main.js 在页内切换时加载、渲染（不再是独立视图，切页签不刷新页面）
return baseclass.extend({
    load: function () {
        return Promise.all([
            uci.load('meowx'),
            meowx.listProfiles(),
            meowx.listRuleProviders(),
            meowx.listProxyProviders(),
        ]);
    },
    render: function (data) {
        const subscriptions = uci.sections('meowx', 'subscription');
        const profiles = data[1];
        const ruleProviders = data[2];
        const proxyProviders = data[3];

        let m, s, o;

        m = new form.Map('meowx');

        s = m.section(form.NamedSection, 'editor', 'editor', _('Editor'));

        o = s.option(form.ListValue, '_file', _('Choose File'));
        o.optional = true;

        for (const profile of profiles) {
            o.value(meowx.profilesDir + '/' + profile.name, _('File:') + profile.name);
        };

        for (const subscription of subscriptions) {
            o.value(meowx.subscriptionsDir + '/' + subscription['.name'] + '.yaml', _('Subscription:') + subscription.name);
        };

        for (const ruleProvider of ruleProviders) {
            o.value(meowx.ruleProvidersDir + '/' + ruleProvider.name, _('Rule Provider:') + ruleProvider.name);
        };

        for (const proxyProvider of proxyProviders) {
            o.value(meowx.proxyProvidersDir + '/' + proxyProvider.name, _('Proxy Provider:') + proxyProvider.name);
        };

        o.value(meowx.mixinFilePath, _('File for Mixin'));
        o.value(meowx.runProfilePath, _('Profile for Startup'));

        o.write = function (section_id, formvalue) {
            return true;
        };
        o.onchange = function (event, section_id, value) {
            return L.resolveDefault(fs.read_direct(value), '').then(function (content) {
                m.lookupOption('_file_content', section_id)[0].getUIElement(section_id).setValue(content);
            });
        };

        o = s.option(form.TextValue, '_file_content',);
        o.rows = 25;
        o.wrap = false;
        o.write = function (section_id, formvalue) {
            const path = m.lookupOption('_file', section_id)[0].formvalue(section_id);
            return meowx.writefile(path, formvalue);
        };
        o.remove = function (section_id) {
            const path = m.lookupOption('_file', section_id)[0].formvalue(section_id);
            return meowx.writefile(path);
        };

        return meowx.decorate(m.render());
    },
    // 编辑器改的是文件、不是 uci，保存后要自己重载 / 重启服务（main.js 在当前页是编辑器时转给它）
    afterSaveApply: function (mode) {
        return mode === '0' ? meowx.reload() : meowx.restart();
    }
});
