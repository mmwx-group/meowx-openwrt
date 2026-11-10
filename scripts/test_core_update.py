"""meowx/files/scripts/core_update.sh：从 meowx-core 的 GitHub Release 下载内核替换 /usr/bin/meowx-core。

用 sh 真的跑脚本，wget / ucode / sha256sum 换成桩：wget 按地址从临时目录里的「Release」取文件，加速地址
https://mirror.test/<原地址> 可以设成正常、回一张网页、或失败；内核是一段 shell，-v 时打印版本。
"""
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'meowx' / 'files' / 'scripts' / 'core_update.sh'
REPO = 'https://github.com/mmwx-group/meowx-core'
# 跑脚本用的 shell：缺省 sh，TEST_SH=dash 换成 dash（更接近路由器上的 busybox ash）
TEST_SH = os.environ.get('TEST_SH', 'sh')

STUBS = {
    # wget -q -T <秒> -O <目标> <地址>
    'wget': r'''
        while [ $# -gt 1 ]; do
            case "$1" in -O) out="$2"; shift ;; esac
            shift
        done
        url="$1"
        echo "$url" >> "$T/wget.log"
        case "$url" in
            https://mirror.test/*)
                mode=$(cat "$T/mirror_mode" 2>/dev/null)
                [ "$mode" = fail ] && exit 4
                if [ "$mode" = garbage ]; then
                    page='<html>mirror error</html>'
                    if [ "$out" = - ]; then echo "$page"; else echo "$page" > "$out"; fi
                    exit 0
                fi
                url="${url#https://mirror.test/}"
                ;;
        esac
        file="$T/www/${url#https://}"
        [ -f "$file" ] || exit 8
        if [ "$out" = - ]; then cat "$file"; else cp "$file" "$out"; fi
    ''',
    # ucode -S <cli> url <地址>：开了加速（$T/mirror 存在）时换算成加速地址
    'ucode': r'''
        if [ -f "$T/mirror" ]; then echo "https://mirror.test/$4"; else echo "$4"; fi
    ''',
    'sha256sum': 'shasum -a 256 "$@"',
}

INIT = r'''#!/bin/sh
case "$1" in
    running) [ -f "$T/service_running" ] ;;
    restart) echo restart >> "$T/init.log" ;;
esac
'''


def fake_core(version):
    # 「内核」：-v 时与真的一样打印一行 Mihomo Meta meowx-<版本> …
    return ('#!/bin/sh\n[ "$1" = -v ] && echo "Mihomo Meta meowx-%s linux amd64 with go1.26 test"\n' % version).encode()


class CoreUpdateTest(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.t)
        bin_dir = self.t / 'bin'
        bin_dir.mkdir()
        for name, body in STUBS.items():
            stub = bin_dir / name
            stub.write_text('#!/bin/sh\n' + textwrap.dedent(body))
            stub.chmod(0o755)
        init = self.t / 'init'
        init.write_text(INIT)
        init.chmod(0o755)
        self.core = self.t / 'usr' / 'bin' / 'meowx-core'
        self.core.parent.mkdir(parents=True)
        self.core.write_bytes(fake_core('0.4.7'))
        self.core.chmod(0o755)
        self.release_file = self.t / 'openwrt_release'
        self.set_arch('x86_64')
        (self.t / 'service_running').touch()
        self.env = {
            'PATH': f'{bin_dir}:/usr/bin:/bin',
            'T': str(self.t),
            'MEOWX_CORE_PATH': str(self.core),
            'MEOWX_INIT': str(init),
            'MEOWX_OPENWRT_RELEASE': str(self.release_file),
            'MEOWX_CORE_WORK_DIR': str(self.t / 'work'),
        }

    def set_arch(self, arch):
        self.release_file.write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_ARCH='%s'\n" % arch)

    def publish(self, version, asset='meowx-core-linux-amd64.gz', content=None, sums=None, latest=True):
        """在桩的「GitHub」上发一个 Release：<版本>/<文件>.gz、sha256sums.txt，latest 时 version.txt 指向它。"""
        www = self.t / 'www' / REPO.replace('https://', '')
        rel = www / 'releases' / 'download' / ('v' + version)
        rel.mkdir(parents=True, exist_ok=True)
        data = gzip.compress(content if content is not None else fake_core(version))
        (rel / asset).write_bytes(data)
        digest = hashlib.sha256(data).hexdigest() if sums is None else sums
        (rel / 'sha256sums.txt').write_text('%s  %s\n' % (digest, asset))
        if latest:
            latest_dir = www / 'releases' / 'latest' / 'download'
            latest_dir.mkdir(parents=True, exist_ok=True)
            (latest_dir / 'version.txt').write_text(version + '\n')

    def run_script(self, *args):
        return subprocess.run([TEST_SH, str(SCRIPT), *args], env=self.env, capture_output=True, text=True, timeout=30)

    def restarted(self):
        log = self.t / 'init.log'
        return log.exists() and 'restart' in log.read_text()

    def wget_urls(self):
        log = self.t / 'wget.log'
        return log.read_text().splitlines() if log.exists() else []

    # ---- 架构 ----

    def test_asset_names(self):
        cases = {
            'x86_64': 'amd64',
            'i386_pentium4': '386',
            'aarch64_cortex-a53': 'arm64',
            'arm_cortex-a7_neon-vfpv4': 'armv7',
            'arm_cortex-a9_vfpv3-d16': 'armv7',
            'arm_cortex-a5_vfpv4': 'armv7',
            'arm_cortex-a9': 'armv5',
            'arm_arm1176jzf-s_vfp': 'armv5',
            'arm_arm926ej-s': 'armv5',
            'mipsel_24kc': 'mipsle-softfloat',
            'mips_24kc': 'mips-softfloat',
            'mips64_octeonplus': 'mips64-softfloat',
            'riscv64_riscv64': 'riscv64',
            'loongarch64_generic': 'loong64',
        }
        for arch, name in cases.items():
            self.set_arch(arch)
            r = self.run_script('asset')
            self.assertEqual(r.stdout.strip(), 'meowx-core-linux-%s.gz' % name, arch)

    def test_unknown_arch(self):
        for arch in ('mips64el_mips64r2', 'powerpc_464fp', ''):
            self.set_arch(arch)
            r = self.run_script('asset')
            self.assertNotEqual(r.returncode, 0, arch)

    def test_every_released_arch_has_a_core(self):
        # 软件源出包的每个架构都得有能直接下载的内核
        workflow = (ROOT / '.github' / 'workflows' / 'release-packages.yml').read_text()
        matrix = workflow[workflow.index('matrix:'):workflow.index('steps:')]
        arches = set(re.findall(r'(?:arch:[ \t]*|^[ \t]*-[ \t]*)(x86_64|[a-z0-9]+_[a-z0-9_.-]+)[ \t]*$', matrix, re.M))
        self.assertGreater(len(arches), 10)
        for arch in sorted(arches):
            self.set_arch(arch)
            self.assertEqual(self.run_script('asset').returncode, 0, arch)

    # ---- 最新版本 ----

    def test_latest_direct(self):
        self.publish('0.4.8')
        r = self.run_script('latest')
        self.assertEqual(r.stdout.strip(), '0.4.8')
        self.assertEqual(self.wget_urls(), [REPO + '/releases/latest/download/version.txt'])

    def test_latest_via_mirror(self):
        self.publish('0.4.8')
        (self.t / 'mirror').touch()
        r = self.run_script('latest')
        self.assertEqual(r.stdout.strip(), '0.4.8')
        self.assertTrue(all(u.startswith('https://mirror.test/') for u in self.wget_urls()))

    def test_latest_mirror_returns_page_then_direct(self):
        self.publish('0.4.8')
        (self.t / 'mirror').touch()
        (self.t / 'mirror_mode').write_text('garbage')
        r = self.run_script('latest')
        self.assertEqual(r.stdout.strip(), '0.4.8')
        self.assertEqual(self.wget_urls()[-1], REPO + '/releases/latest/download/version.txt')

    def test_latest_unreachable(self):
        r = self.run_script('latest')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), '')

    # ---- 更新 ----

    def test_update_to_latest(self):
        self.publish('0.4.8')
        r = self.run_script('update')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('success', r.stdout)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.8'))
        self.assertTrue(os.access(self.core, os.X_OK))
        self.assertTrue(self.restarted())
        self.assertFalse((self.t / 'work').exists())
        self.assertFalse(Path(str(self.core) + '.new').exists())

    def test_update_given_version(self):
        self.publish('0.4.9')
        self.publish('0.4.8', latest=False)
        r = self.run_script('update', '0.4.8')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.8'))

    def test_update_service_stopped(self):
        (self.t / 'service_running').unlink()
        self.publish('0.4.8')
        r = self.run_script('update')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.8'))
        self.assertFalse(self.restarted())

    def test_update_via_mirror(self):
        self.publish('0.4.8')
        (self.t / 'mirror').touch()
        r = self.run_script('update')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(all(u.startswith('https://mirror.test/') for u in self.wget_urls()))

    def test_update_mirror_returns_page_then_direct(self):
        self.publish('0.4.8')
        (self.t / 'mirror').touch()
        (self.t / 'mirror_mode').write_text('garbage')
        r = self.run_script('update', '0.4.8')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('checksum mismatch (mirror)', r.stdout)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.8'))

    def test_update_checksum_mismatch(self):
        self.publish('0.4.8', sums='0' * 64)
        r = self.run_script('update')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.7'))
        self.assertFalse(self.restarted())
        self.assertFalse(Path(str(self.core) + '.new').exists())

    def test_update_core_does_not_run(self):
        # 架构不对的内核跑不起来（-v 什么也不打印）：不换
        self.publish('0.4.8', content=b'#!/bin/sh\nexit 126\n')
        r = self.run_script('update')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('does not run', r.stdout)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.7'))
        self.assertFalse(self.restarted())
        self.assertFalse(Path(str(self.core) + '.new').exists())

    def test_update_unknown_arch(self):
        self.set_arch('powerpc_464fp')
        self.publish('0.4.8')
        r = self.run_script('update')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.core.read_bytes(), fake_core('0.4.7'))
        self.assertEqual([u for u in self.wget_urls() if '/releases/download/' in u], [])

    def test_update_invalid_version(self):
        r = self.run_script('update', '0.4.8;rm -rf /')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.wget_urls(), [])


if __name__ == '__main__':
    unittest.main()
