<p align="center">
  <img src="assets/claude-violet.png" width="128" alt="Claude 紫色多开图标" />
</p>

# Claude Desktop 多开:多个窗口同时用不同 API(多 API 同时工作)

[English](README.md) · **简体中文**

**Claude Desktop 多开,多个窗口同时使用不同 API。** 一个窗口保持**官方订阅**,其余窗口想开几个开几个,分别走**自定义 / 第三方 API**(由 [cc-switch](https://github.com/farion1231/cc-switch) 驱动)。Claude Desktop 多 API、多窗口、多账号同时工作——支持 **Windows**(已实测)和 **macOS**(实验性)。

每个窗口都有独立的数据、独立的**配色图标**(桌面、任务栏、系统托盘)、独立的任务栏按钮,还可以各用各的 API。第三方默认配色是官方图标的**紫黑底 + 白色星芒**;也可选 Gemini、GPT、Perplexity、DeepSeek、WorkBuddy 配色,或任意 `#RRGGBB`。

> 非官方社区工具,与 Anthropic、cc-switch 无任何关联。图标由你本机已安装的应用图标**在本地生成**,仓库里不含 Anthropic 的任何图片素材。

## 功能

* **官方订阅与第三方 API 同时运行。** 官方窗口保持订阅登录;其他窗口走 cc-switch 指向的 API。
* **每个窗口一个不同的 API。** 为每个窗口选 cc-switch 供应商(直连该供应商上游),或让窗口*跟随* cc-switch 当前选择。
* **窗口数量不限**,配一个 Anthropic 风格的小界面(默认英文,内置中文切换)。
* **图标处处独立:** 桌面快捷方式、任务栏按钮、窗口图标、**系统托盘图标与提示文字**。
* **会话共享:** 新会话、标题、固定/星标会话、固定顺序、MCP 服务器会在窗口间镜像;空闲的后台窗口会静默重启以载入。
* **`claude://` 链接**打开到你最近使用的窗口(或固定某一个)。
* **同一会话在两个窗口同时发消息?** 在两份记录分叉之前,Windows 会弹通知提醒你。
* **更新无忧:** Windows 上不拷贝、不修改应用,每次启动都从商店包解析安装路径。

## Windows 快速开始

环境:Windows 11(10 理论可用)、PowerShell 5.1+、通过 Microsoft Store 安装的 Claude Desktop(`AnthropicPBC.Claude`)、带 *Claude Desktop* 供应商的 [cc-switch](https://github.com/farion1231/cc-switch)。

```powershell
git clone https://github.com/TonF1917/claude-desktop-multiple-windows-different-api
cd claude-desktop-multiple-windows-different-api
.\claude-multi.ps1 install        # 为 instances.json 里的每个窗口生成图标和快捷方式
.\claude-multi.ps1 gui            # 或用桌面上的快捷方式 “Claude Multi Manager”
```

然后在桌面上对每个新快捷方式右键 →「固定到任务栏」(Windows 不允许脚本代为固定)。

| 命令 | 作用 |
|---|---|
| `gui` | 管理界面 |
| `add -Id off2 -Name "Claude Official 2" -Kind official -Palette perplexity [-Proxy <url>] [-Timezone <tz>]` | 增加次级官方直连窗口(支持独立配色、代理分流与进程时区隔离) |
| `add -Id gem -Name "Claude Gemini" -Palette gemini [-Provider <id>] [-Proxy <url>] [-Timezone <tz>]` | 增加第三方窗口(配色可用名称或 `"#E11D48"`) |
| `init [-Id <id>]` (别名 `setup`) | 一键物理构建/修复实例环境(建立独立Data目录、镜像MCP配置、挂载会话软链接、生成专属配色图标与快捷方式) |
| `check [-Id <id>]` (别名 `test-ip`) | 一键全量审计各实例出口IP、家宽/机房属性、欺诈分(0-100)、Claude官方区域支持状态与时区吻合度 |
| `install [-Force]` | 重新生成图标和快捷方式;并改接你已固定的 Claude 快捷方式 |
| `launch -Id gem` | 启动某个窗口 |
| `list`、`providers`、`sync`、`remove -Id gem`、`icons -Force`、`uninstall` | 日常维护 |

## macOS(实验性,v1.1.0)

macOS 版在 [`macos/`](macos) 目录(Python 3,仅用标准库),现已对齐 Windows 版功能:多官方窗口、每窗口独立的 `kind` / `proxy` / `timezone`、`init` / `check`,以及覆盖全部选项的图形界面。

> **如实说明:** 它是**在没有 Mac 的条件下写成的**。配置读写、配色、代理/时区/启动参数的生成、凭据脱敏、出口检测(用模拟应答)、`init` 的文件准备和图形界面已在 Windows 上跑通;只能在 macOS 上执行的步骤——克隆 `Claude.app`(`cp -c`)、`sips` / `iconutil` 重绘图标、ad-hoc `codesign`、直接启动克隆体二进制、用 `ps` 识别进程——是按这些工具的文档行为编写的,**从未在真机上运行过**。可能有粗糙之处,欢迎带着终端输出反馈。

**获取:** 下载 `ClaudeMulti-macOS-vX.Y.Z.zip`(由 `macos/build_release.sh` 生成),解压后双击 `Claude Multi.command`(首次请右键 -> 打开);或在克隆的仓库里:

```bash
python3 macos/claude_multi.py gui
python3 macos/claude_multi.py add --id off2 --kind official --palette perplexity --proxy http://127.0.0.1:7890 --timezone America/Toronto
python3 macos/claude_multi.py add --id gem --name "Claude Gemini" --palette gemini [--provider <cc-switch id>]
python3 macos/claude_multi.py init [--id off2]    # 数据目录、MCP 配置链接、会话链接、带配色图标的 Claude.app 克隆(~/Applications/Claude Multi)
python3 macos/claude_multi.py check [--id off2]   # 出口 IP、家宽/机房、风险分、区域、时区吻合度
python3 macos/claude_multi.py launch --id off2    # 另有:stop、restart、list、remove、install、uninstall、sync、providers
python3 macos/claude_multi.py agent &             # 会话镜像 + 后台静默刷新
```

| 命令 | 作用 |
|---|---|
| `add --id --name --kind official/3p --palette --proxy --timezone [--provider] [--lang] [--no-init]` | 添加窗口(`3p` 与 Windows 一样存为 `cc-switch`) |
| `init` / `setup` `[--id]` `[--force]` | 准备数据目录;镜像 `claude_desktop_config.json`(优先符号链接,其次硬链接,最后复制);链接 `claude-code-sessions` / `local-agent-mode-sessions`;生成带配色图标的克隆体。可重复执行 |
| `check` / `test-ip` `[--id]` | 经该窗口代理查询出口 IP(仅 HTTP/HTTPS 代理,标准库 `urllib` 不支持 SOCKS)、IP 类型、风险分、Claude 区域、时区吻合度 |
| `launch` / `stop` / `restart` `--id` | 运行窗口(见下) |
| `list`、`remove --id`、`uninstall`、`install [--force]`、`sync`、`providers`、`agent`、`gui` | 日常维护 |

**macOS 上启动时做了什么。** 直接执行窗口自己的二进制(主官方窗口用原版 `Claude.app`,其余窗口用各自的配色克隆体),环境变量才能真正传到进程里:

* 由窗口的 `proxy` 注入 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`(含小写),并设 `NO_PROXY=localhost,127.0.0.1,::1`,保证本机 cc-switch 网关仍可直连。默认**不**加 `--proxy-server`(在窗口上设 `"proxyServerFlag": true` 才加)。macOS 上 Chromium 不一定遵守这些变量,请先用 `check` 和泄漏测试验证,再把账号交给它。
* 仅对该进程设 `TZ=<时区>`,并按时区推导 `--lang=<语言区域>`(可用 `"lang"` 覆盖)。
* `--webrtc-ip-handling-policy=disable_non_proxied_udp`;除主官方窗口外都带 `--user-data-dir=~/.claude-multi/<id>/Claude`。
* 次级官方窗口(`--kind official` 且 id 不是 `official`)使用独立数据目录,每次启动前删除其中的 `configLibrary`,并且不会创建同级 `Claude-3p`,因此始终是纯 1P,不会读到 cc-switch 配置。
* 代理账号密码在 `list`、图形界面、报错、输出面板和 `~/.claude-multi/claude-multi.log` 中一律脱敏(`http://***@host:port`);`instances.json` 和子进程环境里仍是明文。

**限制 / 未移植:** 固定与 MCP 服务器同步、`claude://` 路由、托盘图标。主官方窗口无法像 Windows 那样与 cc-switch 隔离(macOS 没有可重定向的 `LOCALAPPDATA`):cc-switch 应用了第三方配置时启动它,可能被切成第三方模式。Xcode 自带的 `python3` 可能带旧版 Tk;`gui` 打不开时请安装 python.org 的 Python,或直接用命令行。

## 多官方账号支持与防风控隔离 (Anti-Ban & Multi-Official)

不仅支持 1 个官方 + N 个第三方，现已全面支持**任意多个官方订阅账号（1P）与第三方账号（3P）并排同时运行**：

1. **多官方账号纯净直连**：主官方实例占用系统默认家目录；次级官方实例（如 `official2`）拥有专属虚拟数据目录与独立的私有 `LOCALAPPDATA`，彻底剔除 `configLibrary` 判定，保证 100% 进入纯官方 1P 直连模式，互不顶号。
2. **独立网络与代理分流 (`-Proxy`)**：绕过客户端严禁 `--proxy-server` 命令行参数的封锁限制，在子进程级动态注入 `$env:HTTPS_PROXY`，为每个官方账号分配独立的住宅代理出口，杜绝多账号同 IP 关联连坐。
3. **进程级时区对齐 (`-Timezone`)**：子进程独立注入 `$env:TZ`（如 `America/Toronto`、`Asia/Jakarta`），使 Electron / V8 渲染层的 JavaScript 时区与出口 IP 物理归属地 100% 吻合，且**绝不修改 Windows 全局系统时区**，消除“IP 与时区跨区冲突”的致命风控特征。
4. **一键物理构建与环境审计 (`init` & `check`)**：
   - `.\claude-multi.ps1 init [-Id <id>]`：一键自动创建 Data 目录、镜像 MCP 工具链 (`claude_desktop_config.json`)、建立会话软链接 (`claude-code-sessions`) 并生成着色图标与快捷方式。
   - `.\claude-multi.ps1 check [-Id <id>]`：一键全量审计所有实例的出口 IP、住宅/机房属性、欺诈分 (0-100)、Claude 官方支持状态与时区吻合度。

## 配合 cc-switch 使用

在 cc-switch 里为 Claude Desktop 选择第三方供应商(不要选「官方」)。cc-switch 会在 `127.0.0.1:15721` 启动网关,并把配置写入共用的 3P 配置目录。**跟随**的窗口走这个网关和 cc-switch *当前选中*的供应商。选了**具体供应商**的窗口,会用该供应商自己的 base URL、密钥、模型映射生成配置,直连其上游(仅限 Anthropic 格式供应商;模型名使用上游真实 id)。两个窗口就这样在同一时刻用两个不同的 API。也可以为某个窗口手写配置:`"profile": "路径\\profile.json"`(见 `examples/profile.example.json`)。

cc-switch 选「官方」时,第三方窗口没有配置,会显示普通登录界面。

## 窗口之间同步什么

| 项目 | 是否同步 | 在另一窗口出现的方式 |
|---|---|---|
| 会话(新会话、标题、归档状态) | 是 | 文件数秒内镜像;对方窗口在后台静默重启后载入 |
| 固定(置顶)/星标会话及其顺序 | 是 | 每个会话里的 `isStarred` 标记,以及 `claude_desktop_config.json` 里的 `starred-*`、`pinnedOrder`;只在窗口关闭时(或后台重启前)写入,避免被应用覆盖 |
| MCP 服务器 | 是 | 同一机制(`mcpServers`);可在界面关闭 |
| 对话记录 | 是(天然共享) | 存放在 `~\.claude\projects`,所有窗口共用 |
| 登录、供应商、模型列表、窗口大小位置 | 否 | 有意保持各窗口独立 |

**已知限制:固定(Pin)。** 每个 Claude Desktop 都在内存里维护自己的固定列表并自行写回:运行中的窗口在重启前一直显示它自己的固定项;启动中的窗口会裁剪它读到的列表(实测:窗口关闭时写入 17 个固定项,启动后 8 秒内被改回 12 个;被丢掉的是 10 月 12 日 23:50 之后创建的会话外加一个更早的会话——规则在应用内部,不在本工具)。本工具能保证两份配置文件一致,并且不让空的或新的窗口把它们清空,但无法强制两个窗口*显示*相同的固定项。

**为什么不能瞬时同步?** Claude Desktop 确实会读这些文件夹,但只在启动时读,以及登录账号/组织变化时再读。它没有文件监听,改写它的 `config.json` 也不会触发重新读取,正式版还禁用了远程调试,所以应用之外没有任何办法让一个运行中的窗口重新读文件夹。最接近且安全的办法是静默重启:窗口**只有**在不是焦点窗口、最近 45 秒没有写过会话文件、且其代理/工具子进程没有占用 CPU 时,才会在后台重启;重启后的窗口会**以最小化状态回来、不抢焦点**(以 `SW_SHOWMINNOACTIVE` 启动),同步过程不会弹出任何窗口:通知默认关闭,可在管理界面打开。你正在使用的窗口(在前台**且**最近 90 秒内有键鼠输入)绝不会被重启,而是弹出带「Reload now」按钮的 Windows 通知(也可以在管理界面点「重启所选」);你空闲满 90 秒后会自动刷新。各窗口的会话目录可能通过目录联接共用,所以判断是按“每个运行中的窗口是否认识当前存在的所有会话文件”来做的,不依赖复制。官方窗口默认不参与,可在界面勾选「同时对官方窗口启用实时刷新」(官方窗口里可能有未发送的草稿)。

**同一会话在两个窗口同时发送会怎样?** 每个窗口为每个会话各跑一个 Claude Code 进程(`--resume=<id>`)。两边都发送时,它们会往同一份对话记录里写,但各自保留自己的上下文,历史会交错、两个窗口的内容不一致。某会话在两个窗口里同时存活且其中一个正在工作时,后台代理会弹出通知——同一会话请只在一个窗口里活跃。

**不同来源的会话怎么显示?** 每个窗口显示同一份合并后的列表,没有“来自哪个窗口”的角标。会话保留自己的目录、模型和强度;在另一个窗口打开时,它走的是**那个窗口**的登录/供应商(官方窗口走订阅,第三方窗口走所选供应商)。

## 原理(踩坑所得)

1. **所有窗口共用一份配置库。** 应用从 `%LOCALAPPDATA%\Claude-3p` 读 `configLibrary`;cc-switch 把第三方配置写在那里;带 `disableDeploymentModeChooser` 的配置会强制所有读到它的窗口进入 3P 模式——包括官方窗口下次启动时。
2. **Windows 上 `--user-data-dir` 与 `CLAUDE_USER_DATA_DIR` 无效。** 正式版会清除该环境变量,并在 3P 模式下覆盖数据目录,所以第二个 3P 窗口会与第一个冲突并静默退出。
3. **`%LOCALAPPDATA%` 有效。** 3P 数据目录由该变量推导,因此每个额外窗口用各自私有的 `LOCALAPPDATA`(`~\.claude-multi\<id>\Local`)启动,配置也各自独立。
4. **官方隔离。** 官方应用以私有 `LOCALAPPDATA` 启动,其中 `Claude-3p` 为空(`Claude`、`Packages` 是指向真实目录的目录联接),因此永远不会被强制进入 3P。
5. **独立任务栏按钮与托盘图标。** Electron 给所有窗口设置相同的 AppUserModelID。后台代理给每个窗口设置独立 ID 和图标(`SHGetPropertyStoreForWindow`、`WM_SETICON`),并重绘窗口的通知区图标(`Shell_NotifyIcon`、`NIM_MODIFY`);快捷方式也带对应 ID。
6. **图标不能放在 `AppData\*\ClaudeMulti` 下。** 资源管理器和任务栏对这类目录里的 `.ico` 只显示空白页(放在其他任何目录都正常),所以图标生成到 `~\.claude-multi\icons`。
7. **更新无忧。** 每次启动都从 MSIX 包解析安装路径,不拷贝、不修改应用,也不记录版本号。

## 注意

* Windows:官方窗口的隔离要在它**下次重启**时才生效;正在运行的窗口不会被改动。
* 绕过本工具的入口(开始菜单磁贴、别处注册的协议链接)启动官方应用时没有隔离。
* 依赖应用的未公开行为,未来版本可能失效。
* cc-switch 是独立项目。

## 许可证

MIT,见 [LICENSE](LICENSE)。
