#!/usr/bin/env python3
"""把 OpenWrt 版登记进 MeowX 的发布清单 dl.miaomiaowux.com/meowx/latest.json（platforms.openwrt）。

软件源本身（各架构的 ipk / apk、签名、安装脚本）由工作流先用 aws s3 sync 传到 meowx/openwrt/，这里只改清单：
文档站的「客户端下载」页读它显示版本与安装命令。清单里还有 MeowX 其它端（macos / android / windows）的条目，
由别的仓库写——这里只改 openwrt 一段，其余原样保留；用 If-Match 条件写，别的仓库同时发版时重读重试。

openwrt 条目：
  {"version", "build", "core", "releasedAt", "feed", "install", "files": []}
files 留空：软件源按架构分了几十个目录，用户用安装脚本或软件源装，不逐个列包。

依赖：python3 + aws cli（GitHub runner 自带）。环境变量：R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY，
可选 R2_BUCKET（默认 mmwx-dl）。

用法：
  python3 scripts/publish_cdn.py --version 0.1.0 --build 1 --core 0.3.1
  python3 scripts/publish_cdn.py --version 0.1.0 --build 1 --core 0.3.1 --dry-run   # 只打印，不写 R2
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

PUBLIC_BASE = 'https://dl.miaomiaowux.com'
PREFIX = 'meowx'
MANIFEST_KEY = f'{PREFIX}/latest.json'
FEED_URL = f'{PUBLIC_BASE}/{PREFIX}/openwrt'
PLATFORM = 'openwrt'


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r'\d+', v.split('+')[0]))


def openwrt_entry(version: str, build: str, core: str, now: str) -> dict:
    return {
        'version': version,
        'build': build,
        'core': core,
        'releasedAt': now,
        'feed': FEED_URL,
        'install': f'wget -O - {FEED_URL}/install.sh | ash',
        'files': [],
    }


def merge_manifest(manifest: dict, entry: dict, now: str) -> dict:
    """并进 openwrt 一段；比线上旧的版本拒绝（避免在老提交上手动发布把所有人「更新」回旧版）。"""
    platforms = dict(manifest.get('platforms') or {})
    current = str((platforms.get(PLATFORM) or {}).get('version') or '')
    if current and version_key(entry['version']) < version_key(current):
        raise SystemExit(f'{PLATFORM}: 线上已是 {current}，不发布更旧的 {entry["version"]}')
    platforms[PLATFORM] = entry
    return {**manifest, 'platforms': platforms, 'updatedAt': now}


class R2:
    def __init__(self) -> None:
        missing = [k for k in ('R2_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY') if not os.environ.get(k)]
        if missing:
            raise SystemExit(f'缺少仓库 secret：{", ".join(missing)}')
        self.bucket = os.environ.get('R2_BUCKET') or 'mmwx-dl'
        self.endpoint = f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com"
        self.env = {
            **os.environ,
            'AWS_ACCESS_KEY_ID': os.environ['R2_ACCESS_KEY_ID'],
            'AWS_SECRET_ACCESS_KEY': os.environ['R2_SECRET_ACCESS_KEY'],
            'AWS_DEFAULT_REGION': 'auto',
            # aws cli 2.23 起默认带 CRC 校验头，R2 不一定认；只在 API 要求时才算
            'AWS_REQUEST_CHECKSUM_CALCULATION': 'when_required',
            'AWS_RESPONSE_CHECKSUM_VALIDATION': 'when_required',
        }

    def _aws(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(['aws', '--endpoint-url', self.endpoint, *args], env=self.env, capture_output=True, text=True)

    def get_manifest(self) -> tuple[dict, str | None]:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'latest.json'
            r = self._aws('s3api', 'get-object', '--bucket', self.bucket, '--key', MANIFEST_KEY, str(out))
            if r.returncode != 0:
                if 'NoSuchKey' in r.stderr or 'Not Found' in r.stderr:
                    return {}, None
                raise SystemExit(f'读取 {MANIFEST_KEY} 失败：{r.stderr.strip()}')
            etag = json.loads(r.stdout).get('ETag')
            return json.loads(out.read_text(encoding='utf-8')), etag

    def put_manifest(self, manifest: dict, etag: str | None) -> bool:
        """条件写：线上被别人改过（ETag 变了）返回 False 让调用方重读重试。"""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'latest.json'
            out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            cond = ['--if-match', etag] if etag else ['--if-none-match', '*']
            r = self._aws('s3api', 'put-object', '--bucket', self.bucket, '--key', MANIFEST_KEY, '--body', str(out),
                          '--content-type', 'application/json', '--cache-control', 'no-cache', *cond)
            if r.returncode == 0:
                return True
            if 'PreconditionFailed' in r.stderr or '412' in r.stderr:
                return False
            raise SystemExit(f'写 {MANIFEST_KEY} 失败：{r.stderr.strip()}')


def _open(url: str, timeout: int):
    # Cloudflare 会拦 Python-urllib 默认 UA（403），带一个明确的 UA
    req = urllib.request.Request(f'{url}?t={int(time.time())}', headers={'User-Agent': 'MeowX-publish/1.0'})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_public_manifest() -> dict:
    with _open(f'{PUBLIC_BASE}/{MANIFEST_KEY}', 30) as resp:
        return json.load(resp)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--version', required=True)
    ap.add_argument('--build', required=True)
    ap.add_argument('--core', required=True)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    now = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    entry = openwrt_entry(args.version, args.build, args.core, now)

    if args.dry_run:
        print(json.dumps(merge_manifest(fetch_public_manifest(), entry, now), ensure_ascii=False, indent=2))
        return

    r2 = R2()
    for attempt in range(6):
        manifest, etag = r2.get_manifest()
        manifest = merge_manifest(manifest, entry, now)
        if r2.put_manifest(manifest, etag):
            break
        print('latest.json 被并发修改，重读重试')
        time.sleep(2 + attempt * 2)
    else:
        raise SystemExit('latest.json 多次条件写冲突，放弃')
    print(f'已更新 {MANIFEST_KEY}：{PLATFORM} {args.version}')

    # 公网回读：安装脚本与软件源公钥能下到，清单里是这一版
    for name in ('install.sh', 'feed.sh', 'uninstall.sh', 'key-build.pub', 'public-key.pem'):
        with _open(f'{FEED_URL}/{name}', 60) as resp:
            if resp.status != 200 or not resp.read():
                raise SystemExit(f'公网校验失败：{FEED_URL}/{name}')
        print(f'  OK {FEED_URL}/{name}')
    got = fetch_public_manifest()['platforms'][PLATFORM]['version']
    if got != args.version:
        raise SystemExit(f'公网 latest.json 的 {PLATFORM} 还是 {got}（CDN 缓存？）')
    print('完成')


if __name__ == '__main__':
    sys.exit(main())
