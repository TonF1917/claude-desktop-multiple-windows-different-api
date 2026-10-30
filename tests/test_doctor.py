import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

MACOS_DIR = Path(__file__).resolve().parent.parent / 'macos'
sys.path.insert(0, str(MACOS_DIR))

import claude_multi as cm


class TestDoctor(unittest.TestCase):

    def test_doctor_python_version_check(self):
        """Doctor must audit the Python runtime version."""
        results = cm.run_doctor()
        py_check = next((r for r in results if r['name'] == 'Python Version'), None)
        self.assertIsNotNone(py_check)
        self.assertIn(py_check['status'], ('PASS', 'WARN'))

    def test_doctor_missing_claude_app(self):
        """Doctor must report FAIL when Claude.app is not found."""
        with tempfile.TemporaryDirectory() as td:
            missing_app = Path(td) / 'Claude.app'
            results = cm.run_doctor(official_app_path=missing_app)
            app_check = next((r for r in results if r['name'] == 'Claude.app'), None)
            self.assertIsNotNone(app_check)
            self.assertEqual(app_check['status'], 'FAIL')
            self.assertIn('remediation', app_check)

    def test_doctor_valid_claude_app(self):
        """Doctor must report PASS and display version when valid Claude.app is found."""
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / 'Claude.app'
            plist_dir = app / 'Contents'
            plist_dir.mkdir(parents=True)
            info_plist = plist_dir / 'Info.plist'
            data = {'CFBundleShortVersionString': '0.9.15'}
            with open(info_plist, 'wb') as fp:
                plistlib.dump(data, fp)

            results = cm.run_doctor(official_app_path=app)
            app_check = next((r for r in results if r['name'] == 'Claude.app'), None)
            self.assertIsNotNone(app_check)
            self.assertEqual(app_check['status'], 'PASS')
            self.assertIn('0.9.15', app_check['message'])

    def test_doctor_proxy_embedded_credentials(self):
        """Doctor must warn if any instance has embedded credentials in its proxy URL."""
        with tempfile.TemporaryDirectory() as td:
            cfg_path = Path(td) / 'instances.json'
            cfg_path.write_text(json.dumps({
                'instances': [
                    {'id': 'p1', 'name': 'P1', 'proxy': 'http://user:pass@127.0.0.1:8080'}
                ]
            }), encoding='utf-8')

            results = cm.run_doctor(instances_path=cfg_path)
            proxy_check = next((r for r in results if r['name'] == 'Proxy Syntax'), None)
            self.assertIsNotNone(proxy_check)
            self.assertEqual(proxy_check['status'], 'WARN')
            self.assertIn('p1', proxy_check['message'])

    def test_doctor_clean_proxy_passes(self):
        """Doctor must PASS proxy syntax when all proxies are clean."""
        with tempfile.TemporaryDirectory() as td:
            cfg_path = Path(td) / 'instances.json'
            cfg_path.write_text(json.dumps({
                'instances': [
                    {'id': 'p2', 'name': 'P2', 'proxy': 'http://127.0.0.1:8080'}
                ]
            }), encoding='utf-8')

            results = cm.run_doctor(instances_path=cfg_path)
            proxy_check = next((r for r in results if r['name'] == 'Proxy Syntax'), None)
            self.assertIsNotNone(proxy_check)
            self.assertEqual(proxy_check['status'], 'PASS')

    def test_doctor_corrupted_json(self):
        """Doctor must FAIL config permissions when instances.json is corrupted."""
        with tempfile.TemporaryDirectory() as td:
            cfg_path = Path(td) / 'instances.json'
            cfg_path.write_text('{invalid_json: 123}', encoding='utf-8')

            results = cm.run_doctor(instances_path=cfg_path)
            cfg_check = next((r for r in results if r['name'] == 'Config Permissions'), None)
            self.assertIsNotNone(cfg_check)
            self.assertEqual(cfg_check['status'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
