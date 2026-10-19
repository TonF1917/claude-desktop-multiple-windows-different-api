<p align="center">
  <img src="assets/claude-violet.png" width="128" alt="Claude Multi Violet Icon" />
</p>

# Claude Desktop: multiple windows with different APIs at the same time

**English** · [简体中文](README.zh-CN.md)

**Use several Claude Desktop windows at once, each on a different API.** Keep your **official Claude subscription** in one window and run as many other windows as you like on **custom / third-party APIs** (driven by [cc-switch](https://github.com/farion1231/cc-switch)). Multi-API, multi-window, multi-account Claude Desktop - on **Windows** (tested) and **macOS** (experimental).

Every window has its own data, its own **recoloured icon** (desktop, taskbar, system tray), its own taskbar button and - if you choose - its own API. The default third-party colour is the official icon in **purple-black with a white star**; pick any palette (Gemini, GPT, Perplexity, DeepSeek, WorkBuddy) or any `#RRGGBB`.

> Unofficial community tool. Not affiliated with or endorsed by Anthropic or cc-switch. Icons are generated **locally** from the icon of your installed app; no Anthropic artwork is shipped in this repository.

## Features

* **Official + third-party at the same time.** The official window keeps your subscription login; other windows run on whatever API cc-switch points them at.
* **A different API per window.** Pick a cc-switch provider for each window (it then talks to that provider's upstream directly), or let a window *follow* cc-switch's current selection.
* **As many windows as you want**, in a small GUI in the Anthropic look (English by default, 中文 switch built in).
* **Separate icons everywhere:** desktop shortcut, taskbar button, window icon, **system-tray icon and tooltip**.
* **Shared sessions:** new sessions, titles, pinned/starred sessions, pin order and MCP servers are mirrored between windows; idle background windows restart silently to load them.
* **`claude://` links** open in the window you used last (or a fixed one).
* **Same session in two windows?** You get a Windows notification before the two transcripts drift apart.
* **Update-proof:** nothing is patched or copied on Windows; the install path is resolved from the Store package at every launch.

## Windows - quick start

Requirements: Windows 11 (10 should work), PowerShell 5.1+, Claude Desktop from the Microsoft Store (`AnthropicPBC.Claude`), [cc-switch](https://github.com/farion1231/cc-switch) with a *Claude Desktop* provider.

```powershell
git clone https://github.com/TonF1917/claude-desktop-multiple-windows-different-api
cd claude-desktop-multiple-windows-different-api
.\claude-multi.ps1 install        # icons + shortcuts for every window in instances.json
.\claude-multi.ps1 gui            # or use the Desktop shortcut "Claude Multi Manager"
```

Then right-click each new Desktop shortcut and choose **Pin to taskbar** (Windows does not let scripts pin).

| Command | What it does |
|---|---|
| `gui` | the manager window |
| `add -Id off2 -Name "Claude Official 2" -Kind official -Palette perplexity [-Proxy <url>] [-Timezone <tz>]` | add a secondary official direct window (supports custom tint, dedicated proxy & process timezone) |
| `add -Id gem -Name "Claude Gemini" -Palette gemini [-Provider <id>] [-Proxy <url>] [-Timezone <tz>]` | add a third-party window (any palette name or `"#E11D48"`) |
| `init [-Id <id>]` (alias `setup`) | provision/repair instance environment (creates Data dir, mirrors MCP config, junctions sessions, generates tinted icon & desktop shortcut) |
| `install [-Force]` | (re)build icons and shortcuts; rewires your existing pinned Claude shortcuts |
| `launch -Id gem` | start a window |
| `list`, `providers`, `sync`, `remove -Id gem`, `icons -Force`, `uninstall` | housekeeping |

## macOS - experimental

The port lives in [`macos/`](macos) (Python 3 from the Xcode Command Line Tools, standard library only). It was written **without access to a Mac**: configuration, palettes, icon recolouring, cc-switch profiles, session mirroring and the GUI are exercised on Windows; the macOS-only steps (cloning `Claude.app`, `codesign`, `open`, `iconutil`) follow the documented tool behaviour but have **not been run on real hardware**. Bug reports with the terminal output are very welcome.

```bash
git clone https://github.com/TonF1917/claude-desktop-multiple-windows-different-api
cd claude-desktop-multiple-windows-different-api
python3 macos/claude_multi.py gui
python3 macos/claude_multi.py add --id gem --name "Claude Gemini" --palette gemini
python3 macos/claude_multi.py install      # one tinted APFS clone of Claude.app per extra window (~/Applications/Claude Multi)
python3 macos/claude_multi.py launch --id gem
python3 macos/claude_multi.py agent &      # session mirroring + silent background refresh
```

Not ported yet on macOS: pin/MCP sync, `claude://` routing, tray icon, official-window isolation (launching Claude from the Dock while cc-switch has a third-party profile applied can switch it to third-party mode).

## Using cc-switch

Choose a *Claude Desktop* provider in cc-switch (not "Official"). cc-switch starts its gateway on `127.0.0.1:15721` and writes the profile into the shared 3P config folder. Windows that **follow** cc-switch use that gateway and its *currently selected* provider. Windows with a **specific provider** get a profile built from that provider's own base URL, key and model routes and talk to its upstream directly (Anthropic-format providers only; model ids are the real upstream ids). That is how two windows use two different APIs at the same moment. A hand-written profile can be set per window with `"profile": "path\\to\\profile.json"` (see `examples/profile.example.json`).

When cc-switch is set to *Official*, third-party windows have no profile and show the normal sign-in screen.

## What is synced between windows

| Item | Synced? | How / when it shows up in another window |
|---|---|---|
| Sessions (new ones, titles, archive state) | yes | files mirrored within seconds; the other window loads them after its silent background restart |
| Pinned / starred sessions and pin order | yes | the `isStarred` flag in each session, plus `starred-*` and `pinnedOrder` in `claude_desktop_config.json`; written into a window only while it is closed (or just before its background restart) so the app cannot overwrite it |
| MCP servers | yes | same mechanism (`mcpServers`); switch off in the GUI |
| Conversation transcripts | yes (natively) | they live in `~\.claude\projects`, shared by every window |
| Login, provider, model list, window size/position | no | per window on purpose |

**Known limit - pins.** Each Claude Desktop keeps its pinned list in memory and rewrites it itself: a running window keeps showing its own pins until it is restarted, and a starting window trims the list it reads (tested: 17 pins written while closed came back as 12 within 8 seconds; the dropped ones are sessions created after 12 Oct 23:50 plus one older one - the rule is the app's, not ours). This tool keeps the config files identical and never lets an empty or new window wipe them, but it cannot force two windows to *display* the same pins.

**Why not instantly?** Claude Desktop does read these folders - but only when it starts, and again only when the signed-in account or organisation changes. It has no file watcher, rewriting its `config.json` does not make it re-read anything, and remote debugging is blocked in the production build, so nothing outside the app can tell a running window to re-read the folder. The closest safe thing is the silent restart: a window restarts in the background **only** if it is not focused, has not written a session file in the last 45 s, and none of its agent/tool child processes is using CPU. The restarted window comes back **minimised and without taking the focus** (it is started with `SW_SHOWMINNOACTIVE`), and syncing shows no pop-ups at all: notifications are off by default and can be switched on in the manager. A window you are using right now (focused **and** keyboard/mouse input in the last 90 s) is never restarted: you get a Windows notification with a **Reload now** button instead (or use *Restart selected* in the manager); once you have been idle for 90 s it is refreshed automatically. Session folders may be shared between windows through junctions - the check is therefore per running window ("does it know every session file that exists?"), not based on copying. The official window is excluded unless you tick *Also live-refresh the official window* (it may hold unsent drafts).

**Same session in two windows.** Every window runs its own Claude Code process per session (`--resume=<id>`). If you send in both, both append to the same transcript while each keeps its own context, so the history interleaves and the windows disagree. The agent notifies you when a session is live in two windows and one of them is working - keep a session active in one window at a time.

**How sessions look.** Every window shows the same merged list; there is no per-window badge. A session keeps its folder, model and effort, but when you open it in another window it runs through **that window's** login/provider (subscription in the official one, the chosen provider in a third-party one).

## How it works (what was found the hard way)

1. **One config library for everyone.** The app reads `configLibrary` from `%LOCALAPPDATA%\Claude-3p`; cc-switch writes the third-party profile there; a profile with `disableDeploymentModeChooser` forces *every* window that reads it into 3P mode - including the official one on its next start.
2. **`--user-data-dir` and `CLAUDE_USER_DATA_DIR` do not help on Windows.** The production build strips the env var and overrides the data dir in 3P mode, so a second 3P window collides with the first and exits silently.
3. **`%LOCALAPPDATA%` does.** The 3P data dir is derived from that variable, so each extra window starts with its own private `LOCALAPPDATA` (`~\.claude-multi\<id>\Local`) and its own profile.
4. **Official isolation.** The official app is started with a private `LOCALAPPDATA` whose `Claude-3p` is empty (`Claude` and `Packages` are junctions to the real ones), so it can never be forced into 3P.
5. **Separate taskbar buttons and tray icons.** Electron gives every window the same AppUserModelID. A small background agent sets a per-window ID and icon (`SHGetPropertyStoreForWindow`, `WM_SETICON`) and re-skins the window's notification-area icon (`Shell_NotifyIcon`, `NIM_MODIFY`); the shortcuts carry matching IDs.
6. **Icons must not live in `AppData\*\ClaudeMulti`.** Explorer and the taskbar render a blank page for `.ico` files under such a folder (a `.ico` anywhere else works), so icons are generated into `~\.claude-multi\icons`.
7. **Update-proof.** The install path is resolved from the MSIX package on every launch; nothing is copied or patched, and no version number is stored.

## Caveats

* Windows: the official window picks up its isolation the next time it is **restarted**; a running window is never touched.
* Shortcuts that bypass this tool (Start-menu tile, protocol links registered elsewhere) start the official app without isolation.
* Everything relies on undocumented app behaviour and may break with a future Claude Desktop release.
* cc-switch is an independent project.

## License

MIT - see [LICENSE](LICENSE).
