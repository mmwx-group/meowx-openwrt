'use strict';
'require baseclass';
'require rpc';
'require tools.meowx as meowx';

// MeowX 测速榜（规格 miaomiaowuC/Design/speedtest-board.md §2 / §3 / §5.2 / §6，与 iOS / macOS / 安卓 / Windows 客户端同一套）：
// 用户同意时把测完的结果上传到许可证服务，拿回结果链接、「超越了 x%」与删除凭据，存进这个浏览器里的测速记录。
// 上传请求由内核经**测速用的同一个出站**发（POST /meowx/speedtest/board）：服务端按来源 IP 判出口归属。
// 路由器登录了主控账户时先经 meowx-core 向主控要一张上传凭证（绑定正文的 sha256），拿不到就匿名传。
// 路由器的网页多半是 http 打开的，浏览器不给 crypto.subtle，sha256 自己算。

const API = 'https://license.miaomiaowux.com';
const RESULTS = API + '/api/v2/speedtest/results';
const MAX_SAMPLES = 40;
const GRANT_TIMEOUT = 12000;

const callSpeedBoard = rpc.declare({
    object: 'luci.meowx',
    method: 'speedboard',
    params: ['action', 'upload', 'hash'],
    expect: {}
});

const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

// sha256(bytes) 的 64 位小写 hex
function sha256Hex(bytes) {
    const len = bytes.length;
    const padded = new Uint8Array(((len + 9 + 63) >> 6) << 6);
    padded.set(bytes);
    padded[len] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(padded.length - 8, Math.floor(len / 0x20000000));
    dv.setUint32(padded.length - 4, (len << 3) >>> 0);
    const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const W = new Uint32Array(64);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let off = 0; off < padded.length; off += 64) {
        for (let i = 0; i < 16; i++) {
            W[i] = dv.getUint32(off + i * 4);
        }
        for (let i = 16; i < 64; i++) {
            const s0 = rotr(W[i - 15], 7) ^ rotr(W[i - 15], 18) ^ (W[i - 15] >>> 3);
            const s1 = rotr(W[i - 2], 17) ^ rotr(W[i - 2], 19) ^ (W[i - 2] >>> 10);
            W[i] = (W[i - 16] + s0 + W[i - 7] + s1) >>> 0;
        }
        let [a, b, c, d, e, f, g, h] = H;
        for (let i = 0; i < 64; i++) {
            const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + W[i]) >>> 0;
            const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
            h = g; g = f; f = e; e = (d + t1) >>> 0;
            d = c; c = b; b = a; a = (t1 + t2) >>> 0;
        }
        [a, b, c, d, e, f, g, h].forEach((v, i) => { H[i] = (H[i] + v) >>> 0; });
    }
    return H.map((x) => x.toString(16).padStart(8, '0')).join('');
}

function base64(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
        s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s);
}

const round2 = (v) => Math.round(v * 100) / 100;
const round2n = (v) => (v == null || !isFinite(v)) ? null : round2(v);

// 采样压缩：每段取平均，保留至多 count 个点（同客户端 SpeedTestHistory.downsample）
function downsample(samples, count) {
    count = count ?? MAX_SAMPLES;
    if (!Array.isArray(samples)) {
        return [];
    }
    if (samples.length <= count) {
        return samples.slice();
    }
    const size = samples.length / count;
    const out = [];
    for (let i = 0; i < count; i++) {
        const lo = Math.floor(i * size);
        const hi = Math.max(lo + 1, Math.min(samples.length, Math.floor((i + 1) * size)));
        const slice = samples.slice(lo, hi);
        out.push(slice.reduce((x, y) => x + y, 0) / slice.length);
    }
    return out;
}

// 节点协议的规格码（§2：配置里节点 type 的小写）。内核 /proxies 里 type 是 mihomo 的写法（Vless、Shadowsocks、Socks5…）
function protocolCode(type) {
    let t = String(type ?? '').trim().toLowerCase();
    t = { shadowsocks: 'ss', shadowsocksr: 'ssr', socks: 'socks5' }[t] ?? t;
    t = t.replace(/[^a-z0-9_-]/g, '');
    return t ? t.slice(0, 32) : null;
}

// 插件版本：opkg 是「0.3.5-1」、apk 是「0.3.5-r1」，只要前面的版本号
function appVersion(raw) {
    return String(raw ?? '').trim().split('-')[0].slice(0, 32);
}

// Retry-After（秒数或 HTTP 日期）→ 毫秒；认不出给 10 分钟（同服务端的限流窗口）
function retryAfterMs(value) {
    const v = String(value ?? '').trim();
    if (/^\d+$/.test(v)) {
        return Math.min(Math.max(parseInt(v, 10), 1), 86400) * 1000;
    }
    const at = Date.parse(v);
    return isNaN(at) ? 600000 : Math.max(1000, at - Date.now());
}

function failure(error, retryable, retryAt) {
    return { status: 'failed', error: error, retryable: retryable !== false, retryAt: retryAt ?? null };
}

// 内核回的 BoardResponse；内核没在跑（回 {}）或旧内核（回 { message: '404 page not found' }）给 null
function parseResponse(res) {
    return res && typeof res.status == 'number' ? res : null;
}

function parseBody(res) {
    try {
        const j = JSON.parse(res?.body ?? '');
        return j && typeof j == 'object' ? j : null;
    } catch (e) {
        return null;
    }
}

function send(proxy, method, url, headers, body) {
    const req = { proxy: proxy, method: method, url: url, headers: headers };
    if (body != null) {
        req.body = body;
    }
    return meowx.api('POST', '/meowx/speedtest/board', req).then(parseResponse, () => null);
}

return baseclass.extend({
    BOARD_PAGE: 'https://speed.meowx.net/board',

    sha256Hex: sha256Hex,
    downsample: downsample,
    protocolCode: protocolCode,
    appVersion: appVersion,

    // { asked, upload, install_id }；拿不到当作没问过、不上传
    status: function () {
        return L.resolveDefault(callSpeedBoard('status', false, ''), {}).then((res) => ({
            asked: res?.asked === true,
            upload: res?.upload === true,
            installId: typeof res?.install_id == 'string' ? res.install_id : ''
        }));
    },

    setUpload: function (upload) {
        return callSpeedBoard('set', !!upload, '');
    },

    resetIdentity: function () {
        return callSpeedBoard('reset', false, '');
    },

    // 上传凭证；拿不到（没登录主控、主控旧、没许可证、限流、超时）回 null
    grant: function (hash) {
        const call = L.resolveDefault(callSpeedBoard('grant', false, hash), null)
            .then((res) => res?.success && typeof res.grant == 'string' && res.grant ? res.grant : null);
        return Promise.race([call, new Promise((resolve) => setTimeout(() => resolve(null), GRANT_TIMEOUT))]);
    },

    // 这条记录能不能上传；能 = null，否则是原因。只传测完的（§3）；旧版本的记录没存采样等字段
    blocker: function (r) {
        if (r.error) {
            return _('Failed tests are not uploaded');
        }
        if (r.downloadMbps == null) {
            return _('No download result');
        }
        if (!Array.isArray(r.downloadSamples) || !r.id) {
            return _('Recorded by an older version');
        }
        if (r.via != 'DIRECT' && !r.protocol) {
            return _('No node protocol for this record');
        }
        return null;
    },

    // 上传正文（§3，字段 snake_case）。不传节点名、IP、主控地址、账号
    body: function (r, installId, version) {
        const hasUpload = r.uploadMbps != null && r.source != 'google' && r.source != 'microsoft';
        const exit = r.exit;
        return {
            v: 1,
            client: { app: 'MeowX', platform: 'openwrt', version: version, install_id: installId },
            test: {
                source: r.source,
                connections: r.connections,
                mode: r.via == 'DIRECT' ? 'direct' : 'node',
                protocol: r.via == 'DIRECT' ? null : r.protocol,
                network: 'wired',
                latency_ms: r.latencyMs ?? 0,
                download_mbps: round2n(r.downloadMbps),
                upload_mbps: hasUpload ? round2n(r.uploadMbps) : null,
                download_peak_mbps: round2n(r.downloadPeakMbps),
                upload_peak_mbps: hasUpload ? round2n(r.uploadPeakMbps) : null,
                download_samples: downsample(r.downloadSamples).map(round2),
                upload_samples: hasUpload ? downsample(r.uploadSamples).map(round2) : [],
                bytes_used: r.bytesUsed ?? 0,
                // 内核没给时长：按每段 10 秒、加测延迟约 1.5 秒估（同客户端；服务端只拿它粗核「用量 ≈ 速率 × 时长」）
                duration_ms: r.durationMs || ((hasUpload ? 20000 : 10000) + 1500),
                server: r.server ?? '',
                finished_at: new Date(r.time).toISOString().replace(/\.\d{3}Z$/, 'Z')
            },
            claimed_exit: exit && (exit.asn || exit.org || exit.country) ? { asn: exit.asn ?? 0, org: exit.org ?? '', country: exit.country ?? '' } : null
        };
    },

    // 上传一条，回记录里的 board 状态。每次都重新组正文、重新要凭证（凭证只有 5 分钟、一次性）
    upload: async function (r, installId, version) {
        const blocker = this.blocker(r);
        if (blocker) {
            return failure(blocker, false);
        }
        const bytes = new TextEncoder().encode(JSON.stringify(this.body(r, installId, version)));
        const body = base64(bytes);
        const token = await this.grant(sha256Hex(bytes));
        const type = { 'Content-Type': 'application/json' };
        let resp = await send(r.via, 'POST', RESULTS, token ? Object.assign({ 'X-MeowX-Speed-Grant': token }, type) : type, body);
        let attributed = !!token;
        // 凭证验不过（过期 / 用过 / 不符）：去掉凭证匿名再传一次（这一次不占限流名额，§5.2.1）
        if (resp?.status == 401 && token) {
            attributed = false;
            resp = await send(r.via, 'POST', RESULTS, type, body);
        }
        return this.outcome(resp, attributed);
    },

    // 上传的应答 → board 状态（§5.2 / §5.2.1）
    outcome: function (resp, attributed) {
        if (!resp) {
            return failure(_('MeowX is not running, or the core is too old'));
        }
        if (resp.noProxy) {
            return failure(_('The node used for the test is no longer in the current config'), false);
        }
        if (resp.status == 0) {
            return failure(resp.error ? _('Could not reach the speed board: %s').format(resp.error) : _('Could not reach the speed board'));
        }
        const j = parseBody(resp);
        if (resp.status == 200) {
            if (typeof j?.id != 'string' || !j.id || typeof j?.url != 'string' || !j.url) {
                return failure(_('Unparseable response from the speed board'));
            }
            const p = j.percentile;
            return {
                status: 'uploaded',
                id: j.id,
                url: j.url,
                deleteToken: typeof j.delete_token == 'string' ? j.delete_token : null,
                percentile: p && typeof p.value == 'number'
                    ? { value: Math.max(0, Math.min(100, Math.round(p.value))), scope: typeof p.scope == 'string' ? p.scope : '', samples: p.samples ?? 0 }
                    : null,
                provider: typeof j.provider?.name == 'string' && j.provider.name ? j.provider.name : null,
                attributed: typeof j.attributed == 'boolean' ? j.attributed : attributed
            };
        }
        if (resp.status == 400) {
            return failure(_('The speed board did not accept this result'), false);
        }
        if (resp.status == 429) {
            return failure(_('Too many uploads'), true, Date.now() + retryAfterMs(resp.retryAfter));
        }
        if (resp.status >= 500) {
            return failure(_('The speed board is temporarily unavailable (HTTP %d)').format(resp.status));
        }
        return failure(_('Upload failed (HTTP %d)').format(resp.status));
    },

    // 删除：经这条记录测速用的出站发（它已不在当前配置里就走直连）。回 { ok, message }；200（含已删过）/ 404 都算删掉了
    delete: async function (r) {
        const b = r.board;
        if (b?.status != 'uploaded' || !b.id) {
            return { ok: true };
        }
        if (!b.deleteToken) {
            return { ok: false, message: _('This record has no delete token') };
        }
        const url = RESULTS + '/' + encodeURIComponent(b.id);
        const headers = { 'X-MeowX-Delete-Token': b.deleteToken };
        let resp = await send(r.via, 'DELETE', url, headers);
        if (resp?.noProxy) {
            resp = await send('DIRECT', 'DELETE', url, headers);
        }
        if (!resp) {
            return { ok: false, message: _('MeowX is not running, or the core is too old') };
        }
        if (resp.status == 200 || resp.status == 404) {
            return { ok: true };
        }
        if (resp.status == 0) {
            return { ok: false, message: resp.error ? _('Could not reach the speed board: %s').format(resp.error) : _('Could not reach the speed board') };
        }
        if (resp.status == 403) {
            return { ok: false, message: _('Wrong delete token') };
        }
        if (resp.status == 429) {
            return { ok: false, message: _('Too many requests, try again later') };
        }
        return { ok: false, message: _('Delete failed (HTTP %d)').format(resp.status) };
    }
});
