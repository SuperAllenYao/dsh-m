import SwiftUI

/// R3 swipe-intent arbitration (design 3.2), as pure functions so the gesture
/// thresholds are unit-testable without a touch harness.
enum SwipeIntent {
 /// A leftward drag beats vertical scrolling only when it is clearly
 /// horizontal: |dx| > |dy| * 1.2 and dx < 0.
    static func isHorizontalSwipe(translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.2 && translation.width < 0
    }

 /// Settling decision on gesture end: past half of the action width (or a
 /// fast-enough leftward flick) keeps it open, anything else springs back.
 /// velocity is points per second.
    static func settlesOpen(translation: CGSize, velocity: CGSize, openWidth: CGFloat) -> Bool {
        guard openWidth > 0 else { return false }
        if translation.width < 0, translation.width < -openWidth * 0.5 { return true }
        return velocity.width < -600
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
/// (accent) and archive (warning) blocks at the trailing edge. The vertical
/// scroll stays first-class: the drag only claims a gesture once the swipe
/// intent test passes, so short or vertical movements keep scrolling.
struct SwipeableSessionCard<Content: View>: View {
    var sessionId: String
    var isPinned: Bool
    var open: Bool
    var onSwipeOpen: (String) -> Void
    var onPin: () -> Void
    var onArchive: () -> Void
    @ViewBuilder var content: () -> Content


    @State private var offsetX: CGFloat = 0
    @State private var horizontal = false
    @State private var dragStartOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            actionBlocks
            content()
                .offset(x: offsetX)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    if !horizontal {
                        guard SwipeIntent.isHorizontalSwipe(translation: value.translation) else { return }
                        horizontal = true
                        dragStartOffset = open ? -SwipeCardGeometry.openWidth : 0
 // Swiping one card closes any other open card first.
                        onSwipeOpen(sessionId)
                    }
                    let proposed = dragStartOffset + value.translation.width
                    offsetX = min(0, max(-SwipeCardGeometry.openWidth - 24, proposed))
                }
                .onEnded { value in
                    defer { horizontal = false }
                    guard horizontal else { return }
                    withAnimation(Theme.Motion.quick) {
                        if SwipeIntent.settlesOpen(
                            translation: value.translation,
                            velocity: value.velocity,
                            openWidth: SwipeCardGeometry.openWidth
                        ) {
                            offsetX = -SwipeCardGeometry.openWidth
                        } else {
                            offsetX = 0
                        }
                    }
                }
        )
        .onChange(of: open) { _, isOpen in
 // External close (tap elsewhere / scroll / list refresh) syncs here.
            if !isOpen, offsetX != 0 {
                withAnimation(Theme.Motion.quick) { offsetX = 0 }
            }
        }
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
