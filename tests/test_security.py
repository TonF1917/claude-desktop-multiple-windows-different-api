import hashlib
import json
import os
import shutil
import struct
import subprocess
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

    @staticmethod
    def _build_synthetic_asar(asar_path: Path, index_html_text: str, app_js_text: str = 'console.log("app");\n') -> bytes:
        app_bytes = app_js_text.encode('utf-8')
        html_bytes = index_html_text.encode('utf-8')
        block_size = 4 * 1024 * 1024

        def _integrity(data: bytes) -> dict:
            return {
                'algorithm': 'SHA256',
                'hash': hashlib.sha256(data).hexdigest(),
                'blockSize': block_size,
                'blocks': [
                    hashlib.sha256(data[pos:pos + block_size]).hexdigest()
                    for pos in range(0, len(data), block_size)
                ],
            }

        header_obj = {
            'files': {
                'assets': {
                    'files': {
                        'app.js': {
                            'size': len(app_bytes),
                            'offset': '0',
                            'integrity': _integrity(app_bytes),
                        }
                    }
                },
                'index.html': {
                    'size': len(html_bytes),
                    'offset': str(len(app_bytes)),
                    'integrity': _integrity(html_bytes),
                },
            }
        }
        json_bytes = json.dumps(header_obj, separators=(',', ':')).encode('utf-8')
        jlen = len(json_bytes)
        aligned_jlen = (jlen + 3) & ~3
        pad_len = aligned_jlen - jlen
        u1 = aligned_jlen + 8
        u2 = aligned_jlen + 4
        hdr = struct.pack('<IIII', 4, u1, u2, jlen)
        payload = app_bytes + html_bytes
        asar_path.write_bytes(hdr + json_bytes + (b'\x00' * pad_len) + payload)
        return app_bytes

    def _parse_and_verify_asar(self, asar_path: Path):
        raw = asar_path.read_bytes()
        self.assertGreaterEqual(len(raw), 16)
        u0, u1, u2, jlen = struct.unpack('<IIII', raw[:16])
        self.assertEqual(u0, 4)
        aligned_jlen = (jlen + 3) & ~3
        self.assertEqual(u2, aligned_jlen + 4)
        self.assertEqual(u1, aligned_jlen + 8)
        data_start = 8 + u1
        self.assertEqual(data_start, 16 + aligned_jlen)
        json_bytes = raw[16:16 + jlen]
        self.assertFalse(json_bytes.startswith(b'\xef\xbb\xbf'), 'JSON header must not have UTF-8 BOM')
        header = json.loads(json_bytes.decode('utf-8'))
        payload = raw[data_start:]
        return header, payload

    def test_patch_asar_index_html_font_python(self):
        """Python ASAR patcher must append patched index.html, preserve existing offsets, update SHA256 integrity, and be idempotent."""
        orig_html = (
            '<!doctype html><html lang="en-US"><head><meta charset="utf-8">'
            '<title>Claude</title></head><body><div id="root"></div></body></html>'
        )
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            src_asar = td_path / 'ion-dist.asar'
            dst_asar = td_path / 'out' / 'ion-dist.asar'
            app_bytes = self._build_synthetic_asar(src_asar, orig_html)

            res = cm.patch_asar_index_html_font(src_asar, dst_asar, 'anthropic-serif')
            self.assertEqual(res, dst_asar)
            self.assertTrue(dst_asar.is_file())

            header, payload = self._parse_and_verify_asar(dst_asar)
            app_entry = header['files']['assets']['files']['app.js']
            self.assertEqual(app_entry['offset'], '0')
            self.assertEqual(app_entry['size'], len(app_bytes))
            self.assertEqual(payload[:len(app_bytes)], app_bytes)

            idx_entry = header['files']['index.html']
            idx_offset = int(idx_entry['offset'])
            idx_size = int(idx_entry['size'])
            patched_html_bytes = payload[idx_offset:idx_offset + idx_size]
            self.assertFalse(patched_html_bytes.startswith(b'\xef\xbb\xbf'))
            patched_html = patched_html_bytes.decode('utf-8')

            self.assertIn('id="claude-multi-chat-font"', patched_html)
            self.assertIn('id="claude-multi-chat-font-sync"', patched_html)
            self.assertIn('--font-claude-response: var(--font-anthropic-serif', patched_html)
            self.assertIn('--font-cjk-serif-lead-sc: "Noto Serif SC"', patched_html)
            self.assertLess(patched_html.index('id="claude-multi-chat-font"'), patched_html.lower().index('</head>'))

            expected_hash = hashlib.sha256(patched_html_bytes).hexdigest()
            self.assertEqual(idx_entry['integrity']['algorithm'], 'SHA256')
            self.assertEqual(idx_entry['integrity']['blockSize'], 4194304)
            self.assertEqual(idx_entry['integrity']['hash'], expected_hash)
            self.assertEqual(idx_entry['integrity']['blocks'], [expected_hash])

            # Second pass must be strictly idempotent (including archive byte length)
            dst_asar_2 = td_path / 'out' / 'ion-dist-2.asar'
            cm.patch_asar_index_html_font(dst_asar, dst_asar_2, 'anthropic-serif')
            header2, payload2 = self._parse_and_verify_asar(dst_asar_2)
            idx_entry2 = header2['files']['index.html']
            patched_html_2 = payload2[
                int(idx_entry2['offset']):int(idx_entry2['offset']) + int(idx_entry2['size'])
            ].decode('utf-8')
            self.assertEqual(patched_html_2.count('id="claude-multi-chat-font"'), 1)
            self.assertEqual(patched_html_2.count('id="claude-multi-chat-font-sync"'), 1)
            self.assertEqual(patched_html_2, patched_html)
            self.assertEqual(len(payload2), len(payload))

    def test_patch_asar_rejects_symlink(self):
        """Symlinked source ASAR must be rejected to prevent symlink traversal attacks."""
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            real_asar = td_path / 'real.asar'
            self._build_synthetic_asar(real_asar, '<html><head></head><body></body></html>')
            link_asar = td_path / 'link.asar'
            try:
                link_asar.symlink_to(real_asar)
            except OSError as exc:
                self.skipTest(f'Symlink creation not permitted in this environment: {exc}')

            with self.assertRaises((ValueError, RuntimeError)):
                cm.patch_asar_index_html_font(link_asar, td_path / 'out.asar', 'anthropic-serif')

    def test_build_env_chat_font_cleanup_and_set(self):
        """CLAUDE_MULTI_CHAT_FONT must be stripped from inherited env and populated when chatFont is configured."""
        base = {'CLAUDE_MULTI_CHAT_FONT': 'stale-font', 'PATH': '/usr/bin'}
        inst_unset = {'id': 'official', 'name': 'Claude Official', 'primary': True}
        env_unset = cm.build_env(inst_unset, base=base)
        self.assertNotIn('CLAUDE_MULTI_CHAT_FONT', env_unset)

        inst_serif = {'id': '3p', 'name': 'Claude 3P', 'chatFont': '  Anthropic-Serif '}
        env_serif = cm.build_env(inst_serif, base=base)
        self.assertEqual(env_serif['CLAUDE_MULTI_CHAT_FONT'], 'anthropic-serif')

    @unittest.skipIf(shutil.which('powershell.exe') is None, 'powershell.exe not available')
    def test_powershell_asar_font_patch_parity(self):
        """PowerShell Update-AsarIndexHtmlFontPatch and Ensure-PatchedClaudeRuntime must produce byte-accurate ASARs and valid cache manifests."""
        orig_html = (
            '<!doctype html><html lang="en-US"><head><meta charset="utf-8">'
            '<title>Claude</title></head><body><div id="root"></div></body></html>'
        )
        core_ps1 = Path(__file__).resolve().parent.parent / 'src' / 'Core.ps1'
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            pkg_dir = td_path / 'AnthropicPBC.Claude_1.3455.0.0_x64__pzs8sxrjxfjjc'
            app_dir = pkg_dir / 'app'
            res_dir = app_dir / 'resources'
            res_dir.mkdir(parents=True)
            fake_exe = app_dir / 'Claude.exe'
            fake_exe.write_bytes(b'MZ-fake-claude-exe')
            src_asar = res_dir / 'ion-dist.asar'
            app_bytes = self._build_synthetic_asar(src_asar, orig_html)

            dst_asar = td_path / 'ps-out.asar'
            dst_asar_2 = td_path / 'ps-out-2.asar'
            home_root = td_path / 'home-multi'

            ps_cmd = (
                f". '{core_ps1}'; "
                f"$script:HomeRoot = '{home_root}'; "
                f"Update-AsarIndexHtmlFontPatch -SourceAsar '{src_asar}' -DestAsar '{dst_asar}' -ChatFont 'anthropic-serif' | Out-Null; "
                f"Update-AsarIndexHtmlFontPatch -SourceAsar '{dst_asar}' -DestAsar '{dst_asar_2}' -ChatFont 'anthropic-serif' | Out-Null; "
                f"$rtExe = Ensure-PatchedClaudeRuntime -SourceExe '{fake_exe}' -ChatFont 'anthropic-serif'; "
                f"Write-Output ('RT_EXE=' + $rtExe)"
            )
            proc = subprocess.run(
                ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', ps_cmd],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(proc.returncode, 0, f'PowerShell failed: {proc.stderr}\n{proc.stdout}')
            self.assertTrue(dst_asar.is_file())
            self.assertTrue(dst_asar_2.is_file())

            header, payload = self._parse_and_verify_asar(dst_asar)
            app_entry = header['files']['assets']['files']['app.js']
            self.assertEqual(app_entry['offset'], '0')
            self.assertEqual(app_entry['size'], len(app_bytes))
            self.assertEqual(payload[:len(app_bytes)], app_bytes)

            idx_entry = header['files']['index.html']
            idx_offset = int(idx_entry['offset'])
            idx_size = int(idx_entry['size'])
            patched_bytes = payload[idx_offset:idx_offset + idx_size]
            self.assertFalse(patched_bytes.startswith(b'\xef\xbb\xbf'))
            patched_html = patched_bytes.decode('utf-8')

            self.assertEqual(patched_html.count('id="claude-multi-chat-font"'), 1)
            self.assertEqual(patched_html.count('id="claude-multi-chat-font-sync"'), 1)
            self.assertIn('--font-claude-response: var(--font-anthropic-serif', patched_html)
            self.assertIn('--font-cjk-serif-lead-sc: "Noto Serif SC"', patched_html)

            expected_hash = hashlib.sha256(patched_bytes).hexdigest()
            self.assertEqual(idx_entry['integrity']['algorithm'], 'SHA256')
            self.assertEqual(idx_entry['integrity']['blockSize'], 4194304)
            self.assertEqual(idx_entry['integrity']['hash'], expected_hash)
            self.assertEqual(idx_entry['integrity']['blocks'], [expected_hash])

            header2, payload2 = self._parse_and_verify_asar(dst_asar_2)
            idx_entry2 = header2['files']['index.html']
            patched_bytes_2 = payload2[int(idx_entry2['offset']):int(idx_entry2['offset']) + int(idx_entry2['size'])]
            self.assertEqual(patched_bytes_2, patched_bytes)

            # Verify Ensure-PatchedClaudeRuntime output and .patch-manifest.json
            rt_pkg_dir = home_root / 'runtime' / 'AnthropicPBC.Claude_1.3455.0.0_x64__pzs8sxrjxfjjc_anthropic-serif'
            rt_exe = rt_pkg_dir / 'app' / 'Claude.exe'
            rt_ion = rt_pkg_dir / 'app' / 'resources' / 'ion-dist.asar'
            manifest_path = rt_pkg_dir / '.patch-manifest.json'
            self.assertIn(f'RT_EXE={rt_exe}', proc.stdout)
            self.assertTrue(rt_exe.is_file())
            self.assertTrue(rt_ion.is_file())
            self.assertTrue(manifest_path.is_file())
            manifest_raw = manifest_path.read_bytes()
            self.assertFalse(manifest_raw.startswith(b'\xef\xbb\xbf'))
            manifest = json.loads(manifest_raw.decode('utf-8'))
            self.assertEqual(manifest['schemaVersion'], 'v1')
            self.assertEqual(manifest['pkgName'], 'AnthropicPBC.Claude_1.3455.0.0_x64__pzs8sxrjxfjjc')
            self.assertEqual(manifest['ionSize'], src_asar.stat().st_size)
            self.assertEqual(manifest['chatFont'], 'anthropic-serif')


if __name__ == '__main__':
    unittest.main()
