'use strict';
'require baseclass';
'require ui';
'require tools.meowx as meowx';

// 「网络测速」页：测法与安卓 / Windows / Linux / iOS 客户端相同，在内核里跑（meowx-core 的 component/speedtest），
// 经内核控制接口 /meowx/speedtest 开始 / 停止 / 取进度（luci.meowx 的 api 由路由器带上密钥转发，同「打开面板」用的那一套）。
// 只能选节点或直连（DIRECT），不能选代理组：测速直连测速服务器、不过规则（规则模式下测速地址常被分到直连，测的就成了宽带）。
// 测的时候每半秒问一次进度（每次都要在路由器上起一次 curl，比客户端的 300ms 放宽一点，低端路由器上少占点 CPU）；
// 切到别的页签、关掉或跳走页面时停掉正在跑的测速。测速记录只存在这个浏览器里（localStorage，最近 20 条）。

const POLL_MS = 500;
const HISTORY_KEY = 'meowx.speedtest.history';
const HISTORY_MAX = 20;
const RUNNING = ['preparing', 'latency', 'download', 'upload'];
const SAMPLE_SECONDS = 0.25;   // 内核每 250ms 记一个速率样本
const WARMUP_SAMPLES = 8;      // 内核算平均值时去掉的前 2 秒
const GAUGE_MAX = 1000;        // 码表刻度到 1000 Mbps（对数刻度），更快的数字照常显示、指针停在头

const SOURCES = [
    { id: 'google', title: 'Google', downloadOnly: true },
    { id: 'microsoft', title: 'Microsoft', downloadOnly: true },
    { id: 'apple', title: 'Apple' },
    { id: 'speedtest', title: 'Speedtest' },
    { id: 'cloudflare', title: 'Cloudflare' }
];

// 内核内置的出站，不当节点列出（直连单独放在最上面）
const BUILTIN_TYPES = ['Direct', 'Reject', 'RejectDrop', 'Compatible', 'Pass', 'PassRule', 'Dns'];

function svg(tag, attrs, children) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [k, v] of Object.entries(attrs ?? {})) {
        node.setAttribute(k, v);
    }
    for (const child of [].concat(children ?? [])) {
        node.appendChild(typeof child == 'string' ? document.createTextNode(child) : child);
    }
    return node;
}

function fmtMbps(v) {
    if (v == null || !isFinite(v)) {
        return '--';
    }
    return v >= 100 ? v.toFixed(0) : (v >= 10 ? v.toFixed(1) : v.toFixed(2));
}

function phaseLabel(phase) {
    switch (phase) {
    case 'preparing': return _('Preparing');
    case 'latency': return _('Testing latency');
    case 'download': return _('Download');
    case 'upload': return _('Upload');
    case 'done': return _('Done');
    case 'failed': return _('Failed');
    case 'cancelled': return _('Cancelled');
    default: return _('Ready');
    }
}

function sourceTitle(id) {
    return SOURCES.find((s) => s.id == id)?.title ?? id ?? '';
}

function viaTitle(via) {
    return (via == null || via == 'DIRECT') ? _('Direct') : via;
}

function exitText(exit) {
    if (!exit) {
        return '';
    }
    return [exit.asn ? `AS${exit.asn}` + (exit.org ? ` ${exit.org}` : '') : exit.org, exit.country, exit.ip].filter((x) => x).join(' · ');
}

// /proxies → 节点列表（订阅顺序：GLOBAL 的 all 先列配置里的节点再列组，组里还有 proxy-provider 的节点）+ 缺省节点
// （主代理组 = 第一个 select 组，沿它的当前选择一路走到叶子节点；走不到节点就用直连）
function parseProxies(res) {
    const proxies = res?.proxies;
    if (!proxies || typeof proxies != 'object') {
        return { nodes: [], preferred: 'DIRECT' };
    }
    const isGroup = (p) => Array.isArray(p?.all);
    const isNode = (name) => proxies[name] && !isGroup(proxies[name]) && !BUILTIN_TYPES.includes(proxies[name].type);
    const order = proxies.GLOBAL?.all ?? Object.keys(proxies);
    const nodes = [];
    const seen = new Set();
    const add = (name) => {
        if (!seen.has(name) && isNode(name)) {
            seen.add(name);
            nodes.push(name);
        }
    };
    order.forEach(add);
    for (const name of order) {
        if (isGroup(proxies[name])) {
            proxies[name].all.forEach(add);
        }
    }
    Object.keys(proxies).forEach(add);

    const groups = order.filter((name) => name != 'GLOBAL' && isGroup(proxies[name]));
    let current = groups.find((name) => proxies[name].type == 'Selector') ?? groups[0];
    for (let i = 0; current && isGroup(proxies[current]) && i < 16; i++) {
        current = proxies[current].now;
    }
    return { nodes: nodes, preferred: current && isNode(current) ? current : 'DIRECT' };
}

function loadHistory() {
    try {
        const list = JSON.parse(localStorage.getItem(HISTORY_KEY) ?? '[]');
        return Array.isArray(list) ? list : [];
    } catch (e) {
        return [];
    }
}

function saveHistory(list) {
    try {
        localStorage.setItem(HISTORY_KEY, JSON.stringify(list.slice(0, HISTORY_MAX)));
    } catch (e) { }
}

// 码表：270° 弧，对数刻度（0–1000 Mbps）
const GAUGE = { cx: 120, cy: 112, r: 84, start: 135, sweep: 270 };

function gaugeFraction(v) {
    return Math.max(0, Math.min(1, Math.log10(1 + Math.max(0, v)) / Math.log10(1 + GAUGE_MAX)));
}

function gaugePoint(fraction, r) {
    const a = (GAUGE.start + GAUGE.sweep * fraction) * Math.PI / 180;
    return [GAUGE.cx + r * Math.cos(a), GAUGE.cy + r * Math.sin(a)];
}

function gaugeArcPath() {
    const [x0, y0] = gaugePoint(0, GAUGE.r);
    const [x1, y1] = gaugePoint(1, GAUGE.r);
    return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${GAUGE.r} ${GAUGE.r} 0 1 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`;
}

function buildGauge() {
    const length = GAUGE.r * GAUGE.sweep * Math.PI / 180;
    const value = svg('path', { d: gaugeArcPath(), class: 'mx-st__gauge-value', 'stroke-dasharray': `0 ${length + 1}` });
    const ticks = [0, 10, 50, 100, 500, 1000].map((v) => {
        const [x, y] = gaugePoint(gaugeFraction(v), GAUGE.r + 18);   // 刻度写在弧外，不和中间的大数字挤在一起
        return svg('text', { x: x.toFixed(1), y: (y + 4).toFixed(1), class: 'mx-st__gauge-tick', 'text-anchor': 'middle' }, String(v));
    });
    const node = svg('svg', { viewBox: '0 0 240 210', class: 'mx-st__gauge-svg', 'aria-hidden': 'true' }, [
        svg('path', { d: gaugeArcPath(), class: 'mx-st__gauge-track' }),
        value,
        ...ticks
    ]);
    return {
        node: node,
        set: (mbps, kind) => {
            const fraction = gaugeFraction(mbps ?? 0);
            value.setAttribute('stroke-dasharray', `${(length * fraction).toFixed(2)} ${length + 1}`);
            value.style.opacity = fraction > 0 ? '1' : '0';   // 长度为 0 时圆头线帽仍会画出一个点
            value.classList.toggle('is-upload', kind == 'upload');
        }
    };
}

// 逐秒速率曲线：下载紫、上传玫红，两条叠在同一个 0–10 秒的横轴上
function drawChart(host, progress) {
    const W = 600, H = 170, padL = 34, padR = 8, padT = 10, padB = 22;
    const down = progress?.downloadSamples ?? [];
    const up = progress?.uploadSamples ?? [];
    const seconds = Math.max(10, Math.max(down.length, up.length) * SAMPLE_SECONDS);
    // 纵轴按去掉前 2 秒（慢启动、上传开头先灌满发送缓冲的虚高）之后的样本定，免得开头一个尖峰把整条曲线压扁；尖峰顶到头
    const warm = (samples) => samples.length > WARMUP_SAMPLES ? samples.slice(WARMUP_SAMPLES) : samples;
    const peak = Math.max(1, ...warm(down), ...warm(up));
    // 纵轴取 1 / 2 / 5 × 10^n 的整数刻度
    const mag = Math.pow(10, Math.floor(Math.log10(peak)));
    const top = [1, 2, 5, 10].map((m) => m * mag).find((v) => v >= peak);
    const x = (i) => padL + (W - padL - padR) * Math.min(1, ((i + 1) * SAMPLE_SECONDS) / seconds);
    const y = (v) => padT + (H - padT - padB) * (1 - Math.min(1, v / top));
    const series = (samples, cls) => {
        if (samples.length == 0) {
            return [];
        }
        const pts = samples.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`);
        const line = `${padL},${y(samples[0]).toFixed(1)} ${pts.join(' ')}`;
        const area = `${padL},${H - padB} ${line} ${x(samples.length - 1).toFixed(1)},${H - padB}`;
        return [
            svg('polygon', { points: area, class: 'mx-st__area ' + cls }),
            svg('polyline', { points: line, class: 'mx-st__line ' + cls })
        ];
    };
    const grid = [0, 0.5, 1].map((f) => svg('line', { x1: padL, x2: W - padR, y1: y(top * f), y2: y(top * f), class: 'mx-st__gridline' }));
    const labels = [0, 0.5, 1].map((f) => svg('text', { x: padL - 6, y: y(top * f) + 4, class: 'mx-st__axis', 'text-anchor': 'end' }, String(top * f >= 10 ? Math.round(top * f) : +(top * f).toFixed(1))));
    const xLabels = [
        svg('text', { x: padL, y: H - 6, class: 'mx-st__axis' }, '0s'),
        svg('text', { x: W - padR, y: H - 6, class: 'mx-st__axis', 'text-anchor': 'end' }, `${Math.round(seconds)}s`)
    ];
    host.replaceChildren(svg('svg', { viewBox: `0 0 ${W} ${H}`, class: 'mx-st__chart-svg', preserveAspectRatio: 'none', role: 'img', 'aria-label': _('Speed over time') }, [
        ...grid, ...labels, ...xLabels, ...series(down, 'is-download'), ...series(up, 'is-upload')
    ]));
}

function segment(options, value, onChange) {
    const node = E('div', { class: 'mx-seg', role: 'radiogroup' });
    const buttons = options.map((opt) => E('button', {
        type: 'button',
        class: 'mx-seg__item',
        role: 'radio',
        'data-value': String(opt.value),
        click: () => {
            if (!node.classList.contains('is-disabled')) {
                set(opt.value);
                onChange(opt.value);
            }
        }
    }, opt.title));
    const set = (v) => {
        value = v;
        buttons.forEach((b) => {
            const on = b.getAttribute('data-value') == String(v);
            b.classList.toggle('is-active', on);
            b.setAttribute('aria-checked', on ? 'true' : 'false');
        });
    };
    buttons.forEach((b) => node.appendChild(b));
    set(value);
    return {
        node: node,
        setDisabled: (disabled) => {
            node.classList.toggle('is-disabled', disabled);
            buttons.forEach((b) => { b.disabled = disabled; });
        }
    };
}

return baseclass.extend({
    load: function () {
        return Promise.all([
            L.resolveDefault(meowx.api('GET', '/meowx/speedtest'), {}),
            L.resolveDefault(meowx.api('GET', '/proxies'), {})
        ]);
    },

    render: function ([status, proxies]) {
        this.settings = { source: 'google', connections: 1 };
        this.proxyInfo = parseProxies(proxies);
        this.progress = null;
        this.ownRun = null;        // 本页开始的那一次：开始前的 runID，下一次进度里 runID 变大的就是它
        this.recorded = new Set(); // 已记进测速记录的 runID

        // ---- 左栏：节点 + 码表 + 开始 ----
        this.nodeSelect = E('select', { class: 'mx-st__select', 'aria-label': _('Test via') });
        this.fillNodes(this.proxyInfo.preferred);
        this.gauge = buildGauge();
        this.gaugeValue = E('div', { class: 'mx-st__gauge-num' }, '--');
        this.gaugeUnit = E('div', { class: 'mx-st__gauge-unit' }, 'Mbps');
        this.gaugePhase = E('div', { class: 'mx-st__gauge-phase' }, phaseLabel('idle'));
        this.phaseBar = E('div', { class: 'mx-st__bar-fill' });
        this.startButton = E('button', {
            type: 'button',
            class: 'cbi-button cbi-button-action mx-st__start',
            click: () => this.isRunning() ? this.stop() : this.confirmStart()
        }, _('Start test'));
        this.notice = E('div', { class: 'mx-account__error', hidden: '' });

        const left = E('div', { class: 'mx-account mx-st__card mx-st__main' }, [
            E('div', { class: 'mx-st__label' }, _('Test via')),
            this.nodeSelect,
            E('div', { class: 'mx-st__gauge' }, [
                this.gauge.node,
                E('div', { class: 'mx-st__gauge-center' }, [this.gaugeValue, this.gaugeUnit, this.gaugePhase])
            ]),
            E('div', { class: 'mx-st__bar' }, this.phaseBar),
            this.startButton,
            this.notice
        ]);

        // ---- 右栏：读数 + 曲线 + 设置 ----
        const cell = (label, cls) => {
            const value = E('span', { class: 'mx-st__cell-num' }, '--');
            const sub = E('div', { class: 'mx-st__cell-sub' }, '');
            const node = E('div', { class: 'mx-st__cell ' + cls }, [
                E('div', { class: 'mx-st__cell-label' }, label),
                E('div', { class: 'mx-st__cell-value' }, [value, E('span', { class: 'mx-st__cell-unit' }, cls == 'is-latency' ? 'ms' : 'Mbps')]),
                sub
            ]);
            return { node, value, sub };
        };
        this.cells = {
            latency: cell(_('Latency'), 'is-latency'),
            download: cell(_('Download'), 'is-download'),
            upload: cell(_('Upload'), 'is-upload')
        };
        this.chart = E('div', { class: 'mx-st__chart' });
        this.meta = E('div', { class: 'mx-st__meta' });
        this.exit = E('div', { class: 'mx-st__meta' });

        this.sourceSeg = segment(SOURCES.map((s) => ({ value: s.id, title: s.title })), this.settings.source, (v) => {
            this.settings.source = v;
            this.updateCells();
        });
        this.connSeg = segment([{ value: 1, title: _('Single thread') }, { value: 8, title: _('Multi-thread (8)') }], this.settings.connections, (v) => {
            this.settings.connections = v;
        });

        const right = E('div', { class: 'mx-st__side' }, [
            E('div', { class: 'mx-account mx-st__card' }, [
                E('div', { class: 'mx-st__cells' }, [this.cells.latency.node, this.cells.download.node, this.cells.upload.node]),
                this.chart,
                E('div', { class: 'mx-st__legend' }, [
                    E('span', { class: 'mx-st__key is-download' }, _('Download')),
                    E('span', { class: 'mx-st__key is-upload' }, _('Upload'))
                ]),
                this.meta,
                this.exit
            ]),
            E('div', { class: 'mx-account mx-st__card' }, [
                E('div', { class: 'mx-st__label' }, _('Test server')),
                this.sourceSeg.node,
                E('div', { class: 'mx-po0__note' }, _('Google and Microsoft test download only.')),
                E('div', { class: 'mx-st__label mx-st__label--gap' }, _('Connections')),
                this.connSeg.node
            ])
        ]);

        // ---- 说明 + 测速记录 ----
        this.historyList = E('div', { class: 'mx-po0__list' });
        const notes = E('div', { class: 'mx-account mx-st__card mx-st__wide' }, [
            E('div', { class: 'mx-subcard__label' }, _('About the speed test')),
            E('ul', { class: 'mx-st__notes' }, [
                E('li', {}, _('This measures the speed of the router going out through the selected node. On low-end routers encryption may be the bottleneck, in which case the result is the router\'s own limit rather than the node\'s.')),
                E('li', {}, _('A test saturates your bandwidth for a dozen seconds or so, slowing down other devices on the LAN, and uses real traffic on the node (a fast multi-thread test can use several hundred MB or more).')),
                E('li', {}, _('"Direct" tests the router\'s own network without any proxy.'))
            ])
        ]);
        const history = E('div', { class: 'mx-account mx-st__card mx-st__wide' }, [
            E('div', { class: 'mx-po0__head' }, [
                E('div', { class: 'mx-po0__title' }, [
                    E('span', { class: 'mx-subcard__label' }, _('Test history')),
                    E('div', { class: 'mx-account__hint' }, _('Only kept in this browser (last %d tests).').format(HISTORY_MAX))
                ]),
                E('button', {
                    type: 'button',
                    class: 'cbi-button cbi-button-negative',
                    click: () => {
                        saveHistory([]);
                        this.drawHistory();
                    }
                }, _('Clear history'))
            ]),
            this.historyList
        ]);

        this.root = E('div', { class: 'mx-st' }, [
            E('div', { class: 'mx-st__grid' }, [left, right]),
            notes,
            history
        ]);

        // 关掉页面 / 跳到 LuCI 的别的菜单：停掉正在跑的测速（rpc 排队发不出去，用带 keepalive 的 fetch）
        window.addEventListener('pagehide', () => {
            if (this.isRunning()) {
                meowx.apiBeacon('POST', '/meowx/speedtest/stop');
            }
        });

        this.drawHistory();
        this.apply(status);
        if (this.isRunning()) {
            this.poll();   // 打开页面时已经在测（别的标签页开始的）：接着显示进度
        }

        const map = E('div', { id: 'cbi-meowx', class: 'cbi-map' });
        return meowx.decorate(map, { hero: [E('div', { class: 'mx-cards' }, [this.root])] });
    },

    fillNodes: function (selected) {
        const options = [E('option', { value: 'DIRECT' }, _('Direct (DIRECT, tests the router\'s own network)'))];
        for (const name of this.proxyInfo.nodes) {
            options.push(E('option', { value: name }, name));
        }
        this.nodeSelect.replaceChildren(...options);
        this.nodeSelect.value = ['DIRECT', ...this.proxyInfo.nodes].includes(selected) ? selected : 'DIRECT';
    },

    isRunning: function () {
        return RUNNING.includes(this.progress?.phase);
    },

    // 内核的进度 → 页面。status 不是进度对象（没有 phase）时：旧内核（没有这个接口，回「404 page not found」）或内核没在跑
    apply: function (status) {
        if (typeof status?.phase != 'string') {
            const old = /404|not found/i.test(String(status?.message ?? ''));
            this.progress = null;
            this.supported = !old;
            this.showNotice(old ? _('The current core does not support the speed test. Please update MeowX.') : _('MeowX is not running. Start the service on the App Config page first.'));
            this.update();
            return false;
        }
        this.supported = true;
        this.progress = status;
        if (this.ownRun != null && status.runID > this.ownRun.before) {
            this.ownRun.id = status.runID;
        }
        if (['done', 'failed'].includes(status.phase) && this.ownRun?.id == status.runID && !this.recorded.has(status.runID)) {
            this.recorded.add(status.runID);
            this.record(status);
        }
        if (status.phase == 'failed') {
            this.showNotice(status.error || _('Speed test failed'));
        } else if (!this.noticeSticky) {
            this.showNotice('');
        }
        this.update();
        return true;
    },

    showNotice: function (text, sticky) {
        this.noticeSticky = !!(text && sticky);
        this.notice.textContent = text || '';
        this.notice.hidden = !text;
    },

    update: function () {
        const p = this.progress;
        const running = this.isRunning();
        const phase = p?.phase ?? 'idle';

        this.startButton.textContent = running ? _('Stop test') : _('Start test');
        this.startButton.classList.toggle('cbi-button-action', !running);
        this.startButton.classList.toggle('cbi-button-negative', running);
        this.startButton.disabled = !running && this.supported === false;
        this.nodeSelect.disabled = running;
        this.sourceSeg.setDisabled(running);
        this.connSeg.setDisabled(running);

        // 码表：下载 / 上传时显示当前速率，测完显示下载结果（只测下载的源）或上传结果之前的下载结果
        let value = null, kind = 'download';
        if (phase == 'download' || phase == 'upload') {
            value = p.currentMbps;
            kind = phase;
        } else if (phase == 'done') {
            value = p.downloadMbps;
        }
        this.gauge.set(value ?? 0, kind);
        this.gaugeValue.textContent = value == null ? (phase == 'latency' && p.latencyMs != null ? String(p.latencyMs) : '--') : fmtMbps(value);
        this.gaugeUnit.textContent = value == null && phase == 'latency' && p.latencyMs != null ? 'ms' : 'Mbps';
        this.gaugePhase.textContent = phase == 'done' ? _('Done · Download') : phaseLabel(phase);
        this.gaugePhase.className = 'mx-st__gauge-phase is-' + phase;
        this.phaseBar.style.width = running ? `${Math.round((p.phaseProgress ?? 0) * 100)}%` : (phase == 'done' ? '100%' : '0%');
        this.phaseBar.classList.toggle('is-upload', phase == 'upload');

        this.updateCells();
        drawChart(this.chart, p);

        const meta = [];
        if (p?.server) {
            meta.push(_('Server %s').format(p.server));
        }
        if (p?.via) {
            meta.push(_('Via %s').format(viaTitle(p.via)));
        }
        if (p?.bytesUsed > 0) {
            meta.push(_('Used %s').format(meowx.formatBytes(p.bytesUsed)));
        }
        this.meta.textContent = meta.join(' · ');
        this.meta.hidden = meta.length == 0;
        const exit = p?.exit ? exitText(p.exit) : '';
        this.exit.textContent = exit ? _('Exit %s').format(exit) : (p?.exitPending && running ? _('Exit: looking up…') : '');
        this.exit.hidden = !this.exit.textContent;
    },

    updateCells: function () {
        const p = this.progress;
        const set = (cell, value, sub) => {
            cell.value.textContent = value;
            cell.sub.textContent = sub ?? '';
        };
        set(this.cells.latency, p?.latencyMs != null ? String(p.latencyMs) : '--', p?.server ? sourceTitle(p.source) : '');
        set(this.cells.download, fmtMbps(p?.downloadMbps), p?.downloadPeakMbps != null ? _('Peak %s').format(fmtMbps(p.downloadPeakMbps)) : '');
        // 只测下载的源：上传格写明不测（测过的看那一次的源，没测过看当前设置）
        const source = (p && p.phase != 'idle') ? p.source : this.settings.source;
        if (SOURCES.find((s) => s.id == source)?.downloadOnly && p?.uploadMbps == null) {
            set(this.cells.upload, '--', _('Not tested by %s').format(sourceTitle(source)));
        } else {
            set(this.cells.upload, fmtMbps(p?.uploadMbps), p?.uploadPeakMbps != null ? _('Peak %s').format(fmtMbps(p.uploadPeakMbps)) : '');
        }
    },

    confirmStart: function () {
        const via = this.nodeSelect.value;
        ui.showModal(_('Start speed test?'), [
            E('p', {}, _('The test saturates your bandwidth for a dozen seconds or so, slowing down other devices on the LAN, and uses real traffic.')),
            E('p', {}, _('Via: %s · Server: %s · %s').format(viaTitle(via), sourceTitle(this.settings.source),
                this.settings.connections > 1 ? _('Multi-thread (8)') : _('Single thread'))),
            E('div', { class: 'right' }, [
                E('button', { type: 'button', class: 'cbi-button', click: ui.hideModal }, _('Cancel')),
                ' ',
                E('button', {
                    type: 'button',
                    class: 'cbi-button cbi-button-action',
                    click: () => {
                        ui.hideModal();
                        this.start(via);
                    }
                }, _('Start test'))
            ])
        ]);
    },

    start: function (via) {
        this.showNotice('');
        this.startButton.disabled = true;
        const before = this.progress?.runID ?? 0;
        return meowx.api('POST', '/meowx/speedtest/start', {
            source: this.settings.source,
            proxy: via,
            connections: this.settings.connections
        }).then((res) => {
            if (res?.message) {
                // 没能开始（找不到节点等）；旧内核没有这个接口
                const old = /404|not found/i.test(res.message) && !/节点|node/i.test(res.message);
                if (old) {
                    this.supported = false;
                }
                this.showNotice(old ? _('The current core does not support the speed test. Please update MeowX.') : res.message, true);
                this.update();
                return;
            }
            this.ownRun = { before: before, id: null };
            this.progress = Object.assign({}, this.progress ?? {}, { phase: 'preparing', runID: before, source: this.settings.source, via: via,
                downloadSamples: [], uploadSamples: [], latencyMs: null, downloadMbps: null, uploadMbps: null,
                downloadPeakMbps: null, uploadPeakMbps: null, currentMbps: 0, bytesUsed: 0, server: '', exit: null, phaseProgress: 0 });
            this.update();
            this.poll();
        }, (err) => {
            this.showNotice(String(err?.message ?? err), true);
            this.update();
        });
    },

    stop: function () {
        this.startButton.disabled = true;
        return meowx.api('POST', '/meowx/speedtest/stop').catch(() => { }).then(() => this.poll());
    },

    // 测的时候每半秒问一次；测完（或失败 / 取消）停下。同一时间只有一条轮询链
    poll: function () {
        this.pollSeq = (this.pollSeq ?? 0) + 1;
        const seq = this.pollSeq;
        let failures = 0;
        const tick = () => {
            if (seq != this.pollSeq) {
                return;
            }
            meowx.api('GET', '/meowx/speedtest').then((status) => {
                if (seq != this.pollSeq) {
                    return;
                }
                failures = 0;
                // 开始之后第一轮还拿到上一次的结果（runID 没变）：内核还没换过来，接着等
                const stale = this.ownRun && this.ownRun.id == null && typeof status?.phase == 'string' && status.runID <= this.ownRun.before;
                if (!stale && !this.apply(status)) {
                    return;
                }
                if (stale || this.isRunning()) {
                    this.timer = setTimeout(tick, POLL_MS);
                }
            }, () => {
                if (seq == this.pollSeq && ++failures < 10) {
                    this.timer = setTimeout(tick, POLL_MS * 2);
                }
            });
        };
        clearTimeout(this.timer);
        this.timer = setTimeout(tick, this.isRunning() ? POLL_MS : 0);
    },

    record: function (p) {
        const list = loadHistory();
        list.unshift({
            time: Date.now(),
            via: p.via,
            source: p.source,
            connections: this.settings.connections,
            latencyMs: p.latencyMs ?? null,
            downloadMbps: p.downloadMbps ?? null,
            uploadMbps: p.uploadMbps ?? null,
            error: p.phase == 'failed' ? (p.error || _('Speed test failed')) : ''
        });
        saveHistory(list);
        this.drawHistory();
    },

    drawHistory: function () {
        const list = loadHistory();
        if (list.length == 0) {
            this.historyList.replaceChildren(E('div', { class: 'mx-po0__empty' }, _('No speed tests yet.')));
            return;
        }
        this.historyList.replaceChildren(...list.map((r) => {
            const when = new Date(r.time).toLocaleString();
            const setup = [sourceTitle(r.source), r.connections > 1 ? _('Multi-thread (8)') : _('Single thread')].join(' · ');
            const result = r.error
                ? E('span', { class: 'mx-st__hist-error' }, _('Failed: %s').format(r.error))
                : E('span', { class: 'mx-st__hist-result' }, [
                    E('span', {}, `${r.latencyMs ?? '--'} ms`),
                    E('span', { class: 'is-download' }, `↓ ${fmtMbps(r.downloadMbps)}`),
                    E('span', { class: 'is-upload' }, `↑ ${fmtMbps(r.uploadMbps)}`)
                ]);
            return E('div', { class: 'mx-po0__row mx-st__hist' }, [
                E('div', { class: 'mx-po0__main' }, [
                    E('div', { class: 'mx-st__hist-via' }, viaTitle(r.via)),
                    E('div', { class: 'mx-po0__token' }, `${when} · ${setup}`)
                ]),
                result
            ]);
        }));
    },

    // 切回本页：不在测时重取节点列表（订阅可能换过）与当前状态
    onShow: function () {
        if (this.isRunning()) {
            return this.poll();
        }
        return Promise.all([
            L.resolveDefault(meowx.api('GET', '/meowx/speedtest'), {}),
            L.resolveDefault(meowx.api('GET', '/proxies'), {})
        ]).then(([status, proxies]) => {
            const selected = this.nodeSelect.value;
            this.proxyInfo = parseProxies(proxies);
            this.fillNodes(this.proxyInfo.nodes.includes(selected) ? selected : this.proxyInfo.preferred);
            this.apply(status);
            if (this.isRunning()) {
                this.poll();
            }
        });
    },

    // 切到别的页签：停掉正在跑的测速
    onHide: function () {
        this.pollSeq = (this.pollSeq ?? 0) + 1;
        clearTimeout(this.timer);
        if (this.isRunning()) {
            return meowx.api('POST', '/meowx/speedtest/stop');
        }
    }
});
