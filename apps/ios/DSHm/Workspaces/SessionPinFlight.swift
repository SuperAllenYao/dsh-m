import QuartzCore
import SwiftUI

// MARK: - 卡片缩放锚点（DD-05）

/// 卡片缩放的 `transform-origin`（DD-05 / 需求 v4.0 DEC-09）：
/// - `.top` = 卡片**上边缘水平中心**（`transform-origin: 50% 0%`）：置顶区屏内、
///   普通屏外、新置顶卡长出、归位卡长出；
/// - `.bottom` = 卡片**下边缘水平中心**（`transform-origin: 50% 100%`）：
///   仅内容底部（DEC-13，上方列表同步向下滑动补位）的源卡缩小。
enum PinCardAnchor: String, Equatable {
    case top
    case bottom

    /// SwiftUI `scaleEffect(_:anchor:)` 的等价单位点：`.top` = (0.5, 0)、
    /// `.bottom` = (0.5, 1)，即上/下边缘的水平中心。
    var unitPoint: UnitPoint {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

// MARK: - 置顶 / 取消置顶过渡（DD-01…DD-09）

/// 置顶/取消置顶过渡的纯函数层：置顶区节奏常量、插入点 frame、屏内/屏外/刷新段的
/// 行位移公式、新数据布局预测、时间 → 曲线进度。全部不依赖视图状态，
/// 单测见 `DSHmTests/PinMotionMathTests.swift`。
///
/// 记法（设计 v4 §3）：`shift` = 新屏幕位置 − 旧屏幕位置；行渲染
/// `offset(y: −shift × (1 − progress))`；`growth` = 置顶区高度增量（首次 74、
/// 常规 56）；`sourceSlot` = 源行槽位高（实测卡高 + 12）；`restoredSlot` = 归位行
/// 槽位高。行 id 用 sessionId，分组头用 `header:<path>`。
enum SessionPinFlightMath {
    /// DEC-07 既定时长（唯一权威：`Theme.Motion.pinDuration`，不得替换）。
    static let duration: TimeInterval = Theme.Motion.pinDuration

    // 置顶区纵向节奏：与 WorkspaceListView 的布局常量一一对应，改布局必须同步。
    static let pinnedCardHeight: CGFloat = 44
    static let pinnedRowSpacing: CGFloat = 12
    static let pinnedAreaTopPadding: CGFloat = 10
    static let pinnedAreaBottomPadding: CGFloat = 20
    /// 置顶行槽位高（44 + 12）。
    static let pinnedRowSlot: CGFloat = pinnedCardHeight + pinnedRowSpacing

    /// 分组行的上下内边距合计（行间 12pt：上下各 6）。
    static let groupRowVerticalInset: CGFloat = 6
    /// 分组之后、下一个分组头之前的额外留白（`Theme.Spacing.l` 20 − 行下 6）。
    static let groupSpacingExtra: CGFloat = Theme.Spacing.l - groupRowVerticalInset
    /// 行高缓存缺失时的会话行槽位高（实测 85.7 = 73.7 + 12）。
    static let defaultSessionRowSlot: CGFloat = 85.7
    /// 行高缓存缺失时的分组头高；首个分组头实测后会覆盖。
    static let defaultGroupHeaderHeight: CGFloat = 38

    /// 分组头行 id（与 `listGeometry.headerFrames` 同键）。
    static func headerId(forPath path: String) -> String { "header:" + path }

    // MARK: 插入点 frame

    /// 常量推算的插入点 frame（列表内容坐标，DD-03 用它判屏内/屏外）：
    /// `y = 置顶区顶部 + 10 + index × 56`、`x = pageInset`、
    /// `width = 列表宽 − 2×pageInset`、`height = 44`。
    static func targetFrame(
        index: Int,
        pinnedAreaTop: CGFloat,
        listWidth: CGFloat,
        horizontalInset: CGFloat
    ) -> CGRect {
        let safeIndex = max(0, index)
        let width = max(0, listWidth - horizontalInset * 2)
        let y = pinnedAreaTop + pinnedAreaTopPadding
            + CGFloat(safeIndex) * pinnedRowSlot
        return CGRect(x: horizontalInset, y: y, width: width, height: pinnedCardHeight)
    }

    /// 置顶区内容高度的增量：首张置顶卡还要撑开上下 padding（10 + 44 + 20 = 74），
    /// 之后每张只加一个槽位（44 + 12 = 56）。
    static func pinnedAreaGrowth(pinning: Bool, pinnedCountBefore: Int) -> CGFloat {
        let firstRow = pinnedAreaTopPadding + pinnedAreaBottomPadding + pinnedCardHeight
        if pinning {
            return pinnedCountBefore == 0 ? firstRow : pinnedRowSlot
        }
        return pinnedCountBefore <= 1 ? -firstRow : -pinnedRowSlot
    }

    /// 置顶区内容高度（n 张置顶卡时的总高）：0 张为 0，否则 18 + 56n
    /// （10 上留白 + n×44 + (n−1)×12 + 20 下留白）。
    static func pinnedAreaHeight(pinnedCount: Int) -> CGFloat {
        guard pinnedCount > 0 else { return 0 }
        return pinnedAreaTopPadding + pinnedAreaBottomPadding
            + CGFloat(pinnedCount) * pinnedCardHeight
            + CGFloat(pinnedCount - 1) * pinnedRowSpacing
    }

    // MARK: 行位移（DD-02 屏内 / DD-04 屏外）

    /// 过渡开始时可见的一行（列表内容坐标里的行 frame）。
    struct Row: Equatable {
        var id: String
        /// 行卡片在内容坐标里的 minY（不是被左滑平移的卡片内容）。
        var minY: CGFloat
        var height: CGFloat
        var isPinned: Bool
    }

    /// 置顶（插入点屏内，DD-02）：置顶区已有行 `+growth`；分组行/分组头在源行
    /// 之前 `+growth`、之后 `+growth − sourceSlot`。被置顶的源行不参与（它当帧移除）。
    static func inPlacePinShifts(
        rows: [Row],
        sourceId: String,
        growth: CGFloat,
        sourceSlot: CGFloat
    ) -> [String: CGFloat] {
        guard let source = rows.first(where: { $0.id == sourceId }) else { return [:] }
        var shifts: [String: CGFloat] = [:]
        for row in rows where row.id != sourceId {
            if row.isPinned || row.minY < source.minY {
                shifts[row.id] = growth
            } else {
                shifts[row.id] = growth - sourceSlot
            }
        }
        return shifts
    }

    /// 取消置顶（DD-02）：被取消卡下方的置顶行 `−pinnedRowSlot`、上方不动；分组行/
    /// 分组头在归位点之前 `−sectionGrowth`、之后 `−sectionGrowth + restoredSlot`。
    /// 被取消卡不参与（它当帧移除并换成幽灵卡）。
    static func inPlaceUnpinShifts(
        rows: [Row],
        canceledId: String,
        pinnedRowSlot: CGFloat = pinnedRowSlot,
        sectionGrowth: CGFloat,
        restoredSlot: CGFloat,
        isBeforeRestored: (Row) -> Bool
    ) -> [String: CGFloat] {
        guard let canceled = rows.first(where: { $0.id == canceledId }) else { return [:] }
        var shifts: [String: CGFloat] = [:]
        for row in rows where row.id != canceledId {
            if row.isPinned {
                shifts[row.id] = row.minY > canceled.minY ? -pinnedRowSlot : 0
            } else if isBeforeRestored(row) {
                shifts[row.id] = -sectionGrowth
            } else {
                shifts[row.id] = -sectionGrowth + restoredSlot
            }
        }
        return shifts
    }

    /// DD-04 内容底部（DEC-13）：缺口 = `sourceSlot − 可用余量`（0…sourceSlot）。
    /// 可用余量 = 旧内容最大偏移 − 当前偏移；内容还有一张卡以上余量时缺口为 0
    /// （普通屏外分支），到底时缺口 = sourceSlot（一张卡片槽位，实测 85.7pt）。
    static func anchoredResidual(sourceSlot: CGFloat, headroom: CGFloat) -> CGFloat {
        guard sourceSlot > 0 else { return 0 }
        guard headroom.isFinite else { return 0 }
        return max(0, min(sourceSlot, sourceSlot - headroom))
    }

    /// 置顶（插入点屏外，DD-04）：源行上方可见行 `+residual`、源行下方可见行
    /// `residual − sourceSlot`。内容有余量时 `residual = 0`（上方 0、下方
    /// `−sourceSlot` 连续补位一行）；内容底部（DEC-13）滚动只能吸收
    /// `growth − residual`，缺口 `residual` 由上方可见行连续下移（整体下移
    /// ≤ sourceSlot），下方行按剩余余量上移，二者与终帧布局一致。
    /// `zeroShiftIds`：屏幕位置由吸顶决定的行（吸顶分组头，变更前后都在视口顶部）——
    /// 它们的新旧屏幕位置相同，shift 必须为 0，不能套用内容位移公式（否则会被
    /// 残余 shift 拉出一个向上的单帧跳变）。
    static func anchoredShifts(
        rows: [Row],
        sourceId: String,
        sourceSlot: CGFloat,
        residual: CGFloat = 0,
        zeroShiftIds: Set<String> = []
    ) -> [String: CGFloat] {
        guard let source = rows.first(where: { $0.id == sourceId }) else { return [:] }
        let safeResidual = max(0, min(sourceSlot, residual))
        var shifts: [String: CGFloat] = [:]
        for row in rows where row.id != sourceId {
            if zeroShiftIds.contains(row.id) {
                shifts[row.id] = 0
            } else {
                shifts[row.id] = row.minY > source.minY
                    ? safeResidual - sourceSlot
                    : safeResidual
            }
        }
        return shifts
    }

    /// DD-04 锚点实测校验结果。
    enum AnchorReplacement: Equatable {
        /// 无上方锚点：校正量就是 `growth`（设计稿场景③同款）。
        case noAnchor
        /// 偏差 ≤ 2pt 或实测不可用：保留 `growth` 预测。
        case keepPrediction
        /// 反号：保留 `growth`（设计明确「反号保留预测」）。
        case keepOppositeSign
        /// 同号但残差超出合理上限：判为不可信测量，保留 `growth`。
        case keepImplausible
        /// 同号且 > 2pt：以实测替换，增量 = 偏差（已含 `growth` 校正后再叠加）。
        case replace(adjustment: CGFloat)
    }

    /// DD-04 锚点实测替换判定（纯函数）。
    ///
    /// `deviation` = 锚点「实测屏幕位置 − 段开始时屏幕位置」：`growth` 校正已在同一次
    /// 更新里应用，预测正确时该项恒为 0（非零即预测偏差）。
    /// - `|deviation| ≤ 2pt`：预测已准，保留 `growth`。
    /// - 反号：实测位移小于预测，保留 `growth`，只记录偏差。
    /// - 同号且 > 2pt：以实测替换（滚动偏移再补 `deviation`）；但**超过合理上限**
    ///   （`plausibleLimit`，默认 12pt）的残差更像「首帧布局未落地的中间态测量」，
    ///   不是预测偏差（实测：上方行真实位移 <0.5pt 时锚点却报 -14/-26pt），
    ///   替换会把错误测量灌进滚动偏移 → 保留预测，只记诊断。
    static func anchorReplacement(
        deviation: CGFloat,
        growth: CGFloat,
        threshold: CGFloat = 2,
        plausibleLimit: CGFloat = 12
    ) -> AnchorReplacement {
        guard growth != 0 else { return .keepPrediction }
        if abs(deviation) <= threshold { return .keepPrediction }
        let sameSign = (deviation > 0) == (growth > 0)
        guard sameSign else { return .keepOppositeSign }
        guard abs(deviation) <= plausibleLimit else { return .keepImplausible }
        return .replace(adjustment: deviation)
    }

    /// 过渡开始时源行上方最近的可见行（DD-04 锚点；含可见置顶卡与分组头）。
    static func anchorRow(rows: [Row], sourceId: String) -> Row? {
        guard let source = rows.first(where: { $0.id == sourceId }) else { return nil }
        return rows
            .filter { $0.id != sourceId && $0.minY < source.minY }
            .max { $0.minY < $1.minY }
    }

    // MARK: 卡片锚点与归位卡可见性（DD-05 / DEC-09 / DEC-13）

    /// 幽灵卡（源卡 / 被取消卡）缩放锚点（DD-05）：
    /// - `.inPlace`（插入点屏内）与普通 `.anchored`（屏外非底部）：**上边缘水平中心**；
    /// - 内容底部（DEC-13：`residual > 0`，滚动余量不足、上方列表同步向下补位）：
    ///   **下边缘水平中心**（列表向下补位，视觉上向底部收）。
    /// 刷新段没有幽灵卡，按上边缘处理（无副作用）。
    static func ghostAnchor(for mode: PinMotionState.Mode, residual: CGFloat) -> PinCardAnchor {
        mode == .anchored && residual > 0 ? .bottom : .top
    }

    /// 归位卡是否在过渡开始时视口内（DD-05 / AC-02）：
    /// 新排序位置（DD-07 同一套内容坐标预测）的卡片与视口相交 → 同一段内从
    /// 上边缘水平中心长出；否则当帧出现、不播缩放（保持现状）。
    /// `viewportHeight <= 1`（布局未就绪）按「无限视口」处理，不因测量缺失吞掉动画。
    static func restoredCardVisible(
        newContentTop: CGFloat,
        cardHeight: CGFloat,
        scrollOffset: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        let screenTop = newContentTop - scrollOffset
        let height = max(0, cardHeight)
        let viewport = viewportHeight > 1 ? viewportHeight : .greatestFiniteMagnitude
        return screenTop + height > 0 && screenTop < viewport
    }

    // MARK: 刷新段布局预测（DD-07）

    struct GroupLayout: Equatable {
        var path: String
        var collapsed: Bool
        var sessionIds: [String]
    }

    /// 新数据的布局输入：置顶集合 + 分组顺序 + 行高缓存（缺失走默认）。
    struct LayoutInput {
        var pinnedAreaTop: CGFloat
        var pinnedIds: [String]
        var groups: [GroupLayout]
        var rowSlot: (String) -> CGFloat
        var headerHeight: (String) -> CGFloat
    }

    /// 新数据下每行卡片在内容坐标里的 minY：置顶行、分组头（`header:<path>`）、
    /// 会话行。刷新段用它预测新屏幕位置（不采用变更后实测，DD-07）。
    static func predictedContentTops(_ input: LayoutInput) -> [String: CGFloat] {
        var tops: [String: CGFloat] = [:]
        var y = input.pinnedAreaTop
        if !input.pinnedIds.isEmpty {
            for (index, id) in input.pinnedIds.enumerated() {
                tops[id] = y + pinnedAreaTopPadding + CGFloat(index) * pinnedRowSlot
            }
            y += pinnedAreaHeight(pinnedCount: input.pinnedIds.count)
        }
        for group in input.groups {
            tops[headerId(forPath: group.path)] = y
            y += input.headerHeight(group.path)
            if !group.collapsed {
                for id in group.sessionIds {
                    tops[id] = y + groupRowVerticalInset
                    y += input.rowSlot(id)
                }
            }
            y += groupSpacingExtra
        }
        return tops
    }

    /// 刷新段位移（DD-07）：刷新前后都存在的可见行
    /// `shift = 预测新屏幕位置 − 段开始时实测屏幕位置`。
    static func refreshShifts(
        currentScreenTops: [String: CGFloat],
        predictedContentTops: [String: CGFloat],
        scrollOffset: CGFloat
    ) -> [String: CGFloat] {
        var shifts: [String: CGFloat] = [:]
        for (id, currentScreen) in currentScreenTops {
            guard let newContentTop = predictedContentTops[id] else { continue }
            shifts[id] = newContentTop - scrollOffset - currentScreen
        }
        return shifts
    }

    // MARK: 时间轴（显式插值）

    /// 过渡时间 → 几何进度：与 `Theme.Motion.pin` 同一条 **无过冲** cubic-bezier
    /// （DD-10：`cubic-bezier(.22,1,.36,1)`，进度单调 0→1、不过冲）；超过时长后固定 1。
    /// `duration` 默认设计时长 150ms；DD-07 后段按 450ms 总预算缩短时传入更短值。
    static func motionProgress(
        elapsed: TimeInterval,
        duration: TimeInterval = SessionPinFlightMath.duration
    ) -> Double {
        let safeDuration = max(duration, 1e-6)
        let x = min(max(elapsed / safeDuration, 0), 1)
        let curve = Theme.Motion.pinCurve
        return cubicBezier(x: x, x1: curve.x1, y1: curve.y1, x2: curve.x2, y2: curve.y2)
    }

    /// 通用 cubic-bezier(x1,y1,x2,y2)：x 为时间轴 0…1，返回曲线进度。
    /// 两个 x 控制点都在 (0,1) 内 ⇒ x(u) 单调，用二分求参数再取 y；纯函数，单测覆盖。
    static func cubicBezier(
        x: Double,
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) -> Double {
        let target = min(max(x, 0), 1)
        guard target > 0, target < 1 else { return target }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<30 {
            let middle = (lower + upper) / 2
            if bezierComponent(middle, control1: x1, control2: x2) < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        return bezierComponent((lower + upper) / 2, control1: y1, control2: y2)
    }

    private static func bezierComponent(_ u: Double, control1: Double, control2: Double) -> Double {
        let inverse = 1 - u
        return 3 * inverse * inverse * u * control1
            + 3 * inverse * u * u * control2
            + u * u * u
    }

    // MARK: 卡片缩放（DD-05 / 设计稿 v4.0）

    /// 幽灵卡：原位等比 `scale 1 → 0`（与补位共用同一时间轴/曲线；锚点见
    /// `ghostAnchor`），不透明度 1 → 0（稿面 80% 处 0.6）。无过冲曲线下 `progress`
    /// 不会超过 1，`max(0:)` 只是防御。
    static func ghostScale(progress: Double) -> Double {
        max(0, 1 - progress)
    }

    static func ghostOpacity(progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        if p < 0.8 { return 1 - 0.4 * (p / 0.8) }
        return 0.6 * (1 - (p - 0.8) / 0.2)
    }

    /// 新置顶卡：从**上边缘水平中心**向四周长出 `scale 0 → 1`（设计稿 v4.0；
    /// 不再用旧口径的 0.24 起步，也不再做中心放大）。
    static func insertedCardScale(progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    /// 归位卡（取消置顶回到分组排序位）：在屏内时与新置顶卡同款
    /// 「上边缘水平中心长出」；屏外时视图层直接按 `scale 1` 当帧出现，不调用本函数。
    static func restoredCardScale(progress: Double) -> Double {
        insertedCardScale(progress: progress)
    }

    /// 设计稿 v4.0：长出动画不做透明度淡入（`scale 0` 本身不可见），恒为 1。
    /// 保留函数仅为视图层/单测共用同一口径。
    static func insertedCardOpacity(progress: Double) -> Double {
        _ = progress
        return 1
    }
}

// MARK: - 过渡状态

/// 过渡时间轴：在**首个渲染帧**起算（首帧零点：真机首帧可能晚到约 60ms），跑
/// `duration`（≤150ms；DD-07 三段共享 450ms 预算时后段按剩余预算缩短）。时间轴本身
/// 是「时间 → 曲线」的纯映射；每个渲染消费者（每一行、幽灵卡、新卡、归位卡）各自
/// 维护**自己的**进度（且**自己的首个渲染帧**恒为 0），并且单帧增量上限 `maxAdvancePerFrame`。
///
/// 为什么按消费者分别限速：设计曲线的第一段极陡（60fps 下首帧增量 0.438），模拟器
/// 在数据变更后常有 31–33ms 掉帧、且个别行/卡片层的 `TimelineView` 会晚一帧渲染。若全部
/// 行共享一个「已推进进度」，某一行少渲染一帧后再渲染时会一次跨两帧（实测 0.54 >
/// 判据 1/2）；按消费者各自限速后，任何一行的一帧最多推进 0.40。
/// 同理，晚一帧才首次渲染的消费者（实测：真机幽灵层）若直接取全局曲线会从
/// 中段开始（首帧零点同类现象），所以每个消费者首个渲染帧一律返回 0。
final class PinTransitionClock {
    /// 本段时间轴时长（≤ 设计时长 150ms）。
    let duration: TimeInterval
    private var start: Date?
    /// 数据变更（段开始）请求时刻；仅诊断用，时间轴零点见 `begin`。
    private(set) var requestedAt: Date?
    /// 每个渲染消费者的进度与上次推进时间。
    private var values: [String: Double] = [:]
    private var lastAdvance: [String: Date] = [:]
    /// 已观察到的渲染帧数（首帧 = 1）；DD-04 锚点实测替换要求仍在首帧。
    private(set) var frameCount = 0
    private var lastFrameDate: Date?
    /// 时间轴起点的 `CACurrentMediaTime()`（毫秒，与探针时间轴同一时基）。
    private(set) var startedAtMediaTime: Double?

    /// 单帧最大进度增量：60fps 下曲线自然最大增量 0.398，只有掉帧才会被限速；
    /// 保证任意一帧的位移 ≤ 总位移的 40%（判据 ≤ 1/2）。
    static let maxAdvancePerFrame: Double = 0.40
    /// 同一显示帧的判定窗口：120Hz 最短帧间隔 8.3ms，取 5.5ms 安全。
    private static let sameFrameInterval: TimeInterval = 1.0 / 180.0
    /// 「仍在渲染」的判定窗口（settle 时只看这些消费者的进度）。
    private static let activeWindow: TimeInterval = 0.12

    init(duration: TimeInterval = SessionPinFlightMath.duration) {
        let upper = SessionPinFlightMath.duration
        self.duration = min(max(duration, 1.0 / 60.0), upper)
    }

    var startedAt: Date? { start }

    /// 显式复位（数据变更 / 段开始时调用）：时间轴零点推迟到**首个渲染帧**。
    /// 真机上首帧提交可能晚 40–60ms（大会话列表 / 首次布局），若零点仍是数据变更
    /// 时刻，首帧会直接跳到约 40% 位移、幽灵卡从约 0.6 起步缩小——真机表现为
    /// 「整屏快速闪一下、看不到卡片从中心缩小」（首帧零点）。零点改到首帧后，
    /// 首个渲染帧恒为 0 进度：卡片从全尺寸缩小、整段动画完整播满 150ms。
    func begin(at date: Date) {
        start = nil
        requestedAt = date
        values.removeAll()
        lastAdvance.removeAll()
        frameCount = 0
        lastFrameDate = nil
        startedAtMediaTime = nil
    }

    /// 某个渲染消费者本帧的进度（0…1）：全局时间轴 + **本消费者**的首帧 0 与单帧增量上限。
    /// 同一显示帧内重复调用不推进。
    func progress(key: String, now: Date) -> Double {
        if start == nil {
            // 全局首个渲染帧：从这一帧开始计时，本帧进度恒为 0（不跳过动画前段）。
            start = now
            startedAtMediaTime = CACurrentMediaTime() * 1000
            lastFrameDate = now
            frameCount = 1
            values[key] = 0
            lastAdvance[key] = now
            return 0
        }
        guard let start else { return 0 }
        if let lastFrameDate, now.timeIntervalSince(lastFrameDate) >= Self.sameFrameInterval {
            self.lastFrameDate = now
            frameCount += 1
        } else if lastFrameDate == nil {
            lastFrameDate = now
            frameCount = 1
        }
        if let last = lastAdvance[key], now.timeIntervalSince(last) < Self.sameFrameInterval {
            return values[key] ?? 0
        }
        if values[key] == nil {
            // 该消费者比段首晚一帧才首次渲染（实测：真机幽灵卡）：本帧也恒为 0，
            // 从全尺寸开始缩，而不是从曲线中段开始（首帧零点同类修复）。
            values[key] = 0
            lastAdvance[key] = now
            return 0
        }
        lastAdvance[key] = now
        let target = SessionPinFlightMath.motionProgress(
            elapsed: now.timeIntervalSince(start),
            duration: duration
        )
        let previous = values[key] ?? 0
        let next = min(target, previous + Self.maxAdvancePerFrame)
        values[key] = next
        return next
    }

    /// 段开始起算的墙钟时长（不含任何掉帧暂停）。
    func elapsed(now: Date) -> TimeInterval {
        guard let start else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// 仍活跃消费者的最小进度（最近 120ms 有渲染的键）。所有可见行都到终值才算落位。
    /// 已消失的行（键不再渲染）不参与，否则会被它们的残留值卡住。
    var settledProgress: Double {
        let now = Date()
        let active = values.filter { key, _ in
            guard let last = lastAdvance[key] else { return false }
            return now.timeIntervalSince(last) < Self.activeWindow
        }
        return active.values.min() ?? 0
    }

    /// 探针用：本段渲染到的最大进度。
    var renderedProgress: Double { values.values.max() ?? 0 }
    /// 探针用：已推进的渲染帧数。
    var renderedFrames: Int { frameCount }

    /// 段末条件：时间轴跑满 `duration` **且** 活跃消费者都到终值（限速追赶最多 2 帧）。
    /// 只按时间判定会在限速未追上时落位，产生段末跳变。终值容差 0.5%：曲线尾部
    /// 渐近 1，逐帧采样可能永远差一点点，0.5% 的残留偏移 <0.5pt 不可见。
    func isSettled(now: Date) -> Bool {
        guard start != nil else { return false }
        let elapsed = elapsed(now: now)
        guard elapsed >= duration else { return false }
        return settledProgress >= 1 - 0.005
            || elapsed >= duration + 2.0 / 60.0
    }
}

/// 一次过渡段（DD-07：同一时刻最多一段；段号 1…3，不存在段 4）。
struct PinMotionState {
    enum Mode: String {
        /// 置顶、插入点屏内：整段列表让位。
        case inPlace
        /// 置顶、插入点屏外：滚动偏移吸收 growth，只做源行下方补位。
        case anchored
        /// 刷新段：按数据预测让位到新布局。
        case refresh
    }

    enum Kind: String {
        case pin
        case unpin
        case refresh
    }

    var mode: Mode
    var kind: Kind
    var segment: Int
    /// 被驱动行的屏幕位移（新 − 旧）；键为 sessionId / `header:<path>`。
    var shifts: [String: CGFloat]
    var startedAt: Date
    /// 动画时间轴（首个渲染帧起算；行/新置顶卡/幽灵卡共用）。
    var clock: PinTransitionClock
    /// 段结束回调的取消令牌（连点/滚动 settle 后旧回调失效）。
    var token: UUID
    var sourceId: String?
    /// 新置顶卡（插入点可见时播上边缘中心长出）。
    var insertedId: String?
    /// 取消置顶后回到分组排序位的会话。
    var restoredId: String?
    /// DD-05：归位卡在过渡开始时是否在视口内（true = 同一段从上边缘中心长出；
    /// false = 当帧出现、不播缩放）。
    var restoredVisible: Bool = false
    /// DD-05：幽灵卡缩放锚点（`.inPlace`/普通屏外 = 上边缘；内容底部 = 下边缘）。
    var ghostAnchor: PinCardAnchor = .top
    /// DD-05：归位卡缩放锚点固定为上边缘水平中心。
    var restoredAnchor: PinCardAnchor = .top
    /// 段开始时的数据版本与「旧」全量预测内容坐标（诊断真值）。
    var dataVersion: Int
    var oldContentTops: [String: CGFloat]
    /// DD-04 内容底部（DEC-13）诊断：段开始时可用滚动余量、缺口与实施加的滚动校正。
    /// 普通段（未触发底部）三者均为 0。
    var headroom: CGFloat = 0
    var residual: CGFloat = 0
    var scrollCorrection: CGFloat = 0
}

/// 幽灵卡（DD-05）：源行/被取消卡的原位快照，150ms 内按锚点等比缩小消失
/// （①②上边缘水平中心；内容底部 DEC-13 下边缘水平中心）。
struct SessionPinGhost {
    var sessionId: String
    /// 源行 frame（列表内容坐标）。
    var frame: CGRect
    var card: SessionCardView
    /// 动画时间轴：与过渡段共用（首个渲染帧起算）。
    var clock: PinTransitionClock
    var startedAt: Date
    /// 取消置顶（紧凑置顶卡）为 true；仅诊断用。
    var pinned: Bool
    /// DD-05：缩放 `transform-origin`（top/bottom）。
    var anchor: PinCardAnchor = .top
}
