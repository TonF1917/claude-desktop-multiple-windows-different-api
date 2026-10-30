#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================="
echo "    Claude Multi Manager Installer (macOS)"
echo "=========================================="
echo ""

# 1. Check Python 3
if ! command -v python3 >/dev/null 2>&1; then
    echo "[FAIL] python3 was not found on your system."
    echo ""
    echo "To install Python 3, run:"
    echo "    brew install python@3.11"
    echo "or download the official installer from:"
    echo "    https://www.python.org/downloads/"
    exit 1
fi

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_OK=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 8) else 0)')

if [ "$PY_OK" != "1" ]; then
    echo "[FAIL] Python $PY_VER is installed, but Python >= 3.8 is required."
    echo ""
    echo "To upgrade Python, run:"
    echo "    brew install python@3.11"
    exit 1
fi
echo "[OK] Python $PY_VER detected."

# 2. Check tkinter
if ! python3 -c 'import tkinter' >/dev/null 2>&1; then
    echo "[WARN] tkinter module is not installed for Python $PY_VER."
    echo "       The GUI manager will not be able to open without tkinter."
    echo ""
    echo "To install tkinter via Homebrew, run:"
    echo "    brew install python-tk@$PY_VER"
    echo "or install Python via the official python.org installer."
    echo ""
else
    echo "[OK] tkinter GUI module is available."
fi

# 3. Check official Claude.app
if [ ! -d "/Applications/Claude.app" ]; then
    echo "[WARN] Official Claude.app was not found in /Applications/Claude.app."
    echo "       Claude Desktop is required to clone and launch multi-instances."
    echo ""
    echo "Download Claude Desktop from:"
    echo "    https://claude.ai/download"
    echo ""
else
    echo "[OK] /Applications/Claude.app found."
fi

# 4. Make scripts executable
chmod +x "$SCRIPT_DIR/claude_multi.py" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/claude_multi_gui.py" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/Claude Multi.command" 2>/dev/null || true

# 5. Create clickable launcher in ~/Applications
TARGET_APPS="$HOME/Applications"
mkdir -p "$TARGET_APPS"

APP_BUNDLE="$TARGET_APPS/Claude Multi Manager.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Write Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Claude Multi Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.anthropic.claude-desktop-multi.manager</string>
    <key>CFBundleName</key>
    <string>Claude Multi Manager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Write executable launcher script inside .app bundle
cat <<EOF > "$APP_BUNDLE/Contents/MacOS/Claude Multi Manager"
#!/bin/bash
INSTALL_DIR="$SCRIPT_DIR"
if [ ! -f "\$INSTALL_DIR/claude_multi_gui.py" ]; then
    INSTALL_DIR="\$(cd "\$(dirname "\$0")/../../../../macos" && pwd)"
fi
exec /usr/bin/env python3 "\$INSTALL_DIR/claude_multi_gui.py" "\$@"
EOF

chmod +x "$APP_BUNDLE/Contents/MacOS/Claude Multi Manager"

# Copy icon from Claude.app if available
if [ -f "/Applications/Claude.app/Contents/Resources/electron.icns" ]; then
    cp "/Applications/Claude.app/Contents/Resources/electron.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# Also create Claude Multi Manager.command in ~/Applications
cat <<EOF > "$TARGET_APPS/Claude Multi Manager.command"
#!/bin/bash
# Double-click to launch Claude Multi GUI
INSTALL_DIR="$SCRIPT_DIR"
exec /usr/bin/env python3 "\$INSTALL_DIR/claude_multi_gui.py" "\$@"
EOF
chmod +x "$TARGET_APPS/Claude Multi Manager.command"

echo "[OK] Installed clickable launcher to:"
echo "     - $APP_BUNDLE"
echo "     - $TARGET_APPS/Claude Multi Manager.command"
echo ""

# 6. Run doctor
echo "Running environment doctor..."
echo ""
python3 "$SCRIPT_DIR/claude_multi.py" doctor || true

echo ""
echo "=========================================="
echo "Installation complete!"
echo "Launch Claude Multi Manager via:"
echo "  1. ~/Applications/Claude Multi Manager.app"
echo "  2. ~/Applications/Claude Multi Manager.command"
echo "  3. Terminal: python3 $SCRIPT_DIR/claude_multi.py gui"
echo "=========================================="
