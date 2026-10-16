'use strict';
'require baseclass';
'require uci';
'require fs';
'require rpc';
'require request';

const callRCList = rpc.declare({
    object: 'rc',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

const callRCInit = rpc.declare({
    object: 'rc',
    method: 'init',
    params: ['name', 'action'],
    expect: { '': {} }
});

const callFileWrite = rpc.declare({
    object: 'file',
    method: 'write',
    params: ['path', 'data', 'append', 'mode']
});

const callMeowXVersion = rpc.declare({
    object: 'luci.meowx',
    method: 'version',
    expect: { '': {} }
});

const callMeowXProfile = rpc.declare({
    object: 'luci.meowx',
    method: 'profile',
    params: ['defaults'],
    expect: { '': {} }
});

const callMeowXUpdateSubscription = rpc.declare({
    object: 'luci.meowx',
    method: 'update_subscription',
    params: ['section_id'],
    expect: { '': {} }
});

const callMeowXAPI = rpc.declare({
    object: 'luci.meowx',
    method: 'api',
    params: ['method', 'path', 'query', 'body'],
    expect: { '': {} }
});

const callMeowXGetIdentifiers = rpc.declare({
    object: 'luci.meowx',
    method: 'get_identifiers',
    expect: { '': {} }
});

const callMeowXDebug = rpc.declare({
    object: 'luci.meowx',
    method: 'debug',
    expect: { '': {} }
});

const homeDir = '/etc/meowx';
const profilesDir = `${homeDir}/profiles`;
const subscriptionsDir = `${homeDir}/subscriptions`;
const mixinFilePath = `${homeDir}/mixin.yaml`;
const runDir = `${homeDir}/run`;
const runProfilePath = `${runDir}/config.yaml`;
const providersDir = `${runDir}/providers`;
const ruleProvidersDir = `${providersDir}/rule`;
const proxyProvidersDir = `${providersDir}/proxy`;
const logDir = `/var/log/meowx`;
const appLogPath = `${logDir}/app.log`;
const coreLogPath = `${logDir}/core.log`;
const debugLogPath = `${logDir}/debug.log`;
const nftDir = `${homeDir}/nftables`;

return baseclass.extend({
    homeDir: homeDir,
    profilesDir: profilesDir,
    subscriptionsDir: subscriptionsDir,
    mixinFilePath: mixinFilePath,
    runDir: runDir,
    runProfilePath: runProfilePath,
    ruleProvidersDir: ruleProvidersDir,
    proxyProvidersDir: proxyProvidersDir,
    appLogPath: appLogPath,
    coreLogPath: coreLogPath,
    debugLogPath: debugLogPath,

    status: async function () {
        return (await callRCList('meowx'))?.meowx?.running;
    },

    reload: function () {
        return callRCInit('meowx', 'reload');
    },

    restart: function () {
        return callRCInit('meowx', 'restart');
    },

    writefile: function (path, data, mode) {
        data = (data != null) ? String(data) : '';
        mode = (mode != null) ? mode : 0o644;

        const encoder = new TextEncoder();
        const decoder = new TextDecoder();
        const chunkSize = 8 * 1024;

        const bytes = encoder.encode(data);

        if (bytes.length <= chunkSize) {
            return callFileWrite(path, data, false, mode);
        }

        let promise = Promise.resolve();
        for(let offset = 0; offset < bytes.length; offset += chunkSize) {
            const chunkStart = offset;
            const chunkEnd = Math.min(offset + chunkSize, bytes.length);
            const isLastChunk = chunkEnd === bytes.length;
            const chunkBytes = bytes.slice(chunkStart, chunkEnd);
            const chunk = decoder.decode(chunkBytes, { stream: !isLastChunk });
            const append = offset > 0;
            promise = promise.then(() => callFileWrite(path, chunk, append, mode));
        }

        return promise;
    },

    version: function () {
        return callMeowXVersion();
    },

    profile: function (defaults) {
        return callMeowXProfile(defaults);
    },

    updateSubscription: function (section_id) {
        return callMeowXUpdateSubscription(section_id);
    },

    updateDashboard: function () {
        return callMeowXAPI('POST', '/upgrade/ui');
    },

    openDashboard: async function () {
        const profile = await callMeowXProfile({
            'external-ui-name': null,
            'external-controller': null,
            'external-controller-tls': null,
            'secret': null
        });
        const uiName = profile['external-ui-name'];
        const apiListen = profile['external-controller'];
        const apiTLSListen = profile['external-controller-tls'];
        const apiSecret = profile['secret'] ?? '';
        if (!apiListen && !apiTLSListen) {
            return Promise.reject('API has not been configured');
        }

        let protocol;
        let port;
        if (apiTLSListen) {
            protocol = 'https';
            port = apiTLSListen.substring(apiTLSListen.lastIndexOf(':') + 1);
        } else {
            protocol = 'http';
            port = apiListen.substring(apiListen.lastIndexOf(':') + 1);
        }

        const params = {
            host: window.location.hostname,
            hostname: window.location.hostname,
            port: port,
            secret: apiSecret
        };
        const query = new URLSearchParams(params).toString();
        let url;
        if (uiName) {
            url = `${protocol}://${window.location.hostname}:${port}/ui/${uiName}/?${query}`;
        } else {
            url = `${protocol}://${window.location.hostname}:${port}/ui/?${query}`;
        }

        setTimeout(function () { window.open(url, '_blank') }, 0);

        return Promise.resolve();
    },

    getIdentifiers: function () {
        return callMeowXGetIdentifiers();
    },

    listProfiles: function () {
        return L.resolveDefault(fs.list(this.profilesDir), []);
    },

    listRuleProviders: function () {
        return L.resolveDefault(fs.list(this.ruleProvidersDir), []);
    },

    listProxyProviders: function () {
        return L.resolveDefault(fs.list(this.proxyProvidersDir), []);
    },

    getAppLog: function () {
        return L.resolveDefault(fs.read_direct(this.appLogPath));
    },

    getCoreLog: function () {
        return L.resolveDefault(fs.read_direct(this.coreLogPath));
    },

    clearAppLog: function () {
        return this.writefile(this.appLogPath, '');
    },

    clearCoreLog: function () {
        return this.writefile(this.coreLogPath, '');
    },

    debug: function () {
        return callMeowXDebug();
    },

    // MeowX 页面主题（view/meowx/meowx.css，与客户端同一套设计语言）：注入样式、按主题实际底色定深浅、
    // 卡片错峰进场。每个页面 render 都经它：return meowx.decorate(m.render(), { hero })。
    decorate: function (rendered, options) {
        options = options || {};
        // 样式表每次按 no-cache 取（uhttpd 有 ETag，没变只回 304）：LuCI 的 resource_version 升级我们的包时不一定变，
        // 用 <link> 会一直拿缓存里的旧样式。页面等样式就位再出来，不闪一下无样式的样子。
        if (!this.themeReady) {
            this.themeReady = fetch(L.resource('view/meowx/meowx.css'), { cache: 'no-cache', credentials: 'same-origin' })
                .then(function (res) { return res.ok ? res.text() : ''; })
                .then(function (css) { document.head.appendChild(E('style', { id: 'mx-css' }, css)); })
                .catch(function () { });
        }
        // 先读主题自己的底色（加 .mx-page 之前），按亮度判断深浅：不依赖 bootstrap / argon 等各自的深色写法
        if (!document.body.classList.contains('mx-page')) {
            const rgb = (getComputedStyle(document.body).backgroundColor.match(/\d+(\.\d+)?/g) || ['255', '255', '255']).map(Number);
            const transparent = rgb.length > 3 && rgb[3] === 0;
            const luma = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
            document.body.classList.toggle('mx-dark', !transparent && luma < 0.45);
            document.body.classList.add('mx-page');
        }
        return Promise.all([rendered, this.themeReady]).then(function (results) {
            const node = results[0];
            const map = node.id === 'cbi-meowx' ? node : node.querySelector('#cbi-meowx');
            if (!map) {
                return node;
            }
            map.classList.add('mx');
            // 窄屏页签单行滑动：当前页签不在视野里时滚到中间
            const active = document.querySelector('#tabmenu .tabs > li.active');
            if (active && active.parentNode.scrollWidth > active.parentNode.clientWidth) {
                active.parentNode.scrollLeft = active.offsetLeft - (active.parentNode.clientWidth - active.offsetWidth) / 2;
            }
            if (options.hero) {
                map.classList.add('mx-has-hero');
                const descr = map.querySelector(':scope > .cbi-map-descr');
                map.insertBefore(options.hero, descr ? descr.nextSibling : map.firstChild);
            }
            // 只给前 12 张卡错峰，后面的随第 12 张一起出来（同客户端节点卡的 StaggerIn）；页面在后台时不播，直接显示
            if (document.hidden) {
                return node;
            }
            const cards = map.querySelectorAll(':scope > .mx-hero, :scope > .cbi-section, :scope > .cbi-section-create');
            cards.forEach(function (card, i) {
                card.style.setProperty('--mx-i', Math.min(i, 12));
                card.classList.add('mx-enter');
            });
            return node;
        });
    },

    // 按钮执行期间转圈、禁止重复点；结束（成功或失败）恢复
    busy: function (button, action) {
        if (button.disabled) {
            return Promise.resolve();
        }
        button.disabled = true;
        button.classList.add('spinning');
        return Promise.resolve().then(action).finally(function () {
            button.disabled = false;
            button.classList.remove('spinning');
        });
    },
})
