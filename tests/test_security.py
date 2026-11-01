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

    def test_windows_core_ps1_security_flags(self):
        """Verify Windows Core.ps1 also contains the WebRTC, DNS/QUIC anti-bypass, and shield.cjs fixes."""
        core_ps1_path = Path(__file__).resolve().parent.parent / 'src' / 'Core.ps1'
        content = core_ps1_path.read_text(encoding='utf-8')
        self.assertIn('--force-webrtc-ip-handling-policy', content)
        self.assertIn('--webrtc-ip-handling-policy=disable_non_proxied_udp', content)
        self.assertIn('--enforce-webrtc-ip-permission-check', content)
        self.assertIn('--host-resolver-rules=', content)
        self.assertIn('--disable-quic', content)
        self.assertIn('--dns-prefetch-disable', content)
        self.assertIn('--proxy-server=', content)
        self.assertIn('_networkQuarantined', content)
        self.assertIn('CLAUDE_MULTI_STARTUP_IP', content)

    def test_chromium_anti_bypass_flags_with_proxy(self):
        """Verify Chromium DNS/QUIC/WebRTC anti-bypass CLI flags are appended when proxy is configured."""
        inst = {'id': 'sec1', 'kind': '3p', 'proxy': 'http://127.0.0.1:7890'}
        args = cm.build_args(inst)
        self.assertIn('--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost , EXCLUDE ::1', args)
        self.assertIn('--disable-quic', args)
        self.assertIn('--dns-prefetch-disable', args)
        self.assertIn('--webrtc-ip-handling-policy=disable_non_proxied_udp', args)
        self.assertIn('--enforce-webrtc-ip-permission-check', args)

    def test_assert_profile_data_identity(self):
        """Verify profile identity anchor prevents cross-account profile contamination and rejects symlinks."""
        with tempfile.TemporaryDirectory() as td:
            udd = Path(td) / 'profile1'
            res1 = cm.assert_profile_data_identity(udd, 'acc-1')
            self.assertEqual(res1['instanceId'], 'acc-1')
            # Second call with matching instanceId succeeds
            res2 = cm.assert_profile_data_identity(udd, 'acc-1')
            self.assertEqual(res2['instanceId'], 'acc-1')
            # Call with mismatched instanceId raises ClaudeMultiError
            with self.assertRaises(cm.ClaudeMultiError):
                cm.assert_profile_data_identity(udd, 'acc-2')

            # Symlink rejection test
            target_file = Path(td) / 'outside.json'
            target_file.write_text('{"instanceId": "acc-3"}', encoding='utf-8')
            udd_sym = Path(td) / 'profile_sym'
            udd_sym.mkdir()
            ident_sym = udd_sym / '.profile-identity.json'
            try:
                ident_sym.symlink_to(target_file)
                symlink_supported = True
            except OSError:
                symlink_supported = False
            if symlink_supported:
                with self.assertRaises(cm.ClaudeMultiError):
                    cm.assert_profile_data_identity(udd_sym, 'acc-3')

    def test_ensure_profile_preferences(self):
        """Verify Default/Preferences pre-writes WebRTC policy, preserves existing keys, and cleans DevToolsActivePort."""
        import json
        with tempfile.TemporaryDirectory() as td:
            udd = Path(td) / 'prof'
            default_dir = udd / 'Default'
            default_dir.mkdir(parents=True)
            prefs_path = default_dir / 'Preferences'
            prefs_path.write_text(json.dumps({
                'custom_key': 'preserve_me',
                'webrtc': {'existing_subkey': 123},
            }), encoding='utf-8')
            devtools_port = udd / 'DevToolsActivePort'
            devtools_port.write_text('9222\n/devtools/browser/123', encoding='utf-8')

            cm.ensure_profile_preferences(udd, lang='ja-JP')
            self.assertFalse(devtools_port.exists())
            saved = json.loads(prefs_path.read_text(encoding='utf-8'))
            self.assertEqual(saved['custom_key'], 'preserve_me')
            self.assertEqual(saved['webrtc']['existing_subkey'], 123)
            self.assertEqual(saved['webrtc']['ip_handling_policy'], 'disable_non_proxied_udp')
            self.assertFalse(saved['webrtc']['multiple_routes_enabled'])
            self.assertFalse(saved['webrtc']['nonproxied_udp_enabled'])
            self.assertEqual(saved['intl']['accept_languages'], 'ja-JP')

    def test_verify_proxy_geo_consensus_and_drift_block(self):
        """Verify dual-source GeoIP consensus, COUNTRY_NETWORK_MAP alignment, and proxyExitPolicy == block."""
        import json
        with tempfile.TemporaryDirectory() as td:
            udd = Path(td) / 'inst_kr'
            inst = {'id': 'kr1', 'kind': '3p', 'proxy': 'http://127.0.0.1:7890', 'proxyExitPolicy': 'block'}

            def mock_fetch_ok(url, proxy=None):
                if 'ipwho.is' in url:
                    return json.dumps({'success': True, 'ip': '211.34.56.78', 'country_code': 'KR', 'timezone': {'id': 'Asia/Seoul'}})
                return json.dumps({'ip': '211.34.56.78', 'country_code': 'KR', 'timezone': 'Asia/Seoul'})

            rec = cm.verify_proxy_geo_consensus(inst, user_data_dir=udd, fetch=mock_fetch_ok)
            self.assertEqual(rec['verifiedIp'], '211.34.56.78')
            self.assertEqual(rec['countryCode'], 'KR')
            self.assertEqual(rec['timezone'], 'Asia/Seoul')
            self.assertEqual(rec['lang'], 'ko-KR')
            self.assertEqual(rec['geoConfidence'], 'high')
            self.assertEqual(inst['timezone'], 'Asia/Seoul')
            self.assertEqual(inst['lang'], 'ko-KR')
            self.assertTrue((udd / '.proxy-identity.json').exists())

            # Now simulate IP drift under proxyExitPolicy == 'block'
            def mock_fetch_drifted(url, proxy=None):
                return json.dumps({'success': True, 'ip': '198.51.100.99', 'country_code': 'KR', 'timezone': 'Asia/Seoul'})

            with self.assertRaises(cm.ClaudeMultiError):
                cm.verify_proxy_geo_consensus(inst, user_data_dir=udd, fetch=mock_fetch_drifted)

            # Changing the configured proxy URL resets the baseline proxyScope instead of false-positive drift blocking
            inst['proxy'] = 'http://127.0.0.1:7891'
            rec_new_scope = cm.verify_proxy_geo_consensus(inst, user_data_dir=udd, fetch=mock_fetch_drifted)
            self.assertEqual(rec_new_scope['verifiedIp'], '198.51.100.99')
            self.assertFalse(rec_new_scope['ipDrifted'])

            # Simulate GeoIP country conflict under proxyExitPolicy == 'block'
            udd2 = Path(td) / 'inst_conflict'
            inst2 = {'id': 'cf1', 'kind': '3p', 'proxy': 'http://127.0.0.1:7890', 'proxyExitPolicy': 'block'}

            def mock_fetch_conflict(url, proxy=None):
                if 'ipwho.is' in url:
                    return json.dumps({'success': True, 'ip': '203.0.113.5', 'country_code': 'US', 'timezone': 'America/New_York'})
                return json.dumps({'ip': '203.0.113.5', 'country_code': 'SG', 'timezone': 'Asia/Singapore'})

            with self.assertRaises(cm.ClaudeMultiError):
                cm.verify_proxy_geo_consensus(inst2, user_data_dir=udd2, fetch=mock_fetch_conflict)

    def test_shield_cjs_quarantine_logic(self):
        """Verify generated shield.cjs contains runtime quarantine circuit breaker and env wiring."""
        with tempfile.TemporaryDirectory() as td:
            shield_path = cm.ensure_shield_script(td)
            self.assertTrue(shield_path.exists())
            code = shield_path.read_text(encoding='utf-8')
            self.assertIn('let _networkQuarantined = false;', code)
            self.assertIn('let _quarantineReason =', code)
            self.assertIn('CLAUDE_MULTI_STARTUP_IP', code)
            self.assertIn('CLAUDE_MULTI_EXIT_POLICY', code)
            self.assertIn('CLAUDE_MULTI_MONITOR_INTERVAL_MS', code)
            self.assertIn('[Claude-Multi Shield] Network quarantined due to proxy exit drift:', code)
            self.assertIn('.proxy-quarantine.log', code)

            inst = {'id': 's1', 'kind': '3p', 'proxy': 'http://127.0.0.1:7890'}
            env = cm.build_env(inst, base={}, shield_path=shield_path, startup_ip='203.0.113.10')
            self.assertEqual(env['CLAUDE_MULTI_STARTUP_IP'], '203.0.113.10')
            self.assertEqual(env['CLAUDE_MULTI_EXIT_POLICY'], 'block')
            self.assertIn(f'--require "{shield_path}"', env['NODE_OPTIONS'])


if __name__ == '__main__':
    unittest.main()
