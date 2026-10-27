'use strict';
'require baseclass';
'require uci';
'require fs';
'require rpc';
'require request';
'require ui';

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

const callMeowXRefreshSubscription = rpc.declare({
    object: 'luci.meowx',
    method: 'refresh_subscription',
    params: ['section_id'],
    expect: { '': {} }
});

const callMeowXSwitchProfile = rpc.declare({
    object: 'luci.meowx',
    method: 'switch_profile',
    params: ['profile'],
    expect: { '': {} }
});

const callMeowXAddSubscription = rpc.declare({
    object: 'luci.meowx',
    method: 'add_subscription',
    params: ['url', 'name'],
    expect: { '': {} }
});

const callMeowXPanelStatus = rpc.declare({
    object: 'luci.meowx',
    method: 'panel_status',
    params: [],
    expect: { '': {} }
});

const callMeowXPanelLogin = rpc.declare({
    object: 'luci.meowx',
    method: 'panel_login',
    params: ['link'],
    expect: { '': {} }
});

const callMeowXPanelLogout = rpc.declare({
    object: 'luci.meowx',
    method: 'panel_logout',
    params: [],
    expect: { '': {} }
});

const callMeowXPanelProfile = rpc.declare({
    object: 'luci.meowx',
    method: 'panel_profile',
    params: [],
    expect: { '': {} }
});

const callMeowXPanelSubscriptions = rpc.declare({
    object: 'luci.meowx',
    method: 'panel_subscriptions',
    params: [],
    expect: { '': {} }
});

const callMeowXCheckUpdate = rpc.declare({
    object: 'luci.meowx',
    method: 'check_update',
    expect: { '': {} }
});

const callMeowXUpgrade = rpc.declare({
    object: 'luci.meowx',
    method: 'upgrade',
    expect: { '': {} }
});

const callMeowXUpgradeStatus = rpc.declare({
    object: 'luci.meowx',
    method: 'upgrade_status',
    expect: { '': {} }
});

const callMeowXDashboardStatus = rpc.declare({
    object: 'luci.meowx',
    method: 'dashboard_status',
    params: ['ui', 'name'],
    expect: { '': {} }
});

const callMeowXLastError = rpc.declare({
    object: 'luci.meowx',
    method: 'last_error',
    expect: { '': {} }
});

const callMeowXPo0 = rpc.declare({
    object: 'luci.meowx',
    method: 'po0',
    params: ['action', 'address', 'token', 'index'],
    expect: { '': {} }
});

const callMeowXGhproxy = rpc.declare({
    object: 'luci.meowx',
    method: 'ghproxy',
    params: ['action'],
    expect: { '': {} }
});

function formatBytes(n) {
    n = +n;
    if (!isFinite(n) || n < 0) {
        return '';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return (i == 0 || n >= 100 ? Math.round(n) : n.toFixed(1)) + ' ' + units[i];
}

// 后端给的原因句末带英文句号，套进翻译句子前去掉，免得出现「….。」
function stripPeriod(text) {
    return String(text ?? '').replace(/[.。]\s*$/, '');
}

function relativeTime(ts) {
    const diff = Math.max(0, Date.now() / 1000 - (+ts));
    if (diff < 60) {
        return _('just now');
    }
    if (diff < 3600) {
        return _('%d min ago').format(Math.floor(diff / 60));
    }
    if (diff < 86400) {
        return _('%d h ago').format(Math.floor(diff / 3600));
    }
    return _('%d days ago').format(Math.floor(diff / 86400));
}

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
    relativeTime: relativeTime,

    status: async function () {
        return (await callRCList('meowx'))?.meowx?.running;
    },

    reload: function () {
        return callRCInit('meowx', 'reload');
    },

    // 服务上次启动 / 重载 / 切换没成功的原因：{ error, time }，没有失败时 error 为空
    lastError: function () {
        return L.resolveDefault(callMeowXLastError(), {});
    },

    // GitHub 加速：预设列表 + 上次测速结果（不测速）
    ghproxyStatus: function () {
        return L.resolveDefault(callMeowXGhproxy('status'), {});
    },

    // GitHub 加速：由路由器测一轮各加速地址（约 5 秒），返回同 ghproxyStatus
    ghproxyTest: function () {
        return callMeowXGhproxy('test');
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

    checkUpdate: function () {
        return L.resolveDefault(callMeowXCheckUpdate(), { success: false });
    },

    upgrade: function () {
        return callMeowXUpgrade();
    },

    upgradeStatus: function () {
        return callMeowXUpgradeStatus();
    },

    // 版本号比较（只比数字段，去掉 opkg 的 -rN 修订号）：a > b 返回正数
    compareVersion: function (a, b) {
        const parse = (v) => String(v || '').replace(/-r\d+$/, '').split(/[^0-9]+/).filter(Boolean).map(Number);
        const x = parse(a), y = parse(b);
        for (let i = 0; i < Math.max(x.length, y.length); i++) {
            const d = (x[i] || 0) - (y[i] || 0);
            if (d) {
                return d;
            }
        }
        return 0;
    },

    openDashboard: async function () {
        // 先在本页算好地址再开窗口，不能反过来：LuCI 把请求排进队列、借 requestAnimationFrame 统一发出，
        // 先开窗口的话本页退到后台、动画帧停了，请求就一直排在队列里（Edge 上必现，新窗口一直空白）。
        // 地址几十毫秒就算好，点击之后几秒内 window.open 仍算用户操作，不会被当成弹窗拦掉
        let note = null;
        let url;
        try {
            url = await this.dashboardURL(function () {
                note = ui.addNotification(null, E('p', _('Downloading the web dashboard for the first time, this may take a minute or two…')), 'info');
            });
        } finally {
            note?.remove();
        }
        if (!window.open(url, '_blank')) {
            // 首次下载面板等太久，点击那一下已经失效，浏览器拦了弹窗：给个链接自己点
            ui.addTimeLimitedNotification(null, E('p', {}, [E('a', { href: url, target: '_blank', rel: 'noopener' }, _('The web dashboard is ready. Click here to open it.'))]), 30000, 'info');
        }
    },

    // onDownload：面板还没下载过、要先让内核下载时调一次（打开面板的窗口里换成「正在下载」）
    dashboardURL: async function (onDownload) {
        const profile = await callMeowXProfile({
            'external-ui': null,
            'external-ui-name': null,
            'external-controller': null,
            'external-controller-tls': null,
            'secret': null
        });
        // 面板子目录以插件自己的设置（混入配置 → 外部控制配置）为准，不读运行配置：服务重启生成配置的那几秒里，运行配置还是
        // 订阅原样（常带 external-ui-name: metacubexd），这时点「打开面板」会去 /ui/metacubexd/ → 404。
        // 插件生成配置时同样以这项为准（没填就删掉订阅自带的），两边一致
        // 控制端口、密钥、面板目录同理：插件设置里填了就以它为准（生成配置时也是写它），没填才看运行配置
        await uci.load('meowx');
        const mixin = (option, key) => uci.get('meowx', 'mixin', option) || profile[key] || null;
        const uiName = uci.get('meowx', 'mixin', 'ui_name') || '';
        const uiPath = mixin('ui_path', 'external-ui');
        const apiListen = mixin('api_listen', 'external-controller');
        const apiTLSListen = mixin('api_tls_listen', 'external-controller-tls');
        const apiSecret = mixin('api_secret', 'secret') ?? '';
        // 面板还没下载过（新装的插件、刚换了面板目录）：先让内核下载一次，否则打开就是 404
        if (uiPath && (apiListen || apiTLSListen)) {
            const st = await L.resolveDefault(callMeowXDashboardStatus(uiPath, uiName), { installed: true });
            if (!st.installed) {
                onDownload?.();
                const res = await this.updateDashboard();
                if (res?.status != 'ok') {
                    return Promise.reject(new Error(res?.message || 'download-failed'));
                }
            }
        }
        if (!apiListen && !apiTLSListen) {
            return Promise.reject(new Error('no-controller'));
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
            secret: apiSecret,
            // 每次地址都不同：面板目录的首页 / 目录列表带 Last-Modified，地址不变时 Chrome 会按启发式缓存直接拿旧页面
            // （面板换过目录、刚重新下载过时打开的还是以前那份）
            t: Date.now()
        };
        const query = new URLSearchParams(params).toString();
        let url;
        if (uiName) {
            url = `${protocol}://${window.location.hostname}:${port}/ui/${uiName}/?${query}`;
        } else {
            url = `${protocol}://${window.location.hostname}:${port}/ui/?${query}`;
        }

        return url;
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

    // 刷新订阅并按结果提示：下载 / 校验没过（旧的保留）、下载成功但套用失败（运行中的保持不动）、更新并已套用，分开说
    refreshSubscription: function (section_id) {
        return callMeowXRefreshSubscription(section_id).then((res) => {
            if (res?.busy) {
                ui.addTimeLimitedNotification(null, E('p', _('This subscription is being updated, please try again later.')), 5000, 'warning');
            } else if (!res?.success) {
                ui.addNotification(null, E('p', _('Subscription update failed: %s. The last downloaded copy is kept.').format(this.subscriptionError(res))), 'warning');
            } else if (res.applied === false) {
                ui.addNotification(null, E('p', _('Subscription updated, but applying it failed: %s. The proxy keeps running with the previous config.').format(stripPeriod(res.apply_error) || _('see the log'))), 'warning');
            } else {
                ui.addTimeLimitedNotification(null, E('p', res.applied ? _('Subscription updated and applied.') : _('Subscription updated.')), 4000, 'info');
            }
            return res;
        });
    },

    // 切换配置；没成功时提示原因（服务在跑时新配置不能用会退回原来的选择，运行中的保持不动）
    switchProfile: function (profile) {
        return callMeowXSwitchProfile(profile).then((res) => {
            if (!res?.success && res?.error) {
                ui.addNotification(null, E('p', (res.kept ? _('Switching failed: %s. Still using the previous config.') : _('Failed to start: %s')).format(stripPeriod(res.error))), 'warning');
            }
            return res;
        });
    },

    // 订阅更新失败的原因（UCI / RPC 回包里的 error_type 与 error）：短标签 + 具体原因
    subscriptionErrorLabel: function (res) {
        return { download: _('Download failed'), invalid: _('Invalid content'), test: _('Core test failed') }[res?.error_type] || _('Update failed');
    },

    subscriptionError: function (res) {
        const label = this.subscriptionErrorLabel(res);
        return res?.error ? _('%s (%s)').format(label, res.error) : label;
    },

    addSubscription: function (url, name) {
        return callMeowXAddSubscription(url, name || '');
    },

    formatBytes: formatBytes,

    stripPeriod: stripPeriod,

    panelStatus: function () {
        return L.resolveDefault(callMeowXPanelStatus(), { logged_in: false });
    },

    panelLogin: function (link) {
        return callMeowXPanelLogin(link);
    },

    panelLogout: function () {
        return callMeowXPanelLogout();
    },

    panelProfile: function () {
        return callMeowXPanelProfile();
    },

    po0: function (action, address, token, index) {
        return callMeowXPo0(action, address ?? '', token ?? '', index ?? 0);
    },

    po0Status: function () {
        return L.resolveDefault(callMeowXPo0('status', '', '', 0), { success: false, enabled: false, custom: [], panel: [] });
    },

    panelSubscriptions: function () {
        return L.resolveDefault(callMeowXPanelSubscriptions(), { success: false, subscriptions: [] });
    },

    // 账户下还没下载到本机的订阅（同客户端 SubAccountStore.notDownloaded）：短链路径（/x/<code>）相同就算已下载、
    // 不比主机名（开了订阅域名本机那份可能挂在别的域名上）；只有 filename 的旧式地址按同主机 + filename 认
    notDownloaded: function (remote, localUrls) {
        const parse = function (u) {
            const m = String(u || '').match(/^[a-z][a-z0-9+.-]*:\/\/([^\/:?#]+)(?::\d+)?([^?#]*)(?:\?([^#]*))?/i);
            if (!m) {
                return null;
            }
            const query = new URLSearchParams(m[3] || '');
            // 接口式地址的身份 = 主机 + 路径 + 除 token / t 以外的参数：主控关了短链接时几份套餐共用
            // /api/user/package-subscribe 这一个路径，只靠 assignment_id / merged 区分
            const ident = [...query.entries()].filter((e) => e[0] != 'token' && e[0] != 't').map((e) => e[0] + '=' + e[1]).sort().join('&');
            const path = (m[2] || '/').replace(/\/+$/, '') || '/';
            return { host: m[1].toLowerCase(), path: path, filename: query.get('filename') || '', api: m[1].toLowerCase() + path + '?' + ident };
        };
        const locals = localUrls.map(parse).filter(Boolean);
        return remote.filter(function (sub) {
            const r = parse(sub.url);
            if (!r) {
                return false;
            }
            if (sub.path && r.path.startsWith('/x/')) {
                return !locals.some((l) => l.path == r.path);
            }
            if (sub.path) {
                return !locals.some((l) => l.api == r.api);
            }
            return !locals.some((l) => l.host == r.host && l.filename && l.filename == r.filename);
        });
    },

    // 首页账户卡（同客户端「我的」顶部账户卡）：没登录时粘贴主控「扫码登录」里复制的登录链接登录
    // （路由器没有扫码环境）；登录后显示昵称 / 头像 / 主控，「刷新」才向主控重取账户信息（不定时拉，同客户端）
    renderAccountCard: function (status, onChanged) {
        const card = E('div', { class: 'mx-account' });
        if (!status?.logged_in) {
            const input = E('input', { type: 'text', class: 'mx-quickadd__input', placeholder: _('Paste login link') });
            const error = E('div', { class: 'mx-account__error', hidden: '' });
            const login = E('button', {
                type: 'button',
                class: 'cbi-button cbi-button-action',
                click: (ev) => this.busy(ev.currentTarget, () => {
                    const link = input.value.trim();
                    if (!/^miaomiaowu:\/\/login\?/.test(link)) {
                        input.classList.add('is-invalid');
                        input.focus();
                        error.textContent = _('This is not a MeowX login link');
                        error.hidden = false;
                        return;
                    }
                    input.classList.remove('is-invalid');
                    error.hidden = true;
                    return this.panelLogin(link).then((res) => {
                        if (!res?.success) {
                            error.textContent = res?.error || _('Login failed');
                            error.hidden = false;
                            return;
                        }
                        if (res.imported) {
                            ui.addNotification(null, E('p', _('Logged in, and imported subscription %s').format(res.imported)), 'info');
                        }
                        return onChanged();
                    });
                })
            }, _('Log In'));
            input.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') login.click(); });
            card.appendChild(E('div', { class: 'mx-account__head' }, [
                E('span', { class: 'mx-subcard__label' }, _('Panel Account')),
            ]));
            card.appendChild(E('div', { class: 'mx-account__hint' }, _('On the panel website, open "Scan to log in" and click "Copy login link", then paste it here. The link works once, within 5 minutes.')));
            card.appendChild(E('div', { class: 'mx-quickadd' }, [input, login]));
            card.appendChild(error);
            return card;
        }
        const host = String(status.base || '').replace(/^https?:\/\//, '');
        const avatar = E('span', { class: 'mx-account__avatar' }, (status.username || '?').slice(0, 1).toUpperCase());
        if (status.avatar) {
            const img = E('img', { alt: '', src: status.avatar, referrerpolicy: 'no-referrer' });
            img.addEventListener('load', () => { avatar.replaceChildren(img); });
        }
        card.appendChild(E('div', { class: 'mx-account__row' }, [
            avatar,
            E('div', { class: 'mx-account__main' }, [
                E('div', { class: 'mx-account__name' }, status.username || _('Panel Account')),
                E('div', { class: 'mx-account__host' }, host)
            ]),
            E('div', { class: 'mx-account__actions' }, [
                E('button', {
                    type: 'button',
                    class: 'cbi-button',
                    click: (ev) => this.busy(ev.currentTarget, () => this.panelProfile().then(onChanged))
                }, _('Refresh')),
                E('button', {
                    type: 'button',
                    class: 'cbi-button cbi-button-negative',
                    click: (ev) => {
                        if (!confirm(_('Log out? Subscriptions imported from this panel will be removed from the router.'))) {
                            return;
                        }
                        return this.busy(ev.currentTarget, () => this.panelLogout().then(onChanged));
                    }
                }, _('Log Out'))
            ])
        ]));
        return card;
    },


    // po0 加白卡（同客户端「流量控制 → po0 加白」+「自定义 po0 服务器」）：开关、主控登记的列表、自己添加的列表。
    // 每次操作后用回包原地重画这张卡；token 只显示脱敏写法，完整值只在路由器上
    renderPo0Card: function (po0, loggedIn) {
        const card = E('div', { class: 'mx-account mx-po0' });
        const draw = (state) => {
            const error = E('div', { class: 'mx-account__error', hidden: '' });
            const fail = (res) => {
                error.textContent = res?.error || _('Operation failed');
                error.hidden = false;
            };
            const act = (button, action, address, token, index) => this.busy(button, () =>
                this.po0(action, address, token, index).then((res) => {
                    if (!res?.success) {
                        return fail(res);
                    }
                    draw(res);
                }));

            const toggle = E('input', { type: 'checkbox', 'aria-label': _('po0 Whitelist') });
            toggle.checked = !!state.enabled;
            toggle.addEventListener('change', () => {
                toggle.disabled = true;
                this.po0(toggle.checked ? 'enable' : 'disable').then((res) => {
                    if (!res?.success) {
                        toggle.checked = !toggle.checked;
                        toggle.disabled = false;
                        return fail(res);
                    }
                    draw(res);
                }, (err) => {
                    toggle.checked = !toggle.checked;
                    toggle.disabled = false;
                    fail({ error: String(err?.message ?? err) });
                });
            });

            const children = [
                E('div', { class: 'mx-po0__head' }, [
                    E('div', { class: 'mx-po0__title' }, [
                        E('span', { class: 'mx-subcard__label' }, _('po0 Whitelist')),
                        E('div', { class: 'mx-account__hint' }, _('Report the router\'s public IP to po0 whitelist servers (registered on the panel and added by you), every 10 minutes and whenever WAN reconnects. Traffic to these po0 servers goes direct.'))
                    ]),
                    toggle
                ])
            ];

            if (state.enabled) {
                const panel = state.panel ?? [];
                children.push(E('div', { class: 'mx-po0__group' }, _('Registered on the panel (%d)').format(panel.length)));
                if (!loggedIn) {
                    children.push(E('div', { class: 'mx-po0__empty' }, _('Log in to the panel account to fetch them automatically.')));
                } else if (panel.length == 0) {
                    children.push(E('div', { class: 'mx-po0__empty' }, _('No po0 servers for this account.')));
                } else {
                    children.push(E('div', { class: 'mx-po0__list' }, panel.map((server) => E('div', { class: 'mx-po0__row' }, [
                        E('div', { class: 'mx-po0__main' }, [
                            E('div', { class: 'mx-po0__addr' }, server.name || server.host),
                            server.name ? E('div', { class: 'mx-po0__token' }, server.host) : ''
                        ])
                    ]))));
                }
            }

            const custom = state.custom ?? [];
            children.push(E('div', { class: 'mx-po0__group' }, _('Custom po0 servers (%d)').format(custom.length)));
            if (custom.length > 0) {
                children.push(E('div', { class: 'mx-po0__list' }, custom.map((server, i) => E('div', { class: 'mx-po0__row' }, [
                    E('div', { class: 'mx-po0__main' }, [
                        E('div', { class: 'mx-po0__addr' }, server.address),
                        E('div', { class: 'mx-po0__token' }, server.token)
                    ]),
                    E('button', {
                        type: 'button',
                        class: 'cbi-button cbi-button-negative',
                        click: (ev) => act(ev.currentTarget, 'remove', '', '', i)
                    }, _('Delete'))
                ]))));
            }
            if (!state.enabled && custom.length > 0) {
                children.push(E('div', { class: 'mx-po0__empty' }, _('"po0 Whitelist" is off, so these servers are not reported for now.')));
            }

            const address = E('input', { type: 'text', class: 'mx-quickadd__input', placeholder: _('Whitelist server address: IP or domain, port optional'), autocomplete: 'off', spellcheck: 'false' });
            const token = E('input', { type: 'password', class: 'mx-quickadd__input', placeholder: _('Token, starts with pgnfw_ (@slot optional)'), autocomplete: 'new-password' });
            const add = E('button', {
                type: 'button',
                class: 'cbi-button cbi-button-action',
                click: (ev) => {
                    const a = address.value.trim(), t = token.value.trim();
                    address.classList.toggle('is-invalid', !a);
                    token.classList.toggle('is-invalid', !/^pgnfw_[A-Za-z0-9_-]{4,200}(@[0-9]{1,2})?$/.test(t));
                    if (!a || token.classList.contains('is-invalid')) {
                        error.textContent = !a ? _('Enter the po0 whitelist server address') : _('The token should be the whole string starting with pgnfw_, @slot optional');
                        error.hidden = false;
                        return;
                    }
                    return act(ev.currentTarget, 'add', a, t);
                }
            }, _('Add'));
            token.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') add.click(); });
            children.push(E('div', { class: 'mx-quickadd mx-po0__add' }, [address, token, add]));
            children.push(error);
            children.push(E('div', { class: 'mx-po0__note' }, _('Fill in the po0 whitelist server address (IP or domain, port optional, e.g. 1.2.3.4 or fw.example.com:8443); it is not necessarily the node address. Copy the token from the po0 dashboard.')));
            card.replaceChildren(...children);
        };
        draw(po0 ?? {});
        return card;
    },

    // 订阅显示名：没名字时用链接的主机名（同客户端 SubProfile 的缺省名）
    subscriptionName: function (section) {
        if (section.name) {
            return section.name;
        }
        const m = String(section.url || '').match(/^[a-z][a-z0-9+.-]*:\/\/([^\/:?#]+)/i);
        return m ? m[1] : _('Subscription');
    },

    // 用量条 + 剩余 / 到期 / 更新时间（同客户端首页订阅条）。section 是 uci 里的订阅节
    renderUsage: function (section, onRefresh) {
        const used = +section.used_bytes, total = +section.total_bytes;
        const hasTotal = isFinite(total) && total > 0;
        const ratio = hasTotal ? Math.min(1, Math.max(0, used / total)) : 0;
        const parts = [];
        if (hasTotal) {
            parts.push(_('Remaining %s').format(formatBytes(Math.max(0, total - used))));
        } else if (section.success == '1') {
            parts.push(_('Unlimited'));
        }
        if (+section.expire_ts > 0) {
            const days = Math.floor((+section.expire_ts - Date.now() / 1000) / 86400);
            parts.push(days < 0 ? _('Expired') : _('Expires in %d days').format(days));
        }
        // 上次更新失败：按钮上是短原因（下载失败 / 内容无效 / 内核测试没过），悬停看具体原因；用的仍是上次下载成功的那份
        const failed = section.success == '0';
        const updated = E('button', {
            type: 'button',
            class: 'mx-sub__updated' + (failed ? ' is-failed' : ''),
            title: failed ? this.subscriptionError(section) : _('Update'),
            click: onRefresh ? (ev) => this.busy(ev.currentTarget, onRefresh) : null
        }, failed ? this.subscriptionErrorLabel(section) : (+section.update_ts > 0 ? _('Updated %s').format(relativeTime(section.update_ts)) : _('Never updated')));
        return E('div', { class: 'mx-sub__usage' }, [
            E('div', { class: 'mx-sub__bar' + (hasTotal ? '' : ' is-empty') }, E('span', { style: `transform: scaleX(${ratio})` })),
            E('div', { class: 'mx-sub__line' }, [
                E('span', { class: 'mx-sub__amount' }, hasTotal ? `${formatBytes(used)} / ${formatBytes(total)}` : (used > 0 ? formatBytes(used) : '')),
                E('span', { class: 'mx-sub__meta' }, parts.join(' · ')),
                updated
            ])
        ]);
    },

    // 「粘贴订阅链接 → 添加」：名字下载后自动取（同客户端导入订阅）。onAdded(section_id) 在成功后调
    renderQuickAdd: function (onAdded) {
        const input = E('input', { type: 'url', class: 'mx-quickadd__input', placeholder: _('Paste subscription link') });
        const add = E('button', {
            type: 'button',
            class: 'cbi-button cbi-button-action',
            click: (ev) => this.busy(ev.currentTarget, () => {
                const url = input.value.trim();
                if (!/^https?:\/\/\S+$/.test(url)) {
                    input.focus();
                    input.classList.add('is-invalid');
                    return;
                }
                input.classList.remove('is-invalid');
                return this.addSubscription(url).then((res) => {
                    if (!res?.success) {
                        ui.addNotification(null, E('p', _('Subscription added, but the update failed: %s. Check the link and update it again.').format(this.subscriptionError(res))), 'warning');
                    }
                    input.value = '';
                    return onAdded ? onAdded(res?.section_id) : null;
                });
            })
        }, _('Add Subscription'));
        input.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') add.click(); });
        return E('div', { class: 'mx-quickadd' }, [input, add]);
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
        // 主题标了 data-darkmode（bootstrap）就由 CSS 跟着它走；没标的才按底色亮度判断
        if (!document.body.classList.contains('mx-page') && !document.documentElement.hasAttribute('data-darkmode')) {
            const rgb = (getComputedStyle(document.body).backgroundColor.match(/\d+(\.\d+)?/g) || ['255', '255', '255']).map(Number);
            const transparent = rgb.length > 3 && rgb[3] === 0;
            const luma = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
            document.body.classList.toggle('mx-dark', !transparent && luma < 0.45);
        }
        document.body.classList.add('mx-page');
        return Promise.all([rendered, this.themeReady]).then(function (results) {
            const node = results[0];
            const map = node.id === 'cbi-meowx' ? node : node.querySelector('#cbi-meowx');
            if (!map) {
                return node;
            }
            map.classList.add('mx');
            // 画布挂在 #view 上：这时 #view 里还是「加载中」，LuCI 紧接着在同一轮里换成内容，样式随内容一起出现
            document.getElementById('view')?.classList.add('mx-view');
            // 主卡 / 订阅卡收进一个容器（display: contents，不影响布局）。LuCI 点「保存」等按钮后会重画整张表单、
            // 把地图下的子节点全换掉，容器跟着没了——盯住它，没了就原样放回（不重播进场动画），否则主卡消失、页面跳一下
            let head = null;
            if (options.hero) {
                map.classList.add('mx-has-hero');
                head = E('div', { class: 'mx-head' }, [].concat(options.hero));
                const place = function () {
                    const descr = map.querySelector(':scope > .cbi-map-descr');
                    map.insertBefore(head, descr ? descr.nextSibling : map.firstChild);
                };
                place();
                new MutationObserver(function () {
                    if (!head.isConnected || head.parentNode !== map) {
                        place();
                    }
                }).observe(map, { childList: true });
            }
            // 只给前 12 张卡错峰，后面的随第 12 张一起出来（同客户端节点卡的 StaggerIn）；页面在后台时不播，直接显示。
            // 只在第一次渲染时播：表单重画出来的新卡直接显示
            if (!document.hidden) {
                const cards = map.querySelectorAll(':scope > .mx-head > .mx-hero, :scope > .mx-head > .mx-cards > *, :scope > .cbi-section, :scope > .cbi-section-create');
                cards.forEach(function (card, i) {
                    card.style.setProperty('--mx-i', Math.min(i, 12));
                    card.classList.add('mx-enter');
                });
            }
            return node;
        });
    },

    // 原地刷新整张表单：重新读 uci、按新值重画（主卡 / 订阅卡由 decorate 的容器保住）。用来代替整页刷新——
    // 整页刷新会白屏一下、卡片进场动画重播
    reloadMap: function (map) {
        uci.unload('meowx');
        return map.load().then(function () {
            return map.reset();
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
