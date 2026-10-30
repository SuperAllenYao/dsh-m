import SwiftUI

/// DD-18（r3.3）左滑的起判与停靠判定，纯函数以便脱离手势单测。
/// 阈值唯一权威位置是 AC-21②（76pt / 600pt·s）；设计 §4 / §6 只引用本条。
enum SwipeIntent {
 /// AC-21②：露出 ≥ rail 完全展开宽度的一半（151 / 2 = 75.5 → 收敛为 76pt，
 /// **不得用 `openWidth / 2` 近似**）。
    static let openDistanceThreshold: CGFloat = 76
 /// AC-21②：松手瞬时左向速度 ≥ 600pt/s（**含等号**：恰好 600 停在展开位）。
    static let openVelocityThreshold: CGFloat = 600

 /// DD-18 ①：水平意图门 `|vx| > |vy| * 1.2`；收起态只接左滑（`vx < 0`），
 /// 展开态两个方向都接（右滑用于收起）。
    static func shouldBegin(velocityX: CGFloat, velocityY: CGFloat, isOpen: Bool) -> Bool {
        guard abs(velocityX) > abs(velocityY) * 1.2 else { return false }
        return isOpen || velocityX < 0
    }

 /// DD-18 ②：松手停靠目标（`-openWidth` = 展开，`0` = 收起）。
 ///
 /// ① 手势开始时该行已展开且本次拖动**净向右**（`dx > 0`）→ 一律收到 0
 /// （AC-21③：与剩余露出多少无关，不得要求拖满 151pt）；
 /// ② 其余情况：`offset ≤ -76pt` 或 `velocityX ≤ -600pt/s` → 展开，否则收起。
    static func settleTarget(
        startOpen: Bool,
        dx: CGFloat,
        offset: CGFloat,
        velocityX: CGFloat,
        openWidth: CGFloat
    ) -> CGFloat {
        guard openWidth > 0 else { return 0 }
        if startOpen, dx > 0 { return 0 }
        if offset <= -openDistanceThreshold { return -openWidth }
        if velocityX <= -openVelocityThreshold { return -openWidth }
        return 0
    }
}

/// m3-swipe geometry: the revealed action rail is a 83pt pin block plus a
/// 68pt archive block at the card's trailing edge (no gap), card height 75pt.
/// Kept outside the generic card (Swift disallows static stored properties in
/// generic types) so tests can pin the numbers too.
enum SwipeCardGeometry {
    static let pinBlockWidth: CGFloat = 83
    static let archiveBlockWidth: CGFloat = 68
    static let openWidth: CGFloat = pinBlockWidth + archiveBlockWidth
}

/// One workspace session card with the R3 left-swipe action block
/// (design 3.2 / m3-swipe): pure SwiftUI self-drawing on top of the existing
/// LazyVStack cards - the card body offsets horizontally, revealing the pin
/// (accent) and archive (warning) blocks at the trailing edge.
///
/// DD-18（r3.3）：手势识别层换成 UIKit `UIPanGestureRecognizer` 桥接
/// （`SwipePanGesture`），卡片与 rail 仍是 SwiftUI；水平意图成立后才接管，
/// 纵向滚动保持第一优先（AC-21⑦）。
struct SwipeableSessionCard<Content: View>: View {
    var sessionId: String
    var isPinned: Bool
    var open: Bool
 /// 横向接管开始（`.began`）：父级把 `swipedSessionId` 改成本行。
    var onSwipeBegan: (String) -> Void
 /// 松手停靠结果（是否展开）：父级据此重写 `swipedSessionId`，并抑制尾随 tap。
    var onSwipeSettled: (String, Bool) -> Void = { _, _ in }
    var onPin: () -> Void
    var onArchive: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offsetX: CGFloat = 0
 /// 拖动中：此期间不接受外部收起（DD-18 ③，防松手假回弹）。
    @State private var isDragging = false
 /// 停靠动画窗口（`Theme.Motion.quick` = 160ms）：窗口内的外部收起以停靠结果为准，
 /// 不叠加第二段动画（设计 §4 冲突裁决 ②）。
    @State private var isSettling = false
    @State private var settledOpen = false
    @State private var settleGeneration = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            actionBlocks
            content()
                .offset(x: offsetX)
        }
 // 必须按卡片的圆角裁切：`.clipped()` 只裁方形边界，rail（归档黄色块）是直角，
 // 卡片 14pt 圆角盖不住它的两个角，rail 收起时会在右侧露出两块黄色边角。
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            SwipePanGesture(
                sessionId: sessionId,
                isOpen: open,
                offsetX: $offsetX,
                isDragging: $isDragging,
                onBegan: onSwipeBegan,
                onSettle: settle
            )
        )
        .onChange(of: open) { _, isOpen in
            #if DEBUG
            SwipeDebugLog.log("card open->\(isOpen) sid=\(sessionId) offsetX=\(offsetX)")
            #endif
 // DD-18 ③：拖动期间的外部收起一律抑制，松手后由停靠结果重写。
            if isDragging { return }
 // 设计 §4 ②：停靠动画未结束时的外部收起以停靠结果为准，不叠加第二段动画。
            if isSettling {
                if !isOpen, settledOpen { onSwipeSettled(sessionId, true) }
                return
            }
 // 非拖动时的外部收起（点卡片外 / 纵向滚动 / 列表清理）保持原行为。
            if !isOpen, offsetX != 0 {
                withAnimation(Theme.Motion.quick) { offsetX = 0 }
            }
        }
    }

 /// 停靠结果：进入短暂的停靠窗口，再由父级写 `swipedSessionId`（唯一真值）。
    private func settle(sessionId: String, isOpen: Bool) {
        settledOpen = isOpen
        isSettling = true
        settleGeneration &+= 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            guard generation == settleGeneration else { return }
            isSettling = false
        }
        onSwipeSettled(sessionId, isOpen)
    }

 /// True while the actions are actually revealed (past ~1/4 of the rail).
 /// Drives accessibility: a covered action block must not sit in the a11y
 /// tree (XCUITest taps/hit-tests through the card otherwise).
    private var actionsRevealed: Bool {
        offsetX < -SwipeCardGeometry.openWidth * 0.25
    }

    private var actionBlocks: some View {
        HStack(spacing: 0) {
            Button(action: onPin) {
                VStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 15, weight: .semibold))
                    Text(isPinned ? L10n.t("取消置顶") : L10n.t("置顶"))
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(isPinned ? Theme.Palette.textSecondary : Theme.Palette.accentInk)
                .frame(width: SwipeCardGeometry.pinBlockWidth)
                .frame(maxHeight: .infinity)
                .background(isPinned ? Theme.Palette.surfaceRaised : Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("swipe-pin-" + sessionId)
            Button(action: onArchive) {
                VStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("归档"))
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.accentInk)
                .frame(width: SwipeCardGeometry.archiveBlockWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.Palette.warning)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("swipe-archive-" + sessionId)
        }
        .accessibilityHidden(!actionsRevealed)
    }
}
