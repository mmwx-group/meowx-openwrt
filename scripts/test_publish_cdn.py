import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_cdn as p  # noqa: E402


class MergeTest(unittest.TestCase):
    NOW = '2026-10-16T00:00:00Z'

    def test_keeps_other_platforms(self):
        manifest = {'platforms': {'macos': {'version': '0.5.1'}, 'android': {'version': '0.2.7'}}}
        out = p.merge_manifest(manifest, p.openwrt_entry('0.1.0', '1', '0.3.1', self.NOW), self.NOW)
        self.assertEqual(out['platforms']['macos'], {'version': '0.5.1'})
        self.assertEqual(out['platforms']['android'], {'version': '0.2.7'})
        self.assertEqual(out['platforms']['openwrt']['version'], '0.1.0')
        self.assertEqual(out['platforms']['openwrt']['files'], [])
        self.assertEqual(out['updatedAt'], self.NOW)

    def test_install_command(self):
        e = p.openwrt_entry('0.1.0', '1', '0.3.1', self.NOW)
        self.assertEqual(e['install'], 'wget -O - https://dl.miaomiaowux.com/meowx/openwrt/install.sh | ash')

    def test_rejects_older(self):
        manifest = {'platforms': {'openwrt': {'version': '0.2.0'}}}
        with self.assertRaises(SystemExit):
            p.merge_manifest(manifest, p.openwrt_entry('0.1.9', '1', '0.3.1', self.NOW), self.NOW)

    def test_same_version_republish(self):
        manifest = {'platforms': {'openwrt': {'version': '0.1.0', 'build': '1'}}}
        out = p.merge_manifest(manifest, p.openwrt_entry('0.1.0', '2', '0.3.1', self.NOW), self.NOW)
        self.assertEqual(out['platforms']['openwrt']['build'], '2')


if __name__ == '__main__':
    unittest.main()
