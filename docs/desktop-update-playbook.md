# Claude Desktop 升级 SOP（Windows / MSIX 版）

> 本文件是**操作手册**，不是升级触发器。它不会启动更新、不会重启实例、不会修改防火墙规则。
> 所有「执行」步骤都需要人显式调用对应命令。

## 1. 前置事实：更新粒度只能是全量

Windows 上 Claude Desktop 通过 MSIX 安装。本机上多个窗口
（`official` / `official2` / `official3` / 3p）**共享同一个包**：

- 所有 `Claude.exe` 进程的 `ExecutablePath` 指向同一个
  `C:\Program Files\WindowsApps\<pkgname>_<version>_x64__<pfn>\app\Claude.exe`；
- `%LOCALAPPDATA%\Microsoft\WindowsApps\claude-desktop-msstore.exe` 是指向该 `app\Claude.exe`
  的执行别名（符号链接）；
- `src/Icon.ps1` 的 `Get-ClaudePackage` 按**别名归属**解析包（见下），再按旧名
  `AnthropicPBC.Claude`、任意 `*Claude*` 包逐级回退。

实例之间的差异**只在启动参数**：各自的 `--user-data-dir`、`--proxy-server`、
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 与 `TZ`（见 `instances.json` 与 `src/Core.ps1`
的 `Invoke-Launch`）。因此：

> Store / MSIX 更新一次，整机唯一的二进制被替换，所有实例下次启动全部是新版。
> **不存在「只更新一个 official」的做法。** 横幅只在一个窗口弹出不代表只影响那一个。

### 1.1 双包标识（2026-11-11 实测，务必知道）

5.1231.2 起，两条更新渠道会在同一台机器上留下**两套包标识、同一版本号**：

| 包标识 | Publisher | 执行别名 | 来自 |
| :--- | :--- | :--- | :--- |
| `AnthropicPBC.Claude_fnn82j28hfe8t` | `CN=0ED83B57-1FA9-465C-98F8-41F190D0DF7F` | `claude-desktop-msstore.exe` | Microsoft Store |
| `Claude_pzs8sxrjxfjjc` | `CN="Anthropic, PBC"…SERIALNUMBER=4860621` | `claude-desktop.exe`、`claude-ssh-*` | 官方直装 `ClaudeSetup.exe` |

两者的 `app\Claude.exe` 都存在且都叫 `Claude.exe`，**launcher 走哪个完全由别名归属决定**。
`Get-ClaudePackage` 因此优先选「拥有已落盘别名」的那个包。`doctor` 在检测到多于一个
标识时会打 `[WARN]` 并列出各自拥有的别名——看到这个 WARN 不代表坏了，但要知道
另一套包也在磁盘上（约 300 MB），且它有自己的开始菜单入口。

若确实需要按实例锁版本，必须脱离 MSIX 为每个实例安装独立副本，并同时改造
包解析、图标来源、`claude://` handler 与快捷方式——属于架构变更，另行评估。

注意：Store 版会周期性自动检查更新。需要推迟升级时，不要依赖「不点 Update」，
应暂停 Store 自动更新；本手册不代为修改系统更新策略。

## 2. 隔离分层与唯一断点

| 层 | 载体 | 来源 | 升级后 |
| :--- | :--- | :--- | :--- |
| 一号一 IP | `--proxy-server`、`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` | `instances.json` + `Core.ps1` 的 `Invoke-Launch` 每次启动注入 | 不受影响 |
| 会话 / 指纹隔离 | `--user-data-dir`、独立 `LOCALAPPDATA` | 同上 | 不受影响，登录态与 cookie 留在各自 Data 目录 |
| 出口漂移熔断 | `NODE_OPTIONS --require shield.cjs` | `Core.ps1` 的 `Write-ShieldScript` **每次 launch 重写** | 不受影响；升级强制重启会让模板改动生效到全部实例 |
| WebRTC 裸 UDP 封堵 | 防火墙规则 `Program = <带版本号的 exe 绝对路径>` | `udp-guard` | **会失效** ← 唯一断点 |

第三层由 launcher 在每次启动时重建，与二进制版本无关。第四层不同：防火墙规则按
可执行文件绝对路径匹配，而 MSIX 的 `InstallLocation` 含版本号。升版后路径变化，
旧规则不再匹配新 `Claude.exe`，裸 UDP 出站恢复，WebRTC STUN 可能把真实公网 IP
交给对端。

`--webrtc-ip-handling-policy` / `--force-webrtc-ip-handling-policy` 等命令行开关
经二进制字符串核实为无效（见 `README.zh-CN.md` 与 `Core.ps1` 注释），写进
`Preferences` 的偏好也不下发 renderer。**防火墙规则是唯一的 UDP 封堵手段**，
没有降级冗余。

另一个陷阱：`Ensure-UdpLeakGuard` 在路径过期时会尝试重装规则，但重装需要管理员权限。
非提权启动时它只向 `~/.claude-multi/launch-audit.log` 写一条 `GUARD` 记录并返回
`needs-admin`，**不阻断启动**。所以升级后若不主动补一次，规则会静默失效。

## 3. 两个次级风险

1. **argv 守卫扩表**：当前版本主进程扫描 `process.argv`，命中黑名单即
   `exit(1)`（`refusing to start - a debugging or network-override switch is present`）。
   `Core.ps1` 用 `$script:ClaudeBlockedSwitches` 预防性过滤，并在启动失败时以
   `Find-BlockedSwitch` 探测 + 自动重试兜底。新版若扩充黑名单（尤其若触及
   `--proxy-server` 或 `--user-data-dir`），所有实例会同时拒绝启动。
   表现是「双击没反应」，取证看 `launch-audit.log` 的 `DROP` 行与自检输出。
2. **升级后自动重开的窗口不是隔离实例，而且会占用 3p 的数据目录**：`ClaudeSetup.exe`
   安装成功后必定调 `explorer.exe shell:AppsFolder\<AUMID>` 把应用拉起来。该进程不带
   `--user-data-dir`、不带 `--proxy-server`、不带 `NODE_OPTIONS`。Electron 的默认
   `userData` 恰好解析到 `%LOCALAPPDATA%\Claude-3p`——**正是 `instances.json` 里 `3p`
   实例使用的目录**。所以它不是一个无害的空白profile，而是**用 3p 的登录态裸跑**。
   **配置没有被改，是进程不是由 launcher 拉起的**，但风控效果等价于隔离失效。
   引导器没有 `--no-launch` 之类开关（5.1231.2 二进制字符串核实：只有 `--msix`、
   `--msix-path`、`--exe`、`--all-users`、`--lang`、`--log-path`、`--uninstall`、
   `--elevated`、`--from-app`），所以只能事后关掉。
   根治方向是把 `3p` 的 `--user-data-dir` 迁出默认路径（需迁移登录态，另行评估）。

## 4. 标准流程

### 4.1 更新前（只读）

```powershell
Get-AppxPackage AnthropicPBC.Claude | Select-Object Name, Version, InstallLocation
.\scripts\check-update-guard.ps1
```

记录：包版本、三条防火墙规则的 `Program`、各实例 `Data\shield.cjs` 的哈希、
`~/.claude-multi/launch-audit.log` 的尾部。有正在运行的长任务时**先不要升级**
——更新会关闭所有实例。

### 4.2 更新

通过 Microsoft Store 更新，或应用内 Help → Check for updates。接受它会关闭全部实例。
**不要**在升级完成后直接使用 Windows 自动弹出的窗口。

### 4.3 更新后（按顺序，缺一不可）

1. 确认新包版本与新的 `InstallLocation`，并看 `doctor` 是否打出双标识 `[WARN]`：

   ```powershell
   .\claude-multi.ps1 doctor
   ```

2. **先关掉安装器自启的游离实例**。判据是主进程命令行里**没有** `--proxy-server`：

   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
     Where-Object { $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch '--proxy-server' } |
     ForEach-Object { "STRAY pid=$($_.ProcessId)  $($_.CommandLine)" }
   ```

   逐个 `Stop-Process -Id <pid>`。这一步必须做——它用的是 3p 的登录态且没有代理。

3. **在提权 PowerShell 中**核对/重建防火墙规则：

   ```powershell
   .\claude-multi.ps1 udp-guard
   ```

   三条规则会分别对齐到新 `Claude.exe` 路径。不加 `-Id` 即覆盖所有带 `proxy` 的实例。
   注意：2026-11-11 这次实测中，规则在 MSIX 完成服务后**已经被系统自动改指到新路径**
   （注册表 `App=` 字段确认为新版），但这属于无法保证的行为——`Manual` 策略存储、
   `Package` 字段为空，纯路径匹配。**仍然每次都要跑这一步确认。**
4. 用 launcher 逐个重拉实例，**不要**用开始菜单 / 任务栏 / 自动弹出的窗口：

   ```powershell
   .\claude-multi.ps1 restart -Id official
   .\claude-multi.ps1 restart -Id official2
   .\claude-multi.ps1 restart -Id official3
   ```

   重启时 `Write-ShieldScript` 会用 `Core.ps1` 内的模板重写各实例的 `shield.cjs`，
   因此模板与运行副本天然同步；若手工改过任一副本，重启后会被模板覆盖。
5. 运行只读检查，要求全部 `[OK]`：

   ```powershell
   .\scripts\check-update-guard.ps1
   ```

### 4.4 验收清单

- [ ] 每个主进程命令行含正确的 `--proxy-server`（端口与 `instances.json` 一致）；
- [ ] 三条防火墙规则 `Enabled=True` 且 `Program` 指向**新版本**的 `Claude.exe`；
- [ ] 各实例 `Data\shield.cjs` 存在，且探针超时与 `Core.ps1` 模板一致；
- [ ] `launch-audit.log` 无新增 `GUARD` / `DROP` 记录；
- [ ] 每个实例的出口 IP 复核与台账一致（`.\claude-multi.ps1 check -Id <id>`）；
- [ ] 无「不带 `--user-data-dir`」的游离主进程。

任一项不通过，按「受阻」处理，不要宣称升级完成。

## 5. 不升级

应用内「需要最新版桌面端」类横幅是**特性门槛提示**，不是错误、不是网络故障、
不是账号状态信号。关闭横幅即可继续在旧版本上工作，除非确实需要该版本才提供的新模型
或能力。是否升级由人决定，本仓库不自动触发。
