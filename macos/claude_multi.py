#!/usr/bin/env python3
"""Claude Desktop: multiple windows with different APIs - macOS port (EXPERIMENTAL, feature parity with the Windows tool).

Written without access to a Mac: the portable parts (config, palettes, proxy/timezone/launch planning, icon recolouring, cc-switch
profiles, session mirroring, egress check, GUI) are exercised on Windows; the macOS-only parts (bundle cloning, codesign, sips/iconutil,
executing the cloned binary) follow the documented behaviour of those tools but have NOT been run on real hardware.
Needs only Python 3 (standard library only).

    python3 macos/claude_multi.py gui
    python3 macos/claude_multi.py add --id off2 --kind official --palette perplexity --proxy http://127.0.0.1:7890 --timezone America/Toronto
    python3 macos/claude_multi.py add --id gem --name "Claude Gemini" --palette gemini [--provider <cc-switch id>]
    python3 macos/claude_multi.py init [--id gem]     # provision data dir, MCP config link, session link, tinted Claude.app clone
    python3 macos/claude_multi.py check [--id off2]   # egress IP / residential-or-datacenter / risk / timezone alignment
    python3 macos/claude_multi.py launch --id gem     # also: stop, restart, list, remove, uninstall, agent, sync, providers
"""
import argparse, binascii, colorsys, json, os, plistlib, re, shutil, signal, sqlite3, struct, subprocess, sys, time, zlib
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = Path(os.environ.get('CLAUDE_MULTI_CONFIG') or ROOT / 'instances.json')
PALETTES = ROOT / 'palettes.json'
HOME = Path(os.environ.get('CLAUDE_MULTI_HOME') or Path.home())
HOME_ROOT = HOME / '.claude-multi'
APP_SUP = HOME / 'Library' / 'Application Support'
IS_MAC = sys.platform == 'darwin'
APP_CANDIDATES = [Path('/Applications/Claude.app'), HOME / 'Applications' / 'Claude.app']
SRC_3P = APP_SUP / 'Claude-3p'            # where Claude (and cc-switch) keep the shared 3P config library
CLONES = HOME / 'Applications' / 'Claude Multi'
SESSION_DIRS = ('claude-code-sessions', 'local-agent-mode-sessions')
PROXY_VARS = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
SUPPORTED_CC = ('US', 'CA', 'GB', 'ID', 'JP', 'SG', 'DE', 'FR', 'AU')       # same list as the Windows `check`
COMMON_TIMEZONES = ['America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles', 'America/Toronto', 'America/Vancouver',
                    'America/Mexico_City', 'America/Sao_Paulo', 'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Madrid',
                    'Europe/Moscow', 'Asia/Jakarta', 'Asia/Singapore', 'Asia/Tokyo', 'Asia/Seoul', 'Asia/Shanghai', 'Asia/Hong_Kong',
                    'Asia/Kolkata', 'Asia/Dubai', 'Australia/Sydney', 'Pacific/Auckland', 'UTC']
try:
    VERSION = (Path(__file__).resolve().parent / 'VERSION').read_text().strip() or '1.1.0'
except OSError:
    VERSION = '1.1.0'


class ClaudeMultiError(Exception):
    """A user-facing failure (printed as `error: ...`, never a traceback)."""


# ------------------------------------------------------------------ secrets hygiene
def mask_secrets(text):
    """Hide `user:pass@` in anything that looks like a URL. Use on every string that is printed or logged."""
    return re.sub(r'(://)[^/\s]*@', r'\1***@', str(text))   # greedy: up to the LAST '@', so a password containing '@' is hidden entirely

def mask_proxy(url):
    return mask_secrets(url) if url else ''

def normalize_proxy(value):
    """'' -> None; 'host:port' -> 'http://host:port'; validates scheme/host/port. Error messages never echo credentials."""
    v = (value or '').strip()
    if not v:
        return None
    if '://' not in v:
        v = 'http://' + v
    try:
        u = urllib.parse.urlsplit(v); host = u.hostname; port = u.port
    except ValueError:
        raise ClaudeMultiError('invalid proxy URL (expected http://[user:pass@]host:port)') from None
    if u.scheme not in ('http', 'https', 'socks', 'socks4', 'socks5', 'socks5h') or not host:
        raise ClaudeMultiError(f'invalid proxy URL {mask_secrets(v)!r} (expected http://[user:pass@]host:port)')
    if port is None and u.scheme.startswith('http'):
        raise ClaudeMultiError('proxy URL needs a port')
    return v

def validate_timezone(value):
    v = (value or '').strip()
    if not v:
        return None
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+){0,2}', v):
        raise ClaudeMultiError(f"invalid timezone '{v}' (use an IANA name such as America/Toronto)")
    zi = Path('/usr/share/zoneinfo')
    if zi.is_dir() and not (zi / v).exists():
        raise ClaudeMultiError(f"unknown timezone '{v}' (not in /usr/share/zoneinfo)")
    return v

_LANGS = {'America/Toronto': 'en-CA', 'America/Vancouver': 'en-CA', 'America/Mexico_City': 'es-MX', 'America/Sao_Paulo': 'pt-BR',
          'Europe/London': 'en-GB', 'Europe/Paris': 'fr-FR', 'Europe/Berlin': 'de-DE', 'Europe/Madrid': 'es-ES', 'Europe/Moscow': 'ru-RU',
          'Asia/Jakarta': 'id-ID', 'Asia/Singapore': 'en-SG', 'Asia/Tokyo': 'ja-JP', 'Asia/Seoul': 'ko-KR', 'Asia/Shanghai': 'zh-CN',
          'Asia/Hong_Kong': 'zh-HK', 'Asia/Kolkata': 'en-IN', 'Asia/Dubai': 'en-AE', 'Pacific/Auckland': 'en-NZ'}

def lang_for(i):
    """Chromium --lang for an instance: explicit `lang`, else derived from its timezone, else None (leave the app's default)."""
    if i.get('lang'):
        return i['lang']
    tz = i.get('timezone')
    if not tz:
        return None
    return _LANGS.get(tz) or ('en-AU' if tz.startswith('Australia/') else 'en-US')


# ------------------------------------------------------------------ config
def default_config():
    return {'instances': [dict(id='official', name='Claude', kind='official', palette='official'),
                          dict(id='3p', name='Claude 3P', kind='cc-switch', palette='violet')], 'settings': {}}

def read_config():
    try:
        c = json.loads(CONFIG.read_text(encoding='utf-8-sig')) if CONFIG.exists() else default_config()
    except (OSError, ValueError) as e:
        raise ClaudeMultiError(f'cannot read {CONFIG}: {e}') from None
    c.setdefault('instances', [])
    s = c.setdefault('settings', {})
    for k, v in (('syncSessions', True), ('liveRefresh', True), ('refreshOfficial', False), ('language', 'en'), ('protocol', 'last')):
        s.setdefault(k, v)
    for i in c['instances']:
        if not isinstance(i, dict) or not re.fullmatch(r'[A-Za-z0-9_-]+', str(i.get('id', ''))):
            raise ClaudeMultiError(f"invalid instance id {str(i.get('id') if isinstance(i, dict) else i)[:40]!r} in {CONFIG.name} (letters, digits, - _ only)")
        i.setdefault('kind', 'cc-switch'); i.setdefault('name', f"Claude {i.get('id', '')}"); i.setdefault('palette', 'violet')
    return c

def save_config(c):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG.with_name(CONFIG.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)      # may hold proxy credentials: owner-only on POSIX
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(json.dumps(c, indent=2, ensure_ascii=False) + '\n')
    if os.name == 'posix':
        os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG)

def palettes():
    try:
        return json.loads(PALETTES.read_text(encoding='utf-8-sig'))
    except (OSError, ValueError) as e:
        raise ClaudeMultiError(f'cannot read {PALETTES}: {e}') from None

def get_instance(c, iid):
    for i in c['instances']:
        if i['id'] == iid:
            return i
    raise ClaudeMultiError(f"no instance '{iid}' in {CONFIG.name}")

def is_official(i):
    return i.get('kind') == 'official'

def is_primary(i):                        # the one official window that uses the stock Claude.app and stock data directory
    return is_official(i) and i.get('id') == 'official'

def data_dir(i):                          # --user-data-dir of a window ("<dir>-3p" is derived from it by the app in 3P mode)
    return APP_SUP / 'Claude' if is_primary(i) else HOME_ROOT / i['id'] / 'Claude'

def store_root(i):                        # where the window really keeps its data (config library, claude-code-sessions, MCP config)
    return HOME_ROOT / i['id'] / 'Claude-3p' if not is_official(i) else data_dir(i)

def official_app():
    for p in APP_CANDIDATES:
        if (p / 'Contents' / 'Info.plist').exists():
            return p
    raise ClaudeMultiError('Claude.app not found in /Applications or ~/Applications - install Claude Desktop first')

def clone_path(i):
    return CLONES / ((re.sub(r'[/:\x00]', '-', i['name']).strip() or i['id']) + '.app')

def make_instance(c, id_, name=None, kind='3p', palette='violet', provider=None, profile=None, proxy=None, timezone=None, lang=None):
    """Validate and build a new instance dict (shared by the CLI and the GUI). Windows stores third-party windows as kind 'cc-switch'."""
    if not id_ or not re.fullmatch(r'[A-Za-z0-9_-]+', id_):
        raise ClaudeMultiError('id is required (letters, digits, - _)')
    if any(x['id'] == id_ for x in c['instances']):
        raise ClaudeMultiError(f"instance '{id_}' already exists")
    if kind not in ('official', '3p', 'cc-switch'):
        raise ClaudeMultiError("kind must be 'official' or '3p'")
    resolve_palette(palette or 'violet', palettes()) if palette != 'official' else None
    n = dict(id=id_, name=name or f'Claude {id_}', kind='official' if kind == 'official' else 'cc-switch', palette=palette or 'violet')
    if provider: n['provider'] = provider
    if profile: n['profile'] = profile
    if normalize_proxy(proxy): n['proxy'] = normalize_proxy(proxy)
    if validate_timezone(timezone): n['timezone'] = validate_timezone(timezone)
    if lang: n['lang'] = lang
    return n


# ------------------------------------------------------------------ PNG + palette recolouring (pure Python)
def read_png(path):
    d = Path(path).read_bytes()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos, idat, w = 8, b'', 0
    while pos < len(d):
        ln, typ = struct.unpack('>I4s', d[pos:pos + 8]); body = d[pos + 8:pos + 8 + ln]; pos += 12 + ln
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and ctype in (2, 6) and inter == 0, 'only 8-bit RGB/RGBA non-interlaced PNG is supported'
        elif typ == b'IDAT':
            idat += body
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp; out = bytearray(); prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    if bpp == 3:                           # promote RGB to RGBA
        rgba = bytearray()
        for k in range(0, len(out), 3):
            rgba += out[k:k + 3] + b'\xff'
        out = rgba
    return w, h, out

def write_png(path, w, h, rgba):
    raw = b''.join(b'\x00' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', binascii.crc32(t + b) & 0xffffffff)
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))

def resolve_palette(spec, pal):
    m = re.fullmatch(r'#?([0-9a-fA-F]{6})', spec or '')
    if m:                                  # any #RRGGBB
        r, g, b = (int(m.group(1)[k:k + 2], 16) / 255 for k in (0, 2, 4)); h, s, v = colorsys.rgb_to_hsv(r, g, b)
        return dict(hue=h * 360, sat=max(.35, s), vMin=.15 * v, vMax=max(.35, v), glyph='#FFFFFF')
    if spec not in pal:
        raise ClaudeMultiError(f"unknown palette '{spec}' (use a name from palettes.json or #RRGGBB)")
    return pal[spec]

def recolor(w, h, rgba, p):
    gl = tuple(int(p['glyph'].lstrip('#')[k:k + 2], 16) for k in (0, 2, 4)); out = bytearray(len(rgba))
    for k in range(0, len(rgba), 4):
        r, g, b, a = rgba[k:k + 4]
        if a == 0:
            continue
        mx, mn = max(r, g, b), min(r, g, b); val = mx / 255; sat = 0 if mx == 0 else (mx - mn) / mx
        t = min(1, max(0, (sat - .20) / .25))                       # 1 = coloured body, 0 = white glyph
        v = min(p['vMax'], max(p['vMin'], p['vMin'] + (p['vMax'] - p['vMin']) * ((val - .75) / .2)))
        rr, gg, bb = colorsys.hsv_to_rgb((p['hue'] % 360) / 360, p['sat'], v)
        out[k:k + 4] = bytes((int(gl[0] + (rr * 255 - gl[0]) * t), int(gl[1] + (gg * 255 - gl[1]) * t), int(gl[2] + (bb * 255 - gl[2]) * t), a))
    return out


# ------------------------------------------------------------------ cc-switch: providers and direct profiles
def cc_providers():
    db = HOME / '.cc-switch' / 'cc-switch.db'
    if not db.exists():
        return []
    try:
        con = sqlite3.connect(f'file:{db.as_posix()}?mode=ro', uri=True)
        try:
            rows = con.execute("select id,name,is_current,settings_config,meta from providers where app_type='claude-desktop'").fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return []
    out = []
    for pid, name, cur, sc, meta in rows:
        if pid == 'claude-desktop-official':
            continue
        out.append(dict(id=pid, name=name, current=bool(cur), settings=json.loads(sc or '{}'), meta=json.loads(meta or '{}')))
    return out

def direct_profile(provider_id):
    p = next((x for x in cc_providers() if x['id'] == provider_id), None)
    if not p:
        raise ClaudeMultiError(f"cc-switch provider '{provider_id}' not found")
    fmt = p['meta'].get('apiFormat')
    if fmt and fmt != 'anthropic':
        raise ClaudeMultiError(f"provider '{p['name']}' speaks '{fmt}'; it needs the cc-switch gateway (use 'follow')")
    env = p['settings'].get('env', {}); url = env.get('ANTHROPIC_BASE_URL'); key = env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY')
    if not url or not key:
        raise ClaudeMultiError(f"provider '{p['name']}' has no base URL / key")
    models = [dict(name=r.get('model') or k, labelOverride=r.get('labelOverride') or k, supports1m=True)
              for k, r in (p['meta'].get('claudeDesktopModelRoutes') or {}).items()]
    return dict(inferenceStreamIdleTimeoutSec=1800, defaultModelEffort='medium', inferenceModelPricingEnabled=True, coworkEgressAllowedHosts=['*'],
                disableDeploymentModeChooser=True, inferenceCredentialKind='static', inferenceGatewayApiKey=key, inferenceGatewayAuthScheme='bearer',
                inferenceGatewayBaseUrl=re.sub(r'/v1$', '', url.rstrip('/')), inferenceProvider='gateway', inferenceModels=models)

def _clear_dir(d):
    for old in d.iterdir():
        if old.is_dir() and not old.is_symlink():
            shutil.rmtree(old)
        else:
            old.unlink()

def sync_profile(i):
    """Give a third-party window its own config library; returns the profile's timestamp (restart a running window when it is newer)."""
    dst = store_root(i) / 'configLibrary'
    uid = '00000000-0000-4000-8000-0000000000%02d' % (binascii.crc32(i['id'].encode()) % 100)
    dst.mkdir(parents=True, exist_ok=True)
    if i.get('provider') or i.get('profile'):
        if i.get('profile'):
            try:
                prof = json.loads(Path(os.path.expandvars(i['profile'])).read_text(encoding='utf-8-sig'))
            except (OSError, ValueError) as e:
                raise ClaudeMultiError(f"cannot read profile '{i['profile']}': {e}") from None
        else:
            prof = direct_profile(i['provider'])
        text = json.dumps(prof, indent=2)
        f = dst / f'{uid}.json'
        if not (f.exists() and f.read_text(encoding='utf-8') == text):
            _clear_dir(dst)
            f.write_text(text, encoding='utf-8')
            (dst / '_meta.json').write_text(json.dumps(dict(entries=[dict(id=uid, name=i['name'])], appliedId=uid)), encoding='utf-8')
        return f.stat().st_mtime
    src = SRC_3P / 'configLibrary'                          # follow cc-switch's current selection
    if not src.exists():
        return 0.0
    _clear_dir(dst)
    for f in src.iterdir():
        if f.is_file():
            shutil.copy2(f, dst / f.name)
    return max((f.stat().st_mtime for f in src.iterdir()), default=0.0)


# ------------------------------------------------------------------ subprocess helper
def sh(*a, check=True):
    try:
        r = subprocess.run(a, capture_output=True, text=True)
    except OSError as e:
        if check:
            raise ClaudeMultiError(f"cannot run '{a[0]}': {e.strerror or e}") from None
        return subprocess.CompletedProcess(a, 127, '', str(e))
    if check and r.returncode != 0:
        raise ClaudeMultiError(f"'{a[0]}' failed ({r.returncode}): {mask_secrets((r.stderr or r.stdout).strip())[:400]}")
    return r


# ------------------------------------------------------------------ macOS: tinted Claude.app clones
def app_version(app):
    try:
        return plistlib.loads((app / 'Contents' / 'Info.plist').read_bytes()).get('CFBundleShortVersionString', '?')
    except (OSError, plistlib.InvalidFileException, ValueError) as e:
        raise ClaudeMultiError(f'cannot read {app}/Contents/Info.plist: {e}') from None

def build_icns(icns_in, palette_spec, out_icns, tmp):
    tmp.mkdir(parents=True, exist_ok=True)
    base = tmp / 'base.png'
    sh('sips', '-s', 'format', 'png', str(icns_in), '--out', str(base))
    w, h, px = read_png(base)
    write_png(tmp / 'tint.png', w, h, recolor(w, h, px, resolve_palette(palette_spec, palettes())))
    iconset = tmp / 'icon.iconset'; iconset.mkdir(exist_ok=True)
    for s, name in ((16, 'icon_16x16'), (32, 'icon_16x16@2x'), (32, 'icon_32x32'), (64, 'icon_32x32@2x'), (128, 'icon_128x128'), (256, 'icon_128x128@2x'),
                    (256, 'icon_256x256'), (512, 'icon_256x256@2x'), (512, 'icon_512x512'), (1024, 'icon_512x512@2x')):
        sh('sips', '-z', str(s), str(s), str(tmp / 'tint.png'), '--out', str(iconset / f'{name}.png'))
    sh('iconutil', '-c', 'icns', str(iconset), '-o', str(out_icns))

def clone_binary(app):
    info = plistlib.loads((app / 'Contents' / 'Info.plist').read_bytes())
    exe = app / 'Contents' / 'MacOS' / info.get('CFBundleExecutable', 'Claude')
    if not exe.exists():
        raise ClaudeMultiError(f'executable missing: {exe}')
    return exe

def ensure_clone(i, force=False, out=print):
    """APFS-clone Claude.app (no extra disk space), tint its icon, rename it, drop its claude:// handler, ad-hoc sign. Idempotent."""
    if is_primary(i):
        raise ClaudeMultiError('the primary official window uses the stock Claude.app (no clone)')
    if not IS_MAC:
        raise ClaudeMultiError('cloning Claude.app needs macOS')
    src = official_app(); dst = clone_path(i); stamp = dst / 'Contents' / '.multi-version'
    want = f"{app_version(src)}|{i.get('palette')}|{i['name']}|2"
    if dst.exists() and not force and stamp.exists() and stamp.read_text() == want:
        return dst
    CLONES.mkdir(parents=True, exist_ok=True)
    tmp_app = CLONES / f'.build-{i["id"]}.app'
    if tmp_app.exists():
        shutil.rmtree(tmp_app, ignore_errors=True)
    try:
        r = sh('cp', '-cR', str(src), str(tmp_app), check=False)         # -c = APFS clonefile (instant, no extra space)
        if r.returncode != 0:
            shutil.rmtree(tmp_app, ignore_errors=True)
            sh('cp', '-R', str(src), str(tmp_app))
        plist_path = tmp_app / 'Contents' / 'Info.plist'; info = plistlib.loads(plist_path.read_bytes())
        icon_name = info.get('CFBundleIconFile', 'electron.icns'); icon_name += '' if icon_name.endswith('.icns') else '.icns'
        icns = tmp_app / 'Contents' / 'Resources' / icon_name
        if i.get('palette') not in (None, 'official'):
            if shutil.which('sips') and shutil.which('iconutil'):
                try:
                    build_icns(icns, i['palette'], icns, HOME_ROOT / 'tmp' / i['id'])
                except (ClaudeMultiError, AssertionError, OSError, zlib.error) as e:
                    out(f'warning: icon tint failed, keeping the original icon ({mask_secrets(e)})')
            else:
                out('warning: sips/iconutil not found - keeping the original icon')
        info['CFBundleName'] = info['CFBundleDisplayName'] = i['name']
        info['CFBundleIdentifier'] = f"{info.get('CFBundleIdentifier', 'com.anthropic.claudefordesktop').split('.multi.')[0]}.multi.{i['id']}"
        info.pop('CFBundleURLTypes', None)
        plist_path.write_bytes(plistlib.dumps(info))
        sh('xattr', '-cr', str(tmp_app), check=False)
        old = CLONES / f'.old-{i["id"]}.app'
        shutil.rmtree(old, ignore_errors=True)
        if dst.exists():
            os.replace(dst, old)
        try:
            os.replace(tmp_app, dst)
        except Exception:
            if old.exists():
                os.replace(old, dst)                          # put the previous clone back
            raise
        shutil.rmtree(old, ignore_errors=True)
    except Exception:
        shutil.rmtree(tmp_app, ignore_errors=True)
        raise
    signed = False
    if shutil.which('codesign'):
        r = sh('codesign', '--force', '--deep', '--sign', '-', str(dst), check=False)
        signed = r.returncode == 0
        if not signed:
            out(f'warning: codesign failed - the clone may refuse to start ({mask_secrets(r.stderr.strip())[:200]})')
    else:
        out('warning: codesign not found (install the Xcode Command Line Tools: xcode-select --install) - the clone will likely not start')
    if signed:
        stamp.write_text(want)                               # no stamp for an unsigned clone: the next launch/init retries
    return dst


# ------------------------------------------------------------------ processes
def _started(text):
    try:
        return time.mktime(time.strptime(re.sub(r'\s+', ' ', text), '%a %b %d %H:%M:%S %Y'))
    except ValueError:
        return 0.0

def running(i):
    """[(pid, start_time)] of the main process of this window (macOS: matched by executable and --user-data-dir)."""
    out = sh('ps', '-axo', 'pid=,lstart=,command=', check=False).stdout
    try:
        prefix = (official_app() / 'Contents' / 'MacOS').as_posix() + '/'
    except ClaudeMultiError:
        prefix = None
    pat = None if is_primary(i) else re.compile(re.escape(f'--user-data-dir={data_dir(i)}') + r'(?=\s|$)')
    pids = []
    for line in out.splitlines():
        m = re.match(r'\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]{7,8}\s+\d{4})\s+(.*)', line)
        if not m or '--type=' in m.group(3):
            continue
        cmd = m.group(3)
        if pat is None:
            ok = prefix and cmd.startswith(prefix) and '--user-data-dir' not in cmd
        else:
            ok = bool(pat.search(cmd)) and 'Claude' in cmd
        if ok:
            pids.append((int(m.group(1)), _started(m.group(2))))
    return pids

def build_env(i, base=None):
    """Child environment: process-level TZ and proxy variables for this window only (other windows / the shell are untouched)."""
    env = dict(os.environ if base is None else base)
    for k in PROXY_VARS + ('TZ',):
        env.pop(k, None)
    if i.get('proxy'):
        for k in PROXY_VARS:
            env[k] = i['proxy']
        skip = 'localhost,127.0.0.1,::1'               # keep the local cc-switch gateway (127.0.0.1:15721) reachable
        for k in ('NO_PROXY', 'no_proxy'):
            env[k] = (env[k] + ',' + skip) if env.get(k) else skip
    if i.get('timezone'):
        env['TZ'] = i['timezone']
    return env

def build_args(i, url=None):
    args = []
    if not is_primary(i):
        args.append(f'--user-data-dir={data_dir(i)}')
    if lang_for(i):
        args.append(f'--lang={lang_for(i)}')
    args.append('--webrtc-ip-handling-policy=disable_non_proxied_udp')      # Chromium WebRTC otherwise uses raw UDP and bypasses the proxy
    if i.get('proxy') and i.get('proxyServerFlag'):                         # opt-in: env vars are the default carrier
        u = urllib.parse.urlsplit(i['proxy']); args.append(f'--proxy-server={u.scheme}://{u.hostname}:{u.port}')
    if url:
        if not re.fullmatch(r'claude(-desktop)?://\S+', url):
            raise ClaudeMultiError('refusing non-claude:// URL')
        args.append(url)
    return args

def log_line(msg):
    try:
        HOME_ROOT.mkdir(parents=True, exist_ok=True)
        with open(HOME_ROOT / 'claude-multi.log', 'a', encoding='utf-8') as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {mask_secrets(msg)}\n")
    except OSError:
        pass

def provision(i, out=print, build=True, force=False, strict=False):
    """Everything an instance needs on disk. Idempotent. Returns a summary dict."""
    res = dict(id=i['id'], name=i['name'], kind=i['kind'], data_dir=str(store_root(i)), mcp='n/a', sessions='n/a', clone=None, warnings=[])
    def warn(m): res['warnings'].append(m); out('warning: ' + m)
    eff = store_root(i); eff.mkdir(parents=True, exist_ok=True)
    if not is_primary(i):
        data_dir(i).mkdir(parents=True, exist_ok=True)
    if is_official(i) and not is_primary(i):               # pure 1P: never see a 3P / cc-switch profile
        for lib in (data_dir(i) / 'configLibrary', data_dir(i).parent / 'Claude-3p' / 'configLibrary'):
            if lib.is_symlink() or lib.is_file():
                lib.unlink()
            elif lib.exists():
                shutil.rmtree(lib)
    elif not is_official(i):
        try:
            sync_profile(i)
        except ClaudeMultiError as e:
            if strict:
                raise
            warn(str(e))
    if not is_primary(i):
        canon = APP_SUP / 'Claude' / 'claude_desktop_config.json'; inst = eff / 'claude_desktop_config.json'
        if inst.exists() or inst.is_symlink():
            res['mcp'] = 'present'
        elif canon.exists():
            for how, fn in (('symlink', lambda: os.symlink(canon, inst)), ('hardlink', lambda: os.link(canon, inst)), ('copy', lambda: shutil.copy2(canon, inst))):
                try:
                    fn(); res['mcp'] = how; break
                except OSError:
                    continue
            else:
                warn('could not mirror claude_desktop_config.json')
        else:
            res['mcp'] = 'source missing'
        if read_config()['settings'].get('syncSessions') is not False:
            states = []
            for n in SESSION_DIRS:
                real = APP_SUP / 'Claude' / n; link = eff / n
                if link.exists() or link.is_symlink():
                    states.append('present')
                elif real.exists():
                    try:
                        os.symlink(real, link, target_is_directory=True); states.append('linked')
                    except OSError as e:
                        warn(f'could not link {n}: {e.strerror or e}')
                else:
                    states.append('source missing')
            res['sessions'] = ','.join(sorted(set(states)))
    if build and not is_primary(i):
        if IS_MAC:
            try:
                res['clone'] = str(ensure_clone(i, force=force, out=out))
            except ClaudeMultiError as e:
                warn(f'clone not built: {e}')
        else:
            out('note: not macOS - skipped the Claude.app clone')
    return res

def launch(i, url=None, out=print):
    if not IS_MAC:
        raise ClaudeMultiError('launching needs macOS')
    cur = running(i)
    if cur and not url:
        prof = 0.0
        if not is_official(i):
            try:
                prof = sync_profile(i)
            except ClaudeMultiError:
                prof = 0.0
        if prof and any(s < prof for _, s in cur):                      # a running window read its profile at start-up
            out(f"'{i['id']}' has a newer profile - restarting"); stop(i)
        else:
            out(f"'{i['id']}' is already running (pid {cur[0][0]})"); return cur[0][0]
    provision(i, out=out, build=True, strict=True)
    exe = clone_binary(official_app() if is_primary(i) else ensure_clone(i, out=out))
    args = build_args(i, url)
    log_line(f"launch {i['id']}: {exe} {' '.join(args)}")
    try:
        p = subprocess.Popen([str(exe)] + args, env=build_env(i), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        raise ClaudeMultiError(f"cannot start {exe}: {e.strerror or e}") from None
    time.sleep(1.5)
    if p.poll() is not None:
        raise ClaudeMultiError(f"the app exited immediately (code {p.returncode}); if this is a clone, check codesign and see: xattr -l '{exe.parent.parent.parent}'")
    out(f"started '{i['id']}' (pid {p.pid})" + (f" proxy={mask_proxy(i['proxy'])}" if i.get('proxy') else '') + (f" TZ={i['timezone']}" if i.get('timezone') else ''))
    return p.pid

def stop(i, timeout=10):
    pids = [p for p, _ in running(i)]
    for p in pids:
        try: os.kill(p, signal.SIGTERM)
        except OSError: pass
    end = time.time() + timeout
    while pids and time.time() < end:
        pids = [p for p in pids if _alive(p)]
        time.sleep(0.3)
    return len(pids) == 0

def _alive(pid):
    try:
        os.kill(pid, 0); return True
    except OSError:
        return False

def restart(i, out=print):
    if not stop(i):
        raise ClaudeMultiError(f"'{i['id']}' did not quit within 10 s")
    time.sleep(2)                                       # let the single-instance lock go
    return launch(i, out=out)


# ------------------------------------------------------------------ egress check (Windows `check` / Test-InstancePurity)
def http_get(url, proxy=None, timeout=8):
    """GET through the instance proxy (stdlib only). Socks proxies are not supported by urllib."""
    if proxy and proxy.startswith('socks'):
        raise ClaudeMultiError('socks proxies cannot be checked with the standard library - use an http(s) proxy URL or check manually')
    h = urllib.request.ProxyHandler({'http': proxy, 'https': proxy} if proxy else {})
    req = urllib.request.Request(url, headers={'User-Agent': 'claude-multi-check'})
    with urllib.request.build_opener(h).open(req, timeout=timeout) as r:
        return r.read(65536).decode('utf-8', 'replace')

def check_instance(i, fetch=None):
    fetch = fetch or http_get; proxy = i.get('proxy'); expect = i.get('timezone')
    r = dict(id=i['id'], name=i['name'], proxy=mask_proxy(proxy) or '(direct)', exit_ip='Connection Failed', location='Unknown', ip_type='Unknown',
             risk='N/A', claude='Unreachable', tz_match='N/A', error=None)
    try:
        ip = fetch('https://api.ipify.org', proxy).strip()
        if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', ip):
            raise ClaudeMultiError('unexpected answer from api.ipify.org')
    except Exception as e:
        r['error'] = mask_secrets(e if str(e) else type(e).__name__)
        return r
    r['exit_ip'] = ip
    def j(url):
        try:
            return json.loads(fetch(url, proxy))
        except Exception:
            return None
    risk = j(f'https://api.ipquery.io/{ip}'); geo = j(f'http://ip-api.com/json/{ip}')
    if geo and geo.get('status', 'success') != 'fail':
        r['location'] = f"{geo.get('city')}, {geo.get('countryCode')}"
        r['claude'] = 'Supported' if geo.get('countryCode') in SUPPORTED_CC else 'Restricted'
    else:
        r['claude'] = 'Unknown'; geo = None
    if risk and isinstance(risk.get('risk'), dict):
        r['ip_type'] = 'Datacenter' if risk['risk'].get('is_datacenter') else 'Residential'
        r['risk'] = f"{risk['risk'].get('risk_score')}/100"
    else:
        r['ip_type'] = 'Unknown'; r['risk'] = 'Unknown'
    ip_tz = geo.get('timezone') if geo else 'Unknown'
    r['tz_match'] = (f'Matched (100%)' if ip_tz == expect else f'Mismatch ({ip_tz})') if expect else f'Not Set ({ip_tz})'
    return r

def format_check(r):
    rows = [('Instance', f"{r['name']} [{r['id']}]"), ('Proxy', r['proxy']), ('Exit IP', r['exit_ip']), ('Location', r['location']),
            ('IP type', r['ip_type']), ('Risk score', r['risk']), ('Claude region', r['claude']), ('Timezone', r['tz_match'])]
    if r.get('error'):
        rows.append(('Error', r['error']))
    return [f'{k:<14}{v}' for k, v in rows]


# ------------------------------------------------------------------ sessions: mirror + silent refresh
def session_folders(c):
    for i in c['instances']:
        cs = store_root(i) / 'claude-code-sessions'
        if cs.exists():
            for a in cs.iterdir():
                if a.is_dir():
                    for o in a.iterdir():
                        if o.is_dir() and not o.name.endswith('-backup'):
                            yield i['id'], o

def sync_sessions(c, stale):
    """Newest-wins mirror of every local_*.json into every session folder; a window that receives a session it never had becomes stale."""
    folders = list(session_folders(c))
    if len(folders) < 2:
        return 0
    best = {}
    for _, f in folders:
        for p in f.glob('local_*.json'):
            m = p.stat().st_mtime
            if p.name not in best or m > best[p.name][1]:
                best[p.name] = (p, m)
    copied = 0
    for iid, f in folders:
        for name, (src, m) in best.items():
            dst = f / name
            if (not dst.exists()) or dst.stat().st_mtime < m - 1:
                if dst.exists() and dst.resolve() == src.resolve():
                    continue
                new = not dst.exists(); shutil.copy2(src, dst); os.utime(dst, (m, m)); copied += 1
                if new:
                    stale[iid] = time.time()
    return copied

def agent(interval=6):
    pidf = HOME_ROOT / 'agent.pid'
    try:
        if pidf.exists() and _alive(int(pidf.read_text().strip())) and int(pidf.read_text().strip()) != os.getpid():
            raise ClaudeMultiError('the agent is already running')
    except ValueError:
        pass
    HOME_ROOT.mkdir(parents=True, exist_ok=True); pidf.write_text(str(os.getpid()))
    stale = {}; last_restart = {}
    try:
        while True:
            try:
                c = read_config()
                if c['settings']['syncSessions']:
                    sync_sessions(c, stale)
                if c['settings']['liveRefresh']:
                    front = sh('osascript', '-e', 'tell application "System Events" to get unix id of first process whose frontmost is true', check=False).stdout.strip()
                    for i in c['instances']:
                        if is_official(i) and not c['settings']['refreshOfficial']:
                            continue
                        since = stale.get(i['id'])
                        if not since or time.time() - since < 8 or time.time() - last_restart.get(i['id'], 0) < 120:
                            continue
                        pids = running(i)
                        if not pids or str(pids[0][0]) == front:
                            continue
                        cs = store_root(i) / 'claude-code-sessions'
                        if any(time.time() - p.stat().st_mtime < 45 for p in cs.rglob('local_*.json')):   # the app wrote recently: busy
                            continue
                        restart(i, out=log_line); stale.pop(i['id'], None); last_restart[i['id']] = time.time()
            except (ClaudeMultiError, OSError) as e:
                log_line(f'agent: {e}')
            time.sleep(interval)
    finally:
        try: pidf.unlink()
        except OSError: pass


# ------------------------------------------------------------------ CLI
def _targets(a):
    c = read_config()
    return [get_instance(c, a.id)] if a.id else list(c['instances'])

def cmd_list(a):
    c = read_config()
    print(f"{'ID':<12}{'NAME':<24}{'KIND':<10}{'PALETTE':<12}{'PROXY':<30}{'TIMEZONE':<22}{'PROVIDER':<16}RUNNING")
    for i in c['instances']:
        pids = [p for p, _ in running(i)] if IS_MAC else '-'
        print(f"{i['id']:<12}{i['name']:<24}{i['kind']:<10}{i.get('palette', ''):<12}{mask_proxy(i.get('proxy')):<30}{i.get('timezone', ''):<22}{i.get('provider', ''):<16}{pids}")

def cmd_add(a):
    c = read_config()
    n = make_instance(c, a.id, a.name, a.kind, a.palette, a.provider, a.profile, a.proxy, a.timezone, a.lang)
    c['instances'].append(n); save_config(c)
    print(f"added '{a.id}' ({n['kind']})" + (f" proxy={mask_proxy(n.get('proxy'))}" if n.get('proxy') else '') + (f" timezone={n['timezone']}" if n.get('timezone') else ''))
    if not a.no_init:
        r = provision(n)
        print(f"initialized: data={r['data_dir']} mcp={r['mcp']} sessions={r['sessions']} clone={r['clone'] or '-'}")

def cmd_init(a):
    errors = 0
    for i in _targets(a):
        try:
            r = provision(i, force=getattr(a, 'force', False))
            print(f"[{i['id']}] data={r['data_dir']}\n    mcp config: {r['mcp']}  sessions: {r['sessions']}  clone: {r['clone'] or '-'}")
        except ClaudeMultiError as e:
            errors += 1; print(f"[{i['id']}] error: {e}")
    if errors:
        raise SystemExit(1)

def cmd_check(a):
    print('Auditing instance egress IP, proxy purity and timezone alignment...')
    for i in _targets(a):
        print(); print('\n'.join(format_check(check_instance(i))))

def cmd_remove(a):
    c = read_config(); i = get_instance(c, a.id)
    if is_primary(i): raise ClaudeMultiError("the primary official window cannot be removed (use 'uninstall')")
    if IS_MAC and running(i): print(f"warning: '{a.id}' is still running")
    c['instances'] = [x for x in c['instances'] if x['id'] != a.id]; save_config(c)
    app = clone_path(i)
    if app.exists(): shutil.rmtree(app, ignore_errors=True)
    print(f"removed '{a.id}' (its data in {HOME_ROOT / a.id} was left untouched)")

def cmd_install(a):
    c = read_config(); bad = 0
    for i in c['instances']:
        if is_primary(i):
            continue
        try:
            print('built', ensure_clone(i, force=a.force))
        except ClaudeMultiError as e:
            bad += 1; print(f"[{i['id']}] error: {e}")
    print(f'\nDrag the apps from {CLONES} to the Dock. Start them through this tool (launch) so they get their own data, proxy and timezone.')
    if bad: raise SystemExit(1)

def cmd_uninstall(a):
    n = 0
    if CLONES.is_dir():
        for app in CLONES.glob('*.app'):
            if (app / 'Contents' / '.multi-version').exists() or app.name.startswith(('.build-', '.old-')):
                shutil.rmtree(app, ignore_errors=True); print('removed', app); n += 1
        try: CLONES.rmdir()
        except OSError: pass
    shutil.rmtree(HOME_ROOT / 'tmp', ignore_errors=True)
    print(f'removed {n} clone(s). Window data in {HOME_ROOT} and instances.json were left untouched.')

def cmd_launch(a):
    launch(get_instance(read_config(), a.id), a.url)

def cmd_stop(a):
    i = get_instance(read_config(), a.id); print('stopped' if stop(i) else 'still running after 10 s')

def cmd_restart(a):
    restart(get_instance(read_config(), a.id))

def cmd_sync(a):
    print('copied:', sync_sessions(read_config(), {}))

def cmd_providers(a):
    for p in cc_providers():
        print(p['id'], p['name'], '(current)' if p['current'] else '')

def cmd_gui(a):
    try:
        from claude_multi_gui import run
    except ImportError as e:
        raise ClaudeMultiError(f'tkinter is not available ({e}). Install Python from python.org (includes Tk) or use the CLI commands.') from None
    run(sys.modules[__name__])

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--version', action='version', version=f'claude-multi macOS {VERSION}')
    sp = ap.add_subparsers(dest='cmd')
    for n, f in (('list', cmd_list), ('gui', cmd_gui), ('sync', cmd_sync), ('providers', cmd_providers), ('uninstall', cmd_uninstall), ('agent', lambda a: agent())):
        sp.add_parser(n).set_defaults(f=f)
    p = sp.add_parser('add'); p.set_defaults(f=cmd_add)
    p.add_argument('--id', required=True); p.add_argument('--name'); p.add_argument('--kind', default='3p', choices=['official', '3p', 'cc-switch'])
    p.add_argument('--palette', default='violet'); p.add_argument('--provider'); p.add_argument('--profile'); p.add_argument('--proxy'); p.add_argument('--timezone')
    p.add_argument('--lang'); p.add_argument('--no-init', action='store_true')
    for n in ('init', 'setup'):
        p = sp.add_parser(n); p.add_argument('--id'); p.add_argument('--force', action='store_true'); p.set_defaults(f=cmd_init)
    for n in ('check', 'test-ip', 'purity'):
        p = sp.add_parser(n); p.add_argument('--id'); p.set_defaults(f=cmd_check)
    p = sp.add_parser('remove'); p.add_argument('--id', required=True); p.set_defaults(f=cmd_remove)
    p = sp.add_parser('install'); p.add_argument('--force', action='store_true'); p.set_defaults(f=cmd_install)
    p = sp.add_parser('launch'); p.add_argument('--id', required=True); p.add_argument('--url'); p.set_defaults(f=cmd_launch)
    for n, f in (('stop', cmd_stop), ('restart', cmd_restart)):
        p = sp.add_parser(n); p.add_argument('--id', required=True); p.set_defaults(f=f)
    a = ap.parse_args(argv)
    try:
        (a.f if getattr(a, 'f', None) else cmd_gui)(a)
    except ClaudeMultiError as e:
        print(f'error: {mask_secrets(e)}', file=sys.stderr); return 1
    except KeyboardInterrupt:
        return 130
    return 0

if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(main())
