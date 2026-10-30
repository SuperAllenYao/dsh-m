import SwiftUI

// MARK: - DD-17 飞行层

/// DD-17 的纯函数层：目标 frame 常量推算、置顶区高度增量、内容层透明度分段、
/// 视口锚点补偿。全部不依赖视图状态，单测见
/// `DSHmTests/SessionPinFlightMathTests.swift`。
enum SessionPinFlightMath {
 /// DEC-07 确认的时长（唯一权威：`Theme.Motion.pinDuration`，不得替换）。
    static let duration: TimeInterval = Theme.Motion.pinDuration

 // 置顶区纵向节奏：与 WorkspaceListView 的布局常量一一对应，改布局必须同步。
    static let pinnedCardHeight: CGFloat = 44
    static let pinnedRowSpacing: CGFloat = 12
    static let pinnedAreaTopPadding: CGFloat = 10
    static let pinnedAreaBottomPadding: CGFloat = 20

 /// 分组行的上下内边距（行间 12pt）。
    static let groupRowVerticalInset: CGFloat = 6

 /// 列表「在顶部」的阈值：滚动量 ≤ 该值不做视口补偿（保证置顶卡在视口内）。
    static let viewportAnchorThreshold: CGFloat = 40

 /// 内容层交叉切换：常规层前 45% 淡出、置顶层后 45% 淡入。
    static let contentCrossfadeFraction: Double = 0.45

 // MARK: 目标 frame

 /// 常量推算的目标 frame（列表内容坐标）：
 /// `y = 置顶区顶部 + 10 + index × (44 + 12)`、`x = pageInset`、
 /// `width = 列表宽 − 2×pageInset`、`height = 44`。
 ///
 /// 置顶行插入后由 `onGeometryChange` 实测上报；实测先到时以实测为准
 /// （见 WorkspaceListView.recordPinnedRowFrame）。
    static func targetFrame(
        index: Int,
        pinnedAreaTop: CGFloat,
        listWidth: CGFloat,
        horizontalInset: CGFloat
    ) -> CGRect {
        let safeIndex = max(0, index)
        let width = max(0, listWidth - horizontalInset * 2)
        let y = pinnedAreaTop + pinnedAreaTopPadding
            + CGFloat(safeIndex) * (pinnedCardHeight + pinnedRowSpacing)
        return CGRect(x: horizontalInset, y: y, width: width, height: pinnedCardHeight)
    }

 /// 置顶区内容高度的增量：首张置顶卡还要撑开上下 padding。
    static func pinnedAreaGrowth(pinning: Bool, pinnedCountBefore: Int) -> CGFloat {
        let oneRow = pinnedCardHeight + pinnedRowSpacing
        if pinning {
            return pinnedCountBefore == 0
                ? pinnedAreaTopPadding + pinnedAreaBottomPadding + pinnedCardHeight
                : oneRow
        }
 // 取消置顶不做补偿（0 动画帧），保留完整语义便于单测。
        return pinnedCountBefore <= 1
            ? -(pinnedAreaTopPadding + pinnedAreaBottomPadding + pinnedCardHeight)
            : -oneRow
    }

 // MARK: 内容层交叉切换

 /// 几何进度 → 两层内容透明度：常规层前 45% 线性淡出，置顶层后 45% 线性淡入，
 /// 中间不重叠（避免两套文字同屏重影）。
    static func contentLayerOpacities(progress: Double) -> (normal: Double, pinned: Double) {
        let p = min(max(progress, 0), 1)
        let fraction = contentCrossfadeFraction
        let normal = min(max(1 - p / fraction, 0), 1)
        let pinned = min(max((p - (1 - fraction)) / fraction, 0), 1)
        return (normal: normal, pinned: pinned)
    }

 /// 两层各自的时间窗（两个短动画）：常规层 0 → 45% 淡出；置顶层 55% → 100% 淡入。
    static func contentCrossfadePlan() -> (
        normalOut: TimeInterval,
        pinnedInDelay: TimeInterval,
        pinnedIn: TimeInterval
    ) {
        let fade = duration * contentCrossfadeFraction
        return (normalOut: fade, pinnedInDelay: duration - fade, pinnedIn: fade)
    }

 // MARK: 飞行时间轴（显式插值）

 /// 飞行时间 → 几何进度：与 `Theme.Motion.pin` 同一条 cubic-bezier，因此含曲线
 /// 末端约 3.4% 过冲（≈1pt / 29.7pt 高度行程）；超过时长后固定 1（回稳到目标）。
 ///
 /// 位置与高度都由这一个进度驱动（`flightFrame`），不会出现「高度走回弹、
 /// 位置走别的缓动」的不同步。
    static func flightProgress(elapsed: TimeInterval) -> Double {
        let x = min(max(elapsed / duration, 0), 1)
        let curve = Theme.Motion.pinCurve
        return cubicBezier(x: x, x1: curve.x1, y1: curve.y1, x2: curve.x2, y2: curve.y2)
    }

 /// 逐帧几何：位置与高度沿同一条曲线、同一进度从源行插值到置顶位
 /// （宽度固定取目标宽，与飞行卡内容布局一致）。
    static func flightFrame(source: CGRect, target: CGRect, progress: Double) -> CGRect {
        let p = CGFloat(progress)
        return CGRect(
            x: source.minX + (target.minX - source.minX) * p,
            y: source.minY + (target.minY - source.minY) * p,
            width: target.width,
            height: source.height + (target.height - source.height) * p
        )
    }

 /// 时间 → 两层内容透明度：沿用 `contentCrossfadePlan()` 的时间窗与
 /// `.easeOut` / `.easeIn` 曲线，但由显示帧时钟显式求值（不依赖隐式动画调度）。
    static func contentLayerOpacities(elapsed: TimeInterval) -> (normal: Double, pinned: Double) {
        let plan = contentCrossfadePlan()
        let t = max(elapsed, 0)
        let normalT = min(max(t / plan.normalOut, 0), 1)
        let pinnedT = min(max((t - plan.pinnedInDelay) / plan.pinnedIn, 0), 1)
        return (
            normal: 1 - cubicBezier(x: normalT, x1: 0, y1: 0, x2: 0.58, y2: 1),
            pinned: cubicBezier(x: pinnedT, x1: 0.42, y1: 0, x2: 1, y2: 1)
        )
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

 // MARK: 视口锚点

 /// 是否需要视口补偿：列表滚深（> 40pt）才需要，列表在顶部时不做补偿。
    static func needsViewportCompensation(scrollOffset: CGFloat) -> Bool {
        scrollOffset > viewportAnchorThreshold
    }

 /// 锚点行的内容坐标位移：置顶区增长会把它下推，被置顶的源行从分组移除会把
 /// 它上提（仅当锚点在源行下方）。
    static func anchorShift(
        pinnedAreaGrowth: CGFloat,
        removedSourceHeight: CGFloat?,
        sourceAboveAnchor: Bool,
        groupRowVerticalInset: CGFloat = SessionPinFlightMath.groupRowVerticalInset
    ) -> CGFloat {
        guard sourceAboveAnchor, let height = removedSourceHeight else { return pinnedAreaGrowth }
        return pinnedAreaGrowth - (height + groupRowVerticalInset * 2)
    }

 /// 补偿后的滚动偏移：内容位移 shift 时，把滚动偏移同步 +shift，锚点留在原位。
    static func compensatedScrollOffset(currentOffset: CGFloat, shift: CGFloat) -> CGFloat {
        currentOffset + shift
    }
}

// MARK: - 飞行层视图状态

/// 飞行层逐帧真值（DD-17 的 DEBUG 探针读取；生产构建恒为 nil，不采集）。
final class PinFlightFrameRecorder {
    var rect: CGRect?
}

/// 一次置顶飞行的快照：源行几何（未左滑的行 frame）+ 目标几何 + 卡片内容。
struct SessionPinFlight: Equatable {
    var sessionId: String
 /// 源行几何（列表内容坐标，未左滑的行 frame，不是被平移的卡片内容）。
    var sourceRect: CGRect
 /// 目标几何（列表内容坐标）：点击当帧按常量推算，置顶行实测若在首个显示帧前
 /// 报到则覆盖；飞行开始后不再改（否则会二次跳动）。
    var targetRect: CGRect
 /// 点击当帧的卡片快照：飞行期间真实行被隐藏，飞行卡照原样渲染两层内容。
    var card: SessionCardView
 /// 飞行时间轴原点（点击时刻）：位置/高度/底色/两层内容都从这一个时刻起算。
    var startedAt: Date
}

// MARK: - 飞行卡

/// 飞行卡位置（列表内容坐标）+ 逐帧渲染真值采集。
///
/// 用 `GeometryEffect` 而不是 `.offset` 的原因：`.offset` 是渲染变换，没有可读的
/// 逐帧真值；`effectValue` 能拿到当前插值位置与动画中的高度（探针据此判
/// 「首次到位 / 回稳 / 过冲」）。
struct SessionPinFlightPosition: GeometryEffect {
    var position: CGPoint
    var recorder: PinFlightFrameRecorder?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position.x, position.y) }
        set { position = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        recorder?.rect = CGRect(origin: position, size: size)
        return ProjectionTransform(
            CGAffineTransform(translationX: position.x, y: position.y)
        )
    }
}

/// 飞行卡底色/描边插值（DD-17：与几何同曲线同步变化）。
///
/// 两层 token 交叉淡入：不透明顶层随进度淡出，得到的渲染色正好是两端颜色的线性
/// 插值；置顶底色 = `background` + `accentSoft`(10%) 叠出的不透明合成色（飞行卡
/// 不能透出下面的内容），描边 = `border` → `accentBorder`。
struct PinFlightChrome: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
 // 置顶底色（不透明合成）：background 打底 + accentSoft 10% 叠加。
                    shape.fill(Theme.Palette.background)
                    shape.fill(Theme.Palette.accentSoft)
 // 常规底色 surface 随进度淡出（p=0 时完全覆盖 ⇒ surface）。
                    shape
                        .fill(Theme.Palette.surface)
                        .opacity(1 - progress)
                }
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(Theme.Palette.accentBorder, lineWidth: 1)
                    shape
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                        .opacity(1 - progress)
                }
            }
    }
}

/// DD-17 飞行卡：从源行位置连续插值到置顶位，高度「实测源行高度 → 44pt」，
/// 同时插值底色/描边，常规内容层与置顶内容层前后交叉切换。
struct SessionPinFlightCard: View {
    var flight: SessionPinFlight
    var position: CGPoint
    var height: CGFloat
    var chromeProgress: Double
    var normalOpacity: Double
    var pinnedOpacity: Double
    var recorder: PinFlightFrameRecorder?

 /// 置顶内容层：同一张卡的紧凑/置顶形态（22pt 标题行 + 底/描边由飞行卡负责）。
    private var pinnedCard: SessionCardView {
        var card = flight.card
        card.isPinned = true
        card.compact = true
        return card
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            flight.card
                .opacity(normalOpacity)
            pinnedCard
                .opacity(pinnedOpacity)
        }
        .frame(width: flight.targetRect.width, height: height, alignment: .topLeading)
        .clipped()
        .modifier(PinFlightChrome(progress: chromeProgress))
        .modifier(SessionPinFlightPosition(position: position, recorder: recorder))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
