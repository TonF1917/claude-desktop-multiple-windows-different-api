import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add macos directory to sys.path
MACOS_DIR = Path(__file__).resolve().parent.parent / 'macos'
sys.path.insert(0, str(MACOS_DIR))

import claude_multi as cm


class TestSecurity(unittest.TestCase):

    def test_proxy_bypass_unconditional(self):
        """Proxy must be unconditionally appended to args even without proxyServerFlag."""
        inst = {'id': 'test-node', 'proxy': 'http://127.0.0.1:7890'}
        args = cm.build_args(inst)
        self.assertIn('--proxy-server=http://127.0.0.1:7890', args)

    def test_proxy_credential_stripping(self):
        """Embedded user:pass credentials must be stripped before passing to Chromium CLI."""
        inst = {'id': 'test-node', 'proxy': 'http://myuser:mypassword@proxy.corp.internal:8080'}
        args = cm.build_args(inst)
        self.assertIn('--proxy-server=http://proxy.corp.internal:8080', args)
        # Ensure raw credentials do not leak in command line arguments
        for arg in args:
            self.assertNotIn('myuser', arg)
            self.assertNotIn('mypassword', arg)

    def test_keychain_safestorage_isolation(self):
        """Mock keychain and basic password store must be enforced to isolate macOS Keychain storage."""
        inst = {'id': 'inst-1'}
        args = cm.build_args(inst)
        self.assertIn('--use-mock-keychain', args)
        self.assertIn('--password-store=basic', args)

    def test_webrtc_udp_enforcement(self):
        """Both force-webrtc-ip-handling-policy and disable_non_proxied_udp must be passed to stop WebRTC leaks."""
        inst = {'id': 'inst-2'}
        args = cm.build_args(inst)
        self.assertIn('--force-webrtc-ip-handling-policy', args)
        self.assertIn('--webrtc-ip-handling-policy=disable_non_proxied_udp', args)

    def test_mask_secrets(self):
        """Sensitive credentials and tokens must be masked in string outputs and logs."""
        raw = "Error connecting to http://alice:secretPass123@127.0.0.1:8080 with token sk-ant-api03-1234567890abcdef and ghp_0123456789abcdefghij"
        masked = cm.mask_secrets(raw)
        self.assertNotIn('secretPass123', masked)
        self.assertNotIn('1234567890abcdef', masked)
        self.assertNotIn('0123456789abcdefghij', masked)
        self.assertIn('sk-ant-***', masked)
        self.assertIn('ghp_***', masked)

    def test_proxy_credential_warning_in_check(self):
        """check_instance must raise a warning if embedded credentials are present in the proxy URL."""
        inst = {'id': 'auth-inst', 'name': 'Auth', 'proxy': 'http://alice:secret@127.0.0.1:7890'}
        res = cm.check_instance(inst, fetch=lambda u, p: {})
        self.assertIsNotNone(res.get('warning'))
        self.assertIn('Chromium `--proxy-server` does not accept embedded credentials', res['warning'])

    def test_symlink_traversal_prevention_in_sync_sessions(self):
        """sync_sessions must skip symlinks to prevent symlink traversal attacks."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            inst1_dir = root / 'inst1' / 'claude-code-sessions' / 'acc1' / 'org1'
            inst2_dir = root / 'inst2' / 'claude-code-sessions' / 'acc1' / 'org1'
            inst1_dir.mkdir(parents=True)
            inst2_dir.mkdir(parents=True)

            secret_file = root / 'secret.txt'
            secret_file.write_text('topsecret', encoding='utf-8')

            # Real session file in inst1
            real_file = inst1_dir / 'local_real.json'
            real_file.write_text('{"real": true}', encoding='utf-8')

            # Symlink in inst1 pointing to secret
            symlink_file = inst1_dir / 'local_symlink.json'
            try:
                symlink_file.symlink_to(secret_file)
            except (OSError, NotImplementedError):
                # On Windows without developer mode/admin rights, symlink creation may require privilege
                return

            cfg = {
                'instances': [
                    {'id': 'inst1', 'name': 'One'},
                    {'id': 'inst2', 'name': 'Two'}
                ]
            }

            # Monkey-patch store_root for the test
            orig_store_root = cm.store_root
            cm.store_root = lambda i: root / i['id']
            try:
                copied = cm.sync_sessions(cfg, {})
                # real_file should be copied, symlink should NOT be copied
                self.assertTrue((inst2_dir / 'local_real.json').exists())
                self.assertFalse((inst2_dir / 'local_symlink.json').exists())
            finally:
                cm.store_root = orig_store_root


if __name__ == '__main__':
    unittest.main()
