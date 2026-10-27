#!/bin/bash
# Double-click launcher for the Claude Multi manager (macOS). If macOS blocks it the first time: right-click -> Open.
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 was not found. Install Python 3 from https://www.python.org/downloads/ (it includes Tk) or run: xcode-select --install"
  read -r -p "Press Enter to close" _; exit 1
fi
if [ -f macos/claude_multi.py ]; then SCRIPT=macos/claude_multi.py; else SCRIPT=claude_multi.py; fi
python3 "$SCRIPT" gui
rc=$?
if [ $rc -ne 0 ]; then
  echo; echo "The manager exited with code $rc (see the message above)."
  read -r -p "Press Enter to close" _
fi
exit $rc
