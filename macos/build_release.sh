#!/usr/bin/env bash
# Build ClaudeMulti-macOS-v<VERSION>.zip from the repository (runs on macOS or Linux; needs only bash + python3).
#   macos/build_release.sh [output-dir]      # default: ./dist
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
fi
[ -n "$PY" ] || { echo "error: python3 not found" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: macos/VERSION must look like 1.2.3 (got '$VERSION')" >&2; exit 1; }
OUT="${1:-$REPO/dist}"
NAME="ClaudeMulti-macOS-v$VERSION"

for f in macos/claude_multi.py macos/claude_multi_gui.py palettes.json macos/VERSION examples/profile.example.json "macos/Claude Multi.command" README.md README.zh-CN.md LICENSE; do
  [ -f "$REPO/$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

# fail early on syntax errors; keep bytecode out of the tree
PYTHONDONTWRITEBYTECODE=1 "$PY" - "$REPO" <<'EOF'
import sys, pathlib
for f in ('claude_multi.py', 'claude_multi_gui.py'):
    p = pathlib.Path(sys.argv[1], 'macos', f)
    compile(p.read_text(encoding='utf-8'), str(p), 'exec')
print('syntax ok')
EOF

mkdir -p "$OUT"
"$PY" - "$REPO" "$OUT" "$NAME" "$VERSION" <<'EOF'
import sys, zipfile, pathlib, time
repo, out, name, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
# (source in repo, path inside the zip, executable?)
files = [('macos/claude_multi.py', 'macos/claude_multi.py', True), ('macos/claude_multi_gui.py', 'macos/claude_multi_gui.py', False),
         ('macos/VERSION', 'macos/VERSION', False), ('palettes.json', 'palettes.json', False),
         ('examples/profile.example.json', 'examples/profile.example.json', False),
         ('macos/Claude Multi.command', 'Claude Multi.command', True),
         ('README.md', 'README.md', False), ('README.zh-CN.md', 'README.zh-CN.md', False), ('LICENSE', 'LICENSE', False)]
final = out / f'{name}.zip'
target = out / f'{name}.zip.tmp'          # built next to the final name, moved into place only when complete
if target.exists():
    target.unlink()
now = time.localtime()[:6]
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
    for src, dst, exe in files:
        data = (repo / src).read_bytes()
        if dst.endswith('.command'):
            data = data.replace(b'\r\n', b'\n')            # a CRLF shebang line would not run
        zi = zipfile.ZipInfo(f'{name}/{dst}', date_time=now)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.create_system = 3                                # Unix, so the mode bits below are honoured by unzip / Archive Utility
        zi.external_attr = (0o100755 if exe else 0o100644) << 16
        z.writestr(zi, data)
import os
os.replace(target, final)
print(f'built {final} ({final.stat().st_size} bytes, {len(files)} files)')
EOF
