import SwiftUI

/// Design token layer.
///
/// Source of truth: <internal-doc> §1 (v5, locked) and
/// design/mockups/v5-field-driven/. All colors / radii / spacing / type ramp live
/// here; components must not hard-code visual constants. Visual change = edit the
/// baseline doc first, then this file only.
enum Theme {

 // MARK: - Color tokens (baseline §1)

    enum Palette {
 /// bg
        static let background = Color(hex: 0x06080D)
 /// surface
        static let surface = Color(hex: 0x0A0F16)
 /// surface-2
        static let surfaceRaised = Color(hex: 0x0C121B)
 /// border
        static let border = Color(hex: 0x1A2230)
 /// border-strong
        static let borderStrong = Color(hex: 0x263241)
 /// The single accent color. Live state + primary CTA only.
        static let accent = Color(hex: 0x22D3EE)
 /// accent-ink — text/icon on top of accent fills.
        static let accentInk = Color(hex: 0x041014)
 /// accent-soft — rgba(34,211,238,.10)
        static let accentSoft = Color(hex: 0x22D3EE).opacity(0.10)
 /// accent-border — rgba(34,211,238,.28)
        static let accentBorder = Color(hex: 0x22D3EE).opacity(0.28)
 /// text
        static let textPrimary = Color(hex: 0xE6EDF7)
 /// text-2
        static let textSecondary = Color(hex: 0x93A1B5)
 /// text-3 (13px auxiliary only; lift to text-2 in implementation where needed)
        static let textTertiary = Color(hex: 0x5F6E84)
 /// warn
        static let warning = Color(hex: 0xFBBF24)
        static let warningMuted = Color(hex: 0xFBBF24).opacity(0.12)
        static let warningBorder = Color(hex: 0xFBBF24).opacity(0.32)
 /// danger
        static let danger = Color(hex: 0xF87171)
        static let dangerMuted = Color(hex: 0xF87171).opacity(0.12)
        static let dangerBorder = Color(hex: 0xF87171).opacity(0.28)
 /// Code / diff blocks reuse surface-2 but a touch darker than cards.
        static let codeBackground = Color(hex: 0x070B11)
 /// Success keeps the single-accent rule: no extra green.
        static let success = Color(hex: 0x22D3EE)
 /// 步骤「成功」圆点绿（v7 task-9 用户口径：成功执行的步骤点必须显示成绿色）。
 /// **例外于单一 accent 基线**（baseline §1：accent 只用于 live/CTA）——用户点名要绿，
 /// 取 GitHub Primer dark 的 fgColor-success #3FB950（与 Theme.Diff.addMark 同源，
 /// 不另造新色）：深底对比度够，且与失败红 #F87171 成对不刺眼。
        static let stepSuccess = Color(hex: 0x3FB950)
 /// 运行中行（实时思考 / 运行中的普通步骤行）共用的浅蓝底 = accent 5%。
 /// 沿用 v6 LiveReasoningStepRow 的既有取值（用户点名「那个浅蓝色非常好看」），
 /// 抽成 token 后由两处共用同一份透明度，避免各自写 opacity 漂移。
        static let liveStepFill = Color(hex: 0x22D3EE).opacity(0.05)

 // MARK: desktop parity — Markdown 行内代码 / 围栏代码块（v7 task-6）
 //
 // 取值来自桌面端 app.asar 解包核对（dark theme）：
 // · CSS：@deepseek-ai/dsh-web-frontend/dist/assets/index-*.css
 // `._markdown_1ypvv_5:not(pre)>code`（行内代码）与 `._block_7gxqk_4`（围栏块）；
 // · 变量值：@deepseek-ai/dsh-client-ui-theme/lib/client.js 的
 // `body[data-ds-dark-theme]` 段。
 /// 行内代码 chip 底色 = --dsw-alias-markdown-inline-code（dark: neutral-800 #292929）。
        static let inlineCodeBackground = Color(hex: 0x292929)
 /// 行内代码 chip 描边 = --dsw-alias-border-l1（dark: #ffffff0f，白 6%）。
        static let inlineCodeBorder = Color.white.opacity(0.06)
 /// 行内代码 chip 文字色 = --dsw-alias-label-primary（dark: neutral-bluish-50 #f9fafb）。
 /// 桌面端行内代码文字不染色（旧实现用 accent，v7 task-6/7 改）。
        static let inlineCodeText = Color(hex: 0xF9FAFB)
 /// 围栏代码块底色 = --dsw-alias-markdown-code-block（dark: neutral-bluish-900 #1b1b1c）。
        static let codeBlockBackground = Color(hex: 0x1B1B1C)
 /// 围栏代码块信息栏（语言标签行）底色 =
 /// --dsw-alias-markdown-code-block-banner（dark: neutral-bluish-850 #2c2c2e）。
        static let codeBlockBanner = Color(hex: 0x2C2C2E)
    }

 // MARK: - GitHub diff palette (task-2: unified diff rendering)

 /// GitHub Primer **dark** diff palette, used only by the file-change detail
 /// sheet's unified diff. Source: GitHub Primer primitives as shipped by the
 /// GitHub dark theme (color-canvas-default / color-canvas-subtle /
 /// color-border-default / fgColor-default / fgColor-muted and the
 /// color-diff-blob-* diff tokens):
 ///
 /// canvas #0d1117 · surface + hunk #161b22 · border #30363d
 /// text #e6edf3 · muted #8b949e
 /// added line rgba(46,160,67,.15) · added gutter rgba(46,160,67,.35) · + #3fb950
 /// removed line rgba(248,81,73,.10) · removed gutter rgba(248,81,73,.20) · - #f85149
 ///
 /// Rows are 22pt tall with 11-12pt mono (see Typography.diffLine).
    enum Diff {
 /// canvas-default
        static let canvas = Color(hex: 0x0D1117)
 /// canvas-subtle: file header + hunk header
        static let surface = Color(hex: 0x161B22)
 /// border-default
        static let border = Color(hex: 0x30363D)
 /// fgColor-default (diff code)
        static let text = Color(hex: 0xE6EDF3)
 /// fgColor-muted (line numbers, hunk header text)
        static let muted = Color(hex: 0x8B949E)
 /// diff-blob-addition-line-bg — rgba(46,160,67,.15)
        static let addedLine = Color(hex: 0x2EA043).opacity(0.15)
 /// diff-blob-addition-num-bg — rgba(46,160,67,.35)
        static let addedGutter = Color(hex: 0x2EA043).opacity(0.35)
 /// fgColor-success (the "+" marker / +N counter)
        static let addMark = Color(hex: 0x3FB950)
 /// diff-blob-deletion-line-bg — rgba(248,81,73,.10)
        static let removedLine = Color(hex: 0xF85149).opacity(0.10)
 /// diff-blob-deletion-num-bg — rgba(248,81,73,.20)
        static let removedGutter = Color(hex: 0xF85149).opacity(0.20)
 /// fgColor-danger (the "-" marker / -N counter)
        static let delMark = Color(hex: 0xF85149)
 /// Hunk header strip (-a,b +c,d).
        static let hunkHeader = Color(hex: 0x161B22)
        static let hunkHeaderText = Color(hex: 0x8B949E)
 /// Row metrics: GitHub mobile diffs use 22pt rows.
        static let lineHeight: CGFloat = 22
 /// Width of one line-number gutter (up to 4 digits at 11pt mono).
        static let gutterWidth: CGFloat = 38
 /// Width of the "+" / "-" marker column.
        static let markerWidth: CGFloat = 14
    }

 // MARK: - Radius tokens

    enum Radius {
        static let xl: CGFloat = 20   // r-xl (sheets, big cards)
        static let lg: CGFloat = 14   // r-md (cards, inputs)
        static let sm: CGFloat = 10   // r-sm (chips, inner blocks)
        static let pill: CGFloat = 999
 /// 行内代码 chip 圆角（桌面 --dsw-radius-sm = 8px；v7 task-6 desktop parity）
        static let inlineCode: CGFloat = 8
 /// 围栏代码块圆角（桌面 --dsw-radius-lg = 16px；v7 task-6 desktop parity）
        static let codeBlock: CGFloat = 16
    }

 // MARK: - 行内代码 chip 度量（v7 task-7 desktop parity）

 /// 桌面端行内代码（实测量自 app.asar CSS）：
 /// font: 12px/19px 等宽；padding 0 5px；border.5px；border-radius 8px（--dsw-radius-sm）。
 /// 桌面 chip 可视高度 = 行高 19px + 边框 1px ≈ 20px，8/20 = 0.4 的圆角/高度比。
 /// app 侧按 pt 1:1 对齐：桌面「行高 19px + 上下边框 1px = 20px 高」，
 /// 我们的描边是内描边（strokeBorder），所以背景框高度取 20pt，
 /// 使 chip 可视高度/圆角 = 8/20 = 0.4，与桌面端同比例。
 /// 圆角用.circular：CSS border-radius 是正圆角，而.continuous 的 squircle
 /// 在同数值下视觉更圆。
    enum MarkdownInlineChip {
        static let horizontalPadding: CGFloat = 5
        static let contentMinHeight: CGFloat = 20
        static let borderWidth: CGFloat = 0.5
    }

 // MARK: - Spacing tokens (4/8/12/16/20/24/32 grid, page inset 20)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
 /// Page horizontal inset per baseline §1.
        static let pageInset: CGFloat = 20
    }

 // MARK: - Size tokens (component heights shared by the composer + status strip)

    enum Size {
 /// Composer input single-line height == send/abort button height (v5.5 §14.1).
        static let control: CGFloat = 44
 /// Fixed height of the grid status strip above the composer (v5.5 §14.6).
        static let statusStrip: CGFloat = 40
    }

 // MARK: - Type ramp (baseline §1: body 14/1.5, title 26/700, card 15/650, min 13)

    enum Typography {
 /// Page title — 26/700.
        static let display = Font.system(size: 26, weight: .bold)
 /// Card / screen section title — 15/650 (semibold is the closest system weight).
        static let cardTitle = Font.system(size: 15, weight: .semibold)
 /// Workspace group name in the list header — 16/600.
        static let workspaceName = Font.system(size: 16, weight: .semibold)
        static let title = Font.system(size: 20, weight: .semibold)
        static let headline = Font.system(size: 15, weight: .semibold)
 /// Body — 14/1.5.
        static let body = Font.system(size: 14, weight: .regular)
        static let bodyMedium = Font.system(size: 14, weight: .medium)
        static let callout = Font.system(size: 13, weight: .regular)
 /// Minimum UI size (13).
        static let caption = Font.system(size: 13, weight: .regular)
        static let captionMedium = Font.system(size: 13, weight: .medium)
        static let label = Font.system(size: 12, weight: .medium)
 /// Mono is used for commands / code / diffs only.
        static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
 /// Version line in the workspace header brand lockup — 11/500 mono
 /// (digits don't jitter). R1 design m1-header.
        static let monoSmallMedium = Font.system(size: 11, weight: .medium, design: .monospaced)
 /// GitHub-style unified diff: 11.5pt mono on a 22pt line (Theme.Diff.lineHeight).
        static let diffLine = Font.system(size: 11.5, weight: .regular, design: .monospaced)
        static let diffGutter = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let button = Font.system(size: 15, weight: .semibold)
    }

 // MARK: - Motion tokens (baseline §1: 160–200ms, cubic-bezier(.2,.8,.2,1))

    enum Motion {
        static let quick = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
        static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
 /// v5.5 §14.3 subagent capsule: one linear turn per 1.2s, forever.
 /// Reduce Motion renders the ring statically instead (BackgroundEntryCapsule).
        static let ringRotation = Animation.linear(duration: 1.2).repeatForever(autoreverses: false)
 /// Workspace folder glyph morph: the front cover swings open/closed and
 /// the tint cross-fades (single icon, both directions;).
        static let folder = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
 /// DEC-07 / DD-17置顶飞行：150ms「轻微回弹」
 /// `cubic-bezier(.34,1.32,.46,1)`。曲线与时长是对外口径（AC-10/AC-12），
 /// 不得替换成其它曲线、也不做可配置项；飞行卡的位移/高度/底色/描边与
 /// 其它行的让位都用这一条曲线。
 ///
 /// 控制点/时长单独暴露：`Animation` 无法反解参数，飞行层逐帧显式插值
 /// （`SessionPinFlightMath.flightProgress(elapsed:)`）必须引用同一份数值，
 /// 否则「同一条曲线」只能靠注释约束。
        static let pinCurve = (x1: 0.34, y1: 1.32, x2: 0.46, y2: 1.0)
        static let pinDuration: TimeInterval = 0.15
        static let pin = Animation.timingCurve(
            pinCurve.x1, pinCurve.y1, pinCurve.x2, pinCurve.y2, duration: pinDuration
        )
    }
}

// MARK: - 步骤行状态视觉（v7 task-9：只用彩色圆点，不出现状态文案）

/// 组内步骤行的状态视觉。用户口径：
/// 步骤行不再显示「成功 / 失败 / 运行中」文案，改成 6pt 圆点——
/// 成功=绿、失败=红、运行中=蓝；运行中的整行复用实时思考行的浅蓝底。
///
/// 颜色一律取 Palette token（stepSuccess / danger / accent / warning），
/// 视图里不硬编码色值；状态文案只剩无障碍用途（VoiceOver 仍需读出结果）。
enum StepStatusTone: Equatable {
    case success
    case failure
    case running
    case pendingApproval

 /// 由工具调用的三个状态位推导（纯函数，单测覆盖）。
 /// 优先级 = 旧 statusColor/statusText 的判定顺序：失败 > 待审批 > 运行中 > 成功
 /// （待审批的调用 result 仍为 nil，isRunning 同样为 true，必须先判审批）。
    static func resolve(isError: Bool, pendingApproval: Bool, isRunning: Bool) -> StepStatusTone {
        if isError { return .failure }
        if pendingApproval { return .pendingApproval }
        if isRunning { return .running }
        return .success
    }

 /// 圆点颜色：成功=绿（需求的例外 token）/ 失败=红 / 运行中=蓝 / 待审批=黄。
 /// 运行中直接用 accent（#22D3EE，baseline 把 accent 定义为 live 状态专用色，
 /// 与实时思考行的点/文字/底色同一个 token，不再另造一套蓝）。
    var dotColor: Color {
        switch self {
        case .success: return Theme.Palette.stepSuccess
        case .failure: return Theme.Palette.danger
        case .running: return Theme.Palette.accent
        case .pendingApproval: return Theme.Palette.warning
        }
    }

 /// 只在「没有定论」时脉冲：运行中 / 待审批；成功 / 失败静止。
    var isPulsing: Bool {
        self == .running || self == .pendingApproval
    }

 /// 视觉上已删除状态文案；这段文字只供 VoiceOver（步骤行 a11y 标签拼接用）。
    var accessibilityText: String {
        switch self {
        case .success: return L10n.t("成功")
        case .failure: return L10n.t("失败")
        case .running: return L10n.t("运行中")
        case .pendingApproval: return L10n.t("待审批")
        }
    }
}

extension View {
 /// 「运行中」行共用的浅蓝底 + 顶部 accent 细边：v6 LiveReasoningStepRow 的既有样式，
 /// 不是新颜色——底色 Palette.liveStepFill（accent 5%）+ 顶边 Palette.accentBorder（accent 28%）。
 /// 圆角与内边距不归本样式管：底色块由宿主卡片裁切（分组卡片 Radius.lg），
 /// 行内水平内边距统一 Theme.Spacing.s，与实时思考行同一条款。
    @ViewBuilder
    func liveStepHighlight(_ active: Bool = true) -> some View {
        if active {
            background(Theme.Palette.liveStepFill)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.Palette.accentBorder).frame(height: 1)
                }
        } else {
            self
        }
    }
}

// MARK: - Hex color

extension Color {
 /// Creates a color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
