# DSH-m

从 iPhone 远程接入 Mac 上的 [DeepSeek Harness](https://deepseek.com) 桌面。

DSH-m 通过自托管、TLS 证书钉扎的桥接，把 iPhone App **DSH-m** 连接到 Mac 上的 DSH 桌面。你可以在手机上浏览工作区与会话、阅读实时数据流、处理审批与用户提问、接收推送通知，并远程切换会话的权限预设 —— 无论身处同一局域网，还是通过自己在公网部署的 relay。

## 状态

当前版本 **v2.17.0**（2026-10-27）。已交付的能力：

**导航**

- **iOS 原生导航**：会话页的进入/返回走系统导航栈（`NavigationStack`，底层 `UINavigationController`）——左缘滑动返回与推入/弹出转场均为 Apple 官方动效；返回即时恢复常驻的工作区列表（无重建卡顿）；子代理详情返回直接显示活的父会话。
- 消息列表滚动中也能稳定触发左缘返回（手势仲裁对齐系统原生行为）。
- 历史加载期间页面保持可交互：顶部加载进度条走动时也能自由上下滑动、随时返回，不用等加载结束。

**连接与配对**

- 任意网络扫码配对：同一 Wi-Fi 自动走最快的局域网直连，直连不通或在移动网络下自动走中继（8 位配对码 / 二维码 / 自动配对 payload），带吊销能力的设备注册表。
- 配对体验：桌面二维码可点击放大、不会过期失效；扫码失败可直接重扫，失败提示一句话可操作。
- 配对一次即可长期使用：手机以插件自签 CA 证书为信任锚，插件升级、证书重签（局域网 IP 变化 / 到期续期 / 手动轮换）、桌面端重启、切换网络都不需要重新配对；只有主动吊销设备或显式轮换 CA 才需要。
- 连接稳定：首次启动链路就绪即进入；断线自动恢复（单 WSS 传输与断线恢复 `dsh-m/2`、按 origin 复用的 keep-alive 连接池）；待处理卡片在重连时不清空，重连后按事件 ID 幂等重投。
- 公网访问：在桌面设置页一键部署自托管 relay，部署后进程内激活隧道（无需重载插件）。
- 网络自适应：配对与连接都自动按当前网络选路径（直连优先、2 秒不通切中继）；连接成功后自动学习 Mac 的最新端点；网络环境变化（Wi-Fi / 蜂窝 / 热点 / Mac 局域网 IP 变更）时自动换路并即时重拨，Wi-Fi↔蜂窝双向切换约 1 秒内恢复连接；同一 Wi-Fi 下冷启动约 1.6s 连上。

**会话与交互**

- 工作区 / 会话浏览与实时流；会话列表轻量投影，首屏更快。
- 会话卡片左滑快捷操作：置顶、归档（归档带二次确认弹窗；按钮为纯图标，紧凑不占宽）。
- 会话状态一眼看清：列表卡片状态行与详情右上角用同一套状态图标（等待审批 / 等待作答 / 进行中 / 出错 / 未开始 / 空闲 / 离线），等待类状态轻轻呼吸；某一轮开始或结束，列表卡片立刻变化并自动置顶，不需要下拉刷新。
- 分组「+」一键新建会话并直达；未发送输入自动存草稿，回到该工作区继续；新建的草稿会话固定排在列表顶部，创建后立刻可见（与桌面端一致）；新建空白会话布局与有消息会话一致。
- 顶栏品牌与版本信息重排：版本号下沉第二行，两行与 logo 等高。
- 会话详情为一条平铺消息流（对齐 DSH 桌面端）：无 turn 卡片与按轮折叠；推理与工具调用按「过程组」平铺展开——组头显示「N 步 · 运行中 / 已完成」，点一下收起整组，收起/展开时组头停在原位不动；模型思考时思考内容在组内逐字增长（点开可看全文），工具尚未开始先显示「准备运行命令…」；文件变更卡在流尾；每行独立懒加载，下拉加载的新消息立即可见；消息区采用系统级循环复用列表，几千条消息的超长会话也能流畅快速滚动——历史加载进行中快速滑动几乎不掉帧，超长消息整条一次成型，巨型过程组（上百步）展开收起同样顺滑。
- 子代理与工具调用视图；子代理入口常驻数量，只有真实运行中才播放边框流光，运行期间新启动的子代理即时计入。
- 审批与用户提问：底部交互面板强制作答，可向下折叠查看会话输出，右上角状态图标指示这一刻的会话状态（等待审批 / 等待作答 / 进行中 / 出错 / 未开始 / 空闲 / 离线），等待审批或作答时可重新展开底部面板；多题问答一题一页（上一题 / 下一题、进度、单选自动前进、返回保留草稿、跳过与提交校验）；支持锁屏推送直接处理。
- 统一底部弹层（模型 / 权限 / 子代理 / 文件变更 / 思考 / 工具详情）：从屏幕底部全宽弹出、高度随内容自适应并含底部安全区，按住顶部触摸条下滑即可收起。
- 手机上切换会话权限预设（只读 ↔ 工作区可写 ↔ 完全访问）。
- 手机上切换会话的模型与推理等级（下一次请求生效）；面板只列出桌面端真实可切换的模型；桌面端切换模型后手机端会话页实时跟随，无需重新进入会话。
- 状态行与上下文窗口：会话权限 → 上下文容量 · 已用百分比（如 `1M · 53%`，四档颜色）→ 模型切换 → 子代理。

不包含：P2P 直连。公网访问依赖你自己部署的 relay。各版本的变更记录见 [release notes](docs/release-notes/)。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `packages/dsh-m-link/` | macOS DSH 插件：3466 端口上的 TLS 桥接、配对、设备认证、透明远程桥接、APNs 发送、relay 部署引擎、桌面设置页 |
| `packages/dsh-m-relay/` | 用于公网访问的轻量 Go relay（控制通道 + bridge 端口段） |
| `apps/ios/` | SwiftUI iPhone App（`DSHm`）、单元测试、XcodeGen 工程描述 |

## 环境要求

| 组件 | 要求 |
|---|---|
| macOS | 桌面 DSH App（插件加载到它的 `desktop` profile） |
| Node.js | ≥ 22（插件运行时与插件测试套件） |
| Xcode | Xcode 16+，以及用于真机构建的 Apple Developer team |
| XcodeGen | `brew install xcodegen`（`.xcodeproj` 由 `apps/ios/project.yml` 生成） |
| Go | 1.26+ —— 仅在你自行构建 relay 时需要 |
| iPhone | iOS 17+ |

## 快速开始

1. **安装插件**到 DSH 的 `desktop` profile —— 可以按 bundle 安装
   （`dsh plugin --profile desktop add file:/path/to/dsh-m/packages/dsh-m-link`），
   也可以使用 symlink + profile patch。配置模板见
   [`config.example.yml`](packages/dsh-m-link/config.example.yml)。
2. **完全重启 DSH 桌面 App**（不是刷新页面）。
3. **构建并安装 iOS App**（见下），然后打开。
4. 在 Mac 上打开 **设置 → DSH-m 手机连接**，在 App 中输入 8 位配对码（或扫描二维码）。
   两台设备需在同一网络 —— 或已部署 relay。
5. 可选，用于离家访问：在同一设置页使用 **远程 relay（自托管服务器）**，
   把 relay 部署到你自己的 Linux 主机。

## 构建 iOS App

```sh
brew install xcodegen
cd apps/ios
xcodegen generate
open DSHm.xcodeproj
```

在 Xcode 的 *Signing & Capabilities* 中选择你的签名 team，然后在 iPhone 上运行。模拟器也可以运行（无需签名）。

App 图标已包含在工程中：`apps/ios/DSHm/Resources/Assets.xcassets/AppIcon.appiconset/`
（重新生成方式：`apps/ios/Design/AppIcon/generate.py`）。
每次构建都会自动带上图标，无需额外的 Xcode 步骤。

单元测试（模拟器）：

```sh
cd apps/ios
xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project DSHm.xcodeproj -scheme DSHm \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:DSHmTests -derivedDataPath /tmp/dshm-verify-dd \
  CODE_SIGNING_ALLOWED=NO
```

## 插件测试

插件测试套件离线运行，不会触碰正在运行的插件实例（11 个套件，共 195 项检查）：

```sh
cd packages/dsh-m-link
node test/apns-payload-shape.mjs    # 11 项：APNs payload 形状
node test/m4-notify.mjs             # 13 项：通知管线
node test/m2-transport.mjs          #  8 项：传输分帧
node test/m2-paircode.mjs           # 18 项：配对码 + Bonjour
node test/m2-tunnel.mjs --skip-real-relay  # 23 项：隧道客户端
node test/m2b-deploy.mjs            # 36 项：一键部署引擎
node test/p1-mux-rpc.mjs            # 26 项：单 WSS mux RPC
node test/p1-single-wss.mjs         #  6 项：单 WSS 传输
node test/p1-tickets.mjs            #  9 项：attach ticket
node test/p1-lite-list.mjs          # 14 项：轻量会话列表
node test/session-permission.mjs    # 31 项：权限切换
```

## 构建 relay（可选）

Relay 二进制是**构建产物，不纳入仓库**。构建时会同时重新生成部署引擎用于校验的 manifest：

```sh
bash packages/dsh-m-relay/scripts/build-release.sh   # linux-amd64 + linux-arm64
```

然后通过桌面 UI / CLI 部署，或用
`packages/dsh-m-relay/deploy/install.sh` 手工安装。

## 安全说明

- 配对后的手机对你的 Mac 拥有**等同 owner 的控制权**（可在会话中执行工具）。请把任何已配对设备视为受信设备；手机丢失后，立即在 *设置 → DSH-m 手机连接 → 已配对设备* 中吊销。
- 优先使用局域网或你自建的 relay。生产 profile 中保持 `debug.enabled` 关闭；不要提交 APNs 密钥（`.p8`）、隧道密钥或配对 payload —— 仓库自带的 `.gitignore` 已覆盖这些文件。
- 手机以插件自签 CA 证书为信任锚（配对时固定），并校验服务端证书链与有效期；每台配对设备拥有独立密钥；已吊销设备会被以 `auth/revoked` 拒绝。

## 许可

[MIT](LICENSE)

---

# English

# DSH-m

Remote access to your [DeepSeek Harness](https://deepseek.com) desktop from an iPhone.

DSH-m connects the iOS app **DSH-m** to your Mac's DSH desktop through a self-hosted, TLS-pinned bridge. Browse workspaces and sessions, read live streams, answer approvals and user questions, receive push notifications, and switch a session's permission preset remotely — from your LAN or through your own relay on the public internet.

## Status

Current version **v2.17.0** (2026-10-27). What ships today:

**Connection and pairing**

- LAN pairing (8-digit code / QR / automatic pairing payload) with a device registry that supports revocation.
- Pair once and keep working: the phone anchors trust on the plugin's self-signed CA certificate, so plugin upgrades, certificate re-issues (LAN IP changes / expiry renewal / manual rotation), desktop restarts and network changes no longer require re-pairing; only revoking the device or explicitly rotating the CA does.
- Reliable connection: the app enters as soon as the link is ready on first launch; automatic recovery after disconnects (single-WSS transport with resume `dsh-m/2`, per-origin keep-alive connection pooling); pending cards are not cleared on reconnect and are re-delivered idempotently by event ID.
- Public access: deploy a self-hosted relay with one click from the desktop settings page; the tunnel activates in-process (no plugin reload).
- Network-aware: after every successful connect the app learns the Mac's current endpoints; when the network environment changes (Wi-Fi / cellular / hotspot / Mac LAN IP change) it automatically picks the fastest reachable path and redials immediately — switching between Wi-Fi and cellular recovers the connection in about a second, and a same-Wi-Fi cold start connects in about 1.6s.

**Sessions and interaction**

- Workspace / session browsing with live streams; a lite session-list projection makes the first screen faster.
- Swipe a session card left to pin or archive it (archiving confirms first; the actions are icon-only, so they stay compact).
- Session status at a glance: the list's status line and the detail header share one icon set (waiting for approval / waiting for an answer / running / error / not started / idle / offline), and waiting states breathe gently. When a turn starts or ends, the list card changes immediately and moves to the top — no pull-to-refresh needed.
- The「+」on a group header creates a new session and jumps straight in; unsent input is kept as a draft, and a newly created draft session stays at the top of the list (matching the desktop app). A brand-new empty session lays out like one with messages.
- Header redesign: the version number sits on a second line level with the logo.
- The session detail is a single flat message stream (matching the DSH desktop app): no turn cards or per-turn folding; reasoning and tool calls lay out flat inside process groups — the group header shows "N steps · running / done", one tap collapses the group, and collapsing or expanding keeps the header exactly in place. While the model thinks, the thinking text grows word by word inside the group (tap to read it all), and a tool that has not started yet shows "Preparing to run command…". The file-changes card sits at the end of the stream, and every row lazy-loads on its own, so long sessions stay smooth and newly paged-in messages appear immediately.
- Subagent and tool-call views; the subagent entry keeps a persistent count, plays the border beam only while subagents are actually running, and counts subagents started while the session is open immediately.
- Approvals and user questions: the bottom interaction panel makes answering mandatory, folds down so you can read the conversation output, and the top-right status icon shows this moment's session state (waiting for approval / waiting for an answer / running / error / not started / idle / offline) while a waiting state re-opens it; multi-question prompts page one question at a time (previous / next, progress, auto-advance for single-select, drafts preserved, skip / submit validation); lock-screen push actions are supported.
- Unified bottom popups (models / permissions / subagents / file changes / reasoning / tool details): full-width sheets rise from the screen edge, size themselves to their content plus the bottom safe area, and dismiss by dragging the top grabber down.
- Phone-switchable session permission presets (read-only ↔ workspace-write ↔ full access).
- Phone-switchable model and reasoning effort for a session (applies from the next request); the panel lists only models the desktop can actually switch to, and model switches made on the desktop are reflected in the app in real time without reopening the session.
- Status row and context window: session permission → context capacity · used percentage (for example `1M · 53%`, four colour bands) → model switch → subagents.

Not included: peer-to-peer (P2P) connectivity. Public access relies on a relay you deploy yourself. Per-release changes are documented in the [release notes](docs/release-notes/).

## Repository layout

| Path | What it is |
|---|---|
| `packages/dsh-m-link/` | macOS DSH plugin: TLS bridge on port 3466, pairing, device auth, transparent remote bridge, APNs sender, relay deploy engine, desktop settings page |
| `packages/dsh-m-relay/` | Small Go relay for public-network access (control channel + bridge port range) |
| `apps/ios/` | SwiftUI iPhone app (`DSHm`), unit tests, XcodeGen project spec |

## Requirements

| Component | Requirement |
|---|---|
| macOS | Desktop DSH app (the plugin is loaded into its `desktop` profile) |
| Node.js | ≥ 22 (plugin runtime and plugin test suites) |
| Xcode | Xcode 16+, plus an Apple Developer team for real-device builds |
| XcodeGen | `brew install xcodegen` (the `.xcodeproj` is generated from `apps/ios/project.yml`) |
| Go | 1.26+ — only if you build the relay yourself |
| iPhone | iOS 17+ |

## Quick start

1. **Install the plugin** into your DSH `desktop` profile — either as a bundle
   (`dsh plugin --profile desktop add file:/path/to/dsh-m/packages/dsh-m-link`)
   or with a symlink + profile patch. The config template is
   [`config.example.yml`](packages/dsh-m-link/config.example.yml).
2. **Restart the DSH desktop app completely** (not a page reload).
3. **Build and install the iOS app** (below), then open it.
4. On the Mac: **Settings → DSH-m phone connection**, enter the 8-digit pairing
   code in the app (or scan the QR code). Both devices must be on the same
   network — or a relay must already be deployed.
5. Optional, for access away from home: use **Remote relay (self-hosted server)**
   in the same settings page to deploy the relay to a Linux host you own.

## Build the iOS app

```sh
brew install xcodegen
cd apps/ios
xcodegen generate
open DSHm.xcodeproj
```

Select your signing team in Xcode's *Signing & Capabilities*, then run on your
iPhone. The simulator works too (no signing required).

The app icon is part of the project: `apps/ios/DSHm/Resources/Assets.xcassets/AppIcon.appiconset/`
(regeneration: `apps/ios/Design/AppIcon/generate.py`).
Every build ships it — no extra Xcode step.

Unit tests (simulator):

```sh
cd apps/ios
xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project DSHm.xcodeproj -scheme DSHm \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:DSHmTests -derivedDataPath /tmp/dshm-verify-dd \
  CODE_SIGNING_ALLOWED=NO
```

## Plugin tests

The plugin test suites run offline and never touch the live plugin instance
(11 suites, 195 checks in total):

```sh
cd packages/dsh-m-link
node test/apns-payload-shape.mjs    # 11 checks: APNs payload shape
node test/m4-notify.mjs             # 13 checks: notification pipeline
node test/m2-transport.mjs          #  8 checks: transport framing
node test/m2-paircode.mjs           # 18 checks: pairing code + Bonjour
node test/m2-tunnel.mjs --skip-real-relay  # 23 checks: tunnel client
node test/m2b-deploy.mjs            # 36 checks: one-click deploy engine
node test/p1-mux-rpc.mjs            # 26 checks: single-WSS mux RPC
node test/p1-single-wss.mjs         #  6 checks: single-WSS transport
node test/p1-tickets.mjs            #  9 checks: attach tickets
node test/p1-lite-list.mjs          # 14 checks: lite session list
node test/session-permission.mjs    # 31 checks: permission switching
```

## Build the relay (optional)

Relay binaries are **build outputs and are not committed**. Building them also
regenerates the manifest the deploy engine verifies:

```sh
bash packages/dsh-m-relay/scripts/build-release.sh   # linux-amd64 + linux-arm64
```

Then deploy it with the desktop UI / CLI, or install manually with `packages/dsh-m-relay/deploy/install.sh`.

## Security notes

- A paired phone has **owner-equivalent control of your Mac** (it can run tools
  in your sessions). Treat any paired device as trusted; revoke a lost phone
  immediately in *Settings → DSH-m phone connection → Paired devices*.
- Prefer LAN or a relay you control. Keep `debug.enabled` off in production
  profiles; never commit APNs keys (`.p8`), tunnel secrets or pairing payloads —
  the shipped `.gitignore` covers these.
- The phone anchors trust on the plugin's self-signed CA certificate (pinned at
  pairing time) and validates the server certificate chain and validity period;
  each paired device has its own key; revoked devices are rejected with
  `auth/revoked`.

## License

[MIT](LICENSE)
