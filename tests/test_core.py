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


class TestCore(unittest.TestCase):

    def test_check_clone_update_matching(self):
        """check_clone_update returns outdated=False when bundle version matches official app."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app = root / 'Claude.app'
            pdir = app / 'Contents'
            pdir.mkdir(parents=True)
            with open(pdir / 'Info.plist', 'wb') as fp:
                plistlib.dump({'CFBundleShortVersionString': '1.2.3'}, fp)

            clone = root / 'Claude - Work.app'
            cpdir = clone / 'Contents'
            cpdir.mkdir(parents=True)
            (cpdir / '.multi-version').write_text('1.2.3|violet|Work|2', encoding='utf-8')

            inst = {'id': 'work', 'name': 'Work', 'kind': '3p'}
            orig_clone_path = cm.clone_path
            cm.clone_path = lambda i: clone
            try:
                outdated, src_v, clone_v = cm.check_clone_update(inst, src_app=app)
                self.assertFalse(outdated)
                self.assertEqual(src_v, '1.2.3')
                self.assertEqual(clone_v, '1.2.3')
            finally:
                cm.clone_path = orig_clone_path

    def test_check_clone_update_outdated(self):
        """check_clone_update returns outdated=True when official Claude.app has updated."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app = root / 'Claude.app'
            pdir = app / 'Contents'
            pdir.mkdir(parents=True)
            with open(pdir / 'Info.plist', 'wb') as fp:
                plistlib.dump({'CFBundleShortVersionString': '1.3.0'}, fp)

            clone = root / 'Claude - Work.app'
            cpdir = clone / 'Contents'
            cpdir.mkdir(parents=True)
            (cpdir / '.multi-version').write_text('1.2.3|violet|Work|2', encoding='utf-8')

            inst = {'id': 'work', 'name': 'Work', 'kind': '3p'}
            orig_clone_path = cm.clone_path
            cm.clone_path = lambda i: clone
            try:
                outdated, src_v, clone_v = cm.check_clone_update(inst, src_app=app)
                self.assertTrue(outdated)
                self.assertEqual(src_v, '1.3.0')
                self.assertEqual(clone_v, '1.2.3')
            finally:
                cm.clone_path = orig_clone_path

    def test_sync_mcp_servers(self):
        """sync_mcp_servers propagates mcpServers configuration to non-primary instances."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            canon = root / 'canonical' / 'claude_desktop_config.json'
            canon.parent.mkdir(parents=True)
            mcp_data = {'mcpServers': {'github': {'command': 'npx', 'args': ['-y', '@modelcontextprotocol/server-github']}}}
            canon.write_text(json.dumps(mcp_data), encoding='utf-8')

            inst_dir = root / 'inst1'
            inst_dir.mkdir(parents=True)
            inst_cfg = inst_dir / 'claude_desktop_config.json'
            inst_cfg.write_text(json.dumps({'preferences': {'theme': 'dark'}}), encoding='utf-8')

            cfg = {'instances': [{'id': 'inst1', 'name': 'Inst1', 'kind': '3p'}]}
            orig_read_config = cm.read_config
            orig_store_root = cm.store_root
            cm.read_config = lambda p=None: cfg
            cm.store_root = lambda i: inst_dir
            try:
                updated = cm.sync_mcp_servers(dry_run=False, canon_path=canon)
                self.assertEqual(updated, 1)

                loaded = json.loads(inst_cfg.read_text(encoding='utf-8'))
                self.assertIn('mcpServers', loaded)
                self.assertIn('github', loaded['mcpServers'])
                self.assertIn('preferences', loaded)  # Preserved other settings
            finally:
                cm.read_config = orig_read_config
                cm.store_root = orig_store_root

    def test_non_claude_url_rejected(self):
        """build_args must reject URLs that do not match claude:// schema."""
        inst = {'id': 'test-node'}
        with self.assertRaises(cm.ClaudeMultiError):
            cm.build_args(inst, url='https://malicious.example.com/exploit')

        # Valid claude:// URL must be accepted
        args = cm.build_args(inst, url='claude://open?token=abc')
        self.assertIn('claude://open?token=abc', args)

    def test_log_line_creates_directory_and_masks(self):
        """log_line must create ~/.claude-multi/logs and write masked log entries."""
        with tempfile.TemporaryDirectory() as td:
            orig_home = cm.HOME_ROOT
            orig_logs = cm.LOGS_DIR
            orig_log_file = cm.LOG_FILE
            try:
                cm.HOME_ROOT = Path(td)
                cm.LOGS_DIR = cm.HOME_ROOT / 'logs'
                cm.LOG_FILE = cm.LOGS_DIR / 'claude-multi.log'

                cm.log_line("Test message with token sk-ant-api03-0123456789abcdefghij")
                self.assertTrue(cm.LOG_FILE.exists())
                content = cm.LOG_FILE.read_text(encoding='utf-8')
                self.assertIn('sk-ant-***', content)
                self.assertNotIn('0123456789abcdefghij', content)
            finally:
                cm.HOME_ROOT = orig_home
                cm.LOGS_DIR = orig_logs
                cm.LOG_FILE = orig_log_file


if __name__ == '__main__':
    unittest.main()
