import SwiftUI

// MARK: - Unified bottom popups

/// Preference carrying the intrinsic height of a popup's scroll content.
///
/// The measurement is taken *inside* the popup's `ScrollView`, where the content
/// is proposed an unlimited height, so `proxy.size.height` is the content's own
/// height (not the viewport height) — no layout cycle.
struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Bottom safe-area inset of the active window. The app is portrait-only, so this
/// is stable. Popups include this band in their own surface:
/// height = auto content + bottom safe area.
enum WindowSafeArea {
    static var bottom: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}

/// Pure fitted-height math (kept free of `UIScreen` so it is unit-testable).
///
/// Height = grabber band + header + measured content. The popup's surface
/// background separately extends through the home-indicator band (ignores the
/// bottom safe area), so that band is not part of the layout height. A long list
/// is capped and scrolls instead.
enum PopupHeight {
    /// - Parameters:
    ///   - contentHeight: measured intrinsic height of the scroll content (`0`
    ///     before the first layout pass, which yields `fallbackHeight`).
    ///   - fixedHeight: non-scrolling parts (header + divider, navigation bar).
    ///   - grabberChrome: grabber band above the header (44pt tall hit area).
    ///   - minHeight / maxHeight: clamps.
    ///   - fallbackHeight: height for the first frame, before measurement lands.
    static func fitted(
        contentHeight: CGFloat,
        fixedHeight: CGFloat = 49,
        grabberChrome: CGFloat = 44,
        minHeight: CGFloat = 180,
        maxHeight: CGFloat,
        fallbackHeight: CGFloat = 360
    ) -> CGFloat {
        let ceiling = max(minHeight, maxHeight)
        guard contentHeight > 0 else {
            return min(max(fallbackHeight, minHeight), ceiling)
        }
        return min(max(grabberChrome + fixedHeight + contentHeight, minHeight), ceiling)
    }

    // MARK: Resizable popups (v0.2.8 task-2)

    /// One frame of a grabber resize drag.
    struct ResizeDrag: Equatable {
        /// Popup height for this drag frame, already clamped to [floor, ceiling].
        var height: CGFloat
        /// Pull past the resize floor. The popup renders it as a downward offset
        /// and dismisses once it passes the dismiss threshold.
        var overscroll: CGFloat
    }

    /// Dismiss thresholds, shared by every popup (unchanged from v0.2.0): a slow
    /// pull past 120pt or a fast fling past a 260pt predicted translation closes
    /// the sheet. For resizable popups both are measured *below the floor*, since
    /// the first stretch downwards shrinks instead of dismissing.
    static let dismissThreshold: CGFloat = 120
    static let flingDismissThreshold: CGFloat = 260

    /// Resize bounds of a resizable popup, derived from the screen height.
    ///
    /// The floor is a fixed comfort height (max(240pt, 32% of the screen)) and is
    /// deliberately independent of the content: content scrolls inside the popup,
    /// so a long diff never takes away the user's ability to drag the sheet back
    /// down. The ceiling is ~92% of the screen.
    struct ResizeBounds: Equatable {
        var floor: CGFloat
        var ceiling: CGFloat
    }

    static let minResizeFloor: CGFloat = 240
    static let minResizeFloorFraction: CGFloat = 0.32
    static let maxHeightFraction: CGFloat = 0.92
    /// Auto-expand band used when an inline diff opens: a popup shorter than 55%
    /// of the screen jumps to 65% so the diff is readable right away; the user
    /// can still drag it up or down freely afterwards.
    static let autoExpandBelowFraction: CGFloat = 0.55
    static let autoExpandFraction: CGFloat = 0.65

    /// Fixed resize bounds for a screen height (portrait-only app, so stable).
    static func resizeBounds(
        screenHeight: CGFloat,
        minFloor: CGFloat = minResizeFloor,
        floorFraction: CGFloat = minResizeFloorFraction,
        maxFraction: CGFloat = maxHeightFraction
    ) -> ResizeBounds {
        let screen = max(screenHeight, minFloor)
        let ceiling = screen * maxFraction
        let floor = min(max(minFloor, screen * floorFraction), ceiling)
        return ResizeBounds(floor: floor, ceiling: ceiling)
    }

    /// Height a resizable popup uses while the user has not dragged it: the
    /// content-fitted height clamped into the resize bounds.
    static func initialHeight(fittedHeight: CGFloat, bounds: ResizeBounds) -> CGFloat {
        min(max(fittedHeight, bounds.floor), bounds.ceiling)
    }

    /// Resolves the laid-out height of a resizable popup: the user's height when
    /// they resized it, otherwise the content-fitted default. Both are clamped to
    /// the fixed resize bounds, so a tall diff can always be dragged back down.
    static func resolvedHeight(
        userHeight: CGFloat?,
        fittedHeight: CGFloat,
        bounds: ResizeBounds
    ) -> CGFloat {
        guard let userHeight else {
            return initialHeight(fittedHeight: fittedHeight, bounds: bounds)
        }
        return min(max(userHeight, bounds.floor), bounds.ceiling)
    }

    /// Maps a grabber drag translation to the next popup height.
    ///
    /// - Upward drag (negative translation) grows the popup up to the ceiling.
    /// - Downward drag shrinks it down to the fixed floor.
    /// - Anything further down becomes overscroll (> 0); the popup follows the
    ///   finger from there and dismisses past the threshold.
    static func resizeDrag(
        startHeight: CGFloat,
        translation: CGFloat,
        bounds: ResizeBounds
    ) -> ResizeDrag {
        let target = startHeight - translation // drag up (negative) grows
        if target < bounds.floor {
            return ResizeDrag(height: bounds.floor, overscroll: bounds.floor - target)
        }
        return ResizeDrag(height: min(target, bounds.ceiling), overscroll: 0)
    }

    /// Height to animate to when content expands (an inline diff opens). Only
    /// raises a popup that is still shorter than the auto-expand threshold.
    static func autoExpandHeight(
        currentHeight: CGFloat,
        screenHeight: CGFloat,
        bounds: ResizeBounds
    ) -> CGFloat {
        let screen = max(screenHeight, minResizeFloor)
        guard currentHeight < screen * autoExpandBelowFraction else { return currentHeight }
        let target = screen * autoExpandFraction
        return min(max(target, bounds.floor), bounds.ceiling)
    }
}

/// Preference declared by a popup's content: the user may drag this popup taller.
///
/// Opt-in only — sheets that never call sheetResizable() keep the v0.2.0
/// behaviour (fixed content-fitted height, drag down to dismiss).
struct SheetResizableKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Opts this popup's content into grabber resize: drag up to grow past the
    /// content height, drag down to shrink back toward the fixed floor, drag
    /// further down to dismiss. Forwarded by BottomSheetLayer to BottomSheetPopup.
    func sheetResizable() -> some View {
        preference(key: SheetResizableKey.self, value: true)
    }
}

/// Preference asking a resizable popup to grow to a comfortable height because
/// its content just expanded (a file row opening its inline diff). The integer is
/// a request counter: every increment asks for one auto-expand.
struct SheetExpandKey: PreferenceKey {
    static var defaultValue: Int = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Asks the enclosing resizable popup to auto-expand (see SheetExpandKey).
    func sheetExpandRequest(_ request: Int) -> some View {
        preference(key: SheetExpandKey.self, value: request)
    }
}

extension View {
    /// Reports this view's intrinsic height to the enclosing popup. Put it on the
    /// content *inside* the popup's `ScrollView`.
    func measureSheetContentHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SheetContentHeightKey.self,
                    value: proxy.size.height
                )
            }
        )
    }

    /// Caps a greedy scroll view at its measured content height (used by the
    /// interaction panel, whose outer frame only sets an upper bound).
    func fitHeightToMeasuredContent(maxHeight: CGFloat? = nil) -> some View {
        modifier(MeasuredContentFrameModifier(cap: maxHeight))
    }
}

private struct MeasuredContentFrameModifier: ViewModifier {
    var cap: CGFloat?
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
            .frame(maxHeight: measuredCap)
    }

    private var measuredCap: CGFloat? {
        guard contentHeight > 0 else { return cap }
        guard let cap else { return contentHeight }
        return min(contentHeight, cap)
    }
}

// MARK: - Shared header

/// Shared header of every popup: one title style and one optional back control.
/// Popups are dismissed by dragging the grabber down, so there is no close button.
struct SheetHeader<Trailing: View>: View {
    var title: String
    var icon: String?
    var onBack: (() -> Void)?
    var titleIdentifier: String?
    var backIdentifier: String?
    @ViewBuilder var trailing: () -> Trailing

    /// Header height without the 1pt divider.
    static var height: CGFloat { 48 }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(backIdentifier ?? "sheet-header-back")
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier(titleIdentifier ?? "sheet-header-title")
            Spacer(minLength: Theme.Spacing.xs)
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: Self.height)
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(
        title: String,
        icon: String? = nil,
        onBack: (() -> Void)? = nil,
        titleIdentifier: String? = nil,
        backIdentifier: String? = nil
    ) {
        self.init(
            title: title,
            icon: icon,
            onBack: onBack,
            titleIdentifier: titleIdentifier,
            backIdentifier: backIdentifier,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - The popup container

/// One unified bottom popup (sheets and the interaction panel share this surface).
///
/// Layout top → bottom: grabber (20pt from the top edge, draggable down to
/// dismiss) — content — home-indicator band. The surface spans the full screen
/// width and ends at the physical bottom edge; its height is the measured content
/// height plus that band (capped so long content scrolls).
///
/// iOS 26 renders partial-height system sheets as inset floating cards, which is
/// why this is a custom overlay instead of `.sheet`.
struct BottomSheetPopup<Content: View>: View {
    /// Called when the grabber is dragged down past the dismiss threshold.
    var onDismiss: () -> Void
    /// Measured content height in points (from measureSheetContentHeight).
    var contentHeight: CGFloat
    /// v0.2.8 task-2: opt-in grabber resize, declared by the content with
    /// sheetResizable(). Non-resizable popups keep the v0.2.0 behaviour.
    var isResizable: Bool = false
    /// Auto-expand request counter from the content (see SheetExpandKey).
    var expandRequest: Int = 0
    @ViewBuilder var content: () -> Content

    /// Full-width hit area for the grabber; the bar itself sits 20pt from the top.
    static var grabberAreaHeight: CGFloat { 44 }
    static var grabberBarHeight: CGFloat { 4 }
    static var chrome: CGFloat { grabberAreaHeight }

    @State private var dragOffset: CGFloat = 0
    /// User-chosen height after the last resize drag (nil = follow content).
    @State private var userHeight: CGFloat?
    /// Height captured at drag start; the math stays relative to it so the popup
    /// tracks the finger 1:1 instead of rebasing every frame.
    @State private var dragStartHeight: CGFloat?
    /// Height during an active resize drag (nil = not dragging).
    @State private var dragHeight: CGFloat?

    private var screenHeight: CGFloat {
        UIScreen.main.bounds.height
    }

    /// Fixed resize bounds: floor = content-independent comfort height,
    /// ceiling = ~92% of the screen.
    private var resizeBounds: PopupHeight.ResizeBounds {
        PopupHeight.resizeBounds(screenHeight: screenHeight)
    }

    /// Content-fitted height, capped at the resize ceiling. It is NOT the resize
    /// floor: the floor is a fixed comfort height, so long content (a tall diff)
    /// can still be dragged back down.
    private var fittedHeight: CGFloat {
        PopupHeight.fitted(
            contentHeight: contentHeight,
            fixedHeight: SheetHeader<EmptyView>.height + 1,
            grabberChrome: Self.chrome,
            maxHeight: resizeBounds.ceiling
        )
    }

    /// Height actually laid out: active drag > user-chosen > content-fitted.
    /// Non-resizable popups keep the v0.2.0 content-fitted height untouched.
    private var laidOutHeight: CGFloat {
        if let dragHeight { return dragHeight }
        guard isResizable else { return fittedHeight }
        return PopupHeight.resolvedHeight(
            userHeight: userHeight,
            fittedHeight: fittedHeight,
            bounds: resizeBounds
        )
    }

    /// Grabber drag. Non-resizable popups keep the v0.2.0 behaviour (follow the
    /// finger down, dismiss past the threshold). Resizable popups resize first and
    /// only treat the pull past the fixed resize floor as a dismiss gesture.
    private var grabberDragGesture: some Gesture {
        // Global coordinate space: the popup moves with the finger, so a
        // local-space gesture would keep rebasing its translation and make the
        // popup oscillate instead of following the drag.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard isResizable else {
                    dragOffset = max(0, value.translation.height)
                    return
                }
                let start = dragStartHeight ?? laidOutHeight
                if dragStartHeight == nil { dragStartHeight = start }
                let drag = PopupHeight.resizeDrag(
                    startHeight: start,
                    translation: value.translation.height,
                    bounds: resizeBounds
                )
                dragHeight = drag.height
                dragOffset = drag.overscroll
            }
            .onEnded { value in
                guard isResizable else {
                    let shouldDismiss = value.translation.height > PopupHeight.dismissThreshold
                        || value.predictedEndTranslation.height > PopupHeight.flingDismissThreshold
                    if shouldDismiss {
                        onDismiss()
                    } else {
                        withAnimation(Theme.Motion.quick) { dragOffset = 0 }
                    }
                    return
                }
                let start = dragStartHeight ?? laidOutHeight
                let end = PopupHeight.resizeDrag(
                    startHeight: start,
                    translation: value.translation.height,
                    bounds: resizeBounds
                )
                let predicted = PopupHeight.resizeDrag(
                    startHeight: start,
                    translation: value.predictedEndTranslation.height,
                    bounds: resizeBounds
                )
                dragStartHeight = nil
                let shouldDismiss = end.overscroll > PopupHeight.dismissThreshold
                    || predicted.overscroll > PopupHeight.flingDismissThreshold
                if shouldDismiss {
                    onDismiss()
                } else {
                    userHeight = end.height
                    withAnimation(Theme.Motion.quick) {
                        dragHeight = nil
                        dragOffset = 0
                    }
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
                .gesture(grabberDragGesture)
            content()
        }
        .frame(maxWidth: .infinity)
        .frame(height: laidOutHeight, alignment: .top)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.xl,
                topTrailingRadius: Theme.Radius.xl,
                style: .continuous
            )
            .fill(Theme.Palette.surfaceRaised)
            // Paints the home-indicator band with the popup colour so the popup
            // visually reaches the physical bottom edge.
            .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: dragOffset)
        .onChange(of: expandRequest) { _, _ in
            autoExpandIfNeeded()
        }
    }

    /// Grows the popup into the comfortable auto-expand band when the content
    /// asks for it (an inline diff just opened) and the sheet is still short.
    /// A user who already dragged it higher is left alone; dragging up and down
    /// stays free afterwards.
    private func autoExpandIfNeeded() {
        guard isResizable else { return }
        let current = laidOutHeight
        let target = PopupHeight.autoExpandHeight(
            currentHeight: current,
            screenHeight: screenHeight,
            bounds: resizeBounds
        )
        guard target > current + 0.5 else { return }
        withAnimation(Theme.Motion.standard) { userHeight = target }
    }

    private var grabber: some View {
        Capsule()
            .fill(Theme.Palette.borderStrong)
            .frame(width: 36, height: Self.grabberBarHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("sheet-grabber")
            .accessibilityLabel(L10n.t("下滑收起"))
            .frame(height: Self.grabberAreaHeight)
    }
}

/// Scrim + bottom-anchored popup, drawn above the session screen and reaching the
/// physical bottom edge. Tapping the scrim also dismisses.
struct BottomSheetLayer<Content: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var isResizable = false
    @State private var expandRequest = 0
    @State private var hasMeasuredContent = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .accessibilityIdentifier("sheet-scrim")
            BottomSheetPopup(
                onDismiss: onDismiss,
                contentHeight: contentHeight,
                isResizable: isResizable,
                expandRequest: expandRequest,
                content: content
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(SheetContentHeightKey.self) { height in
            // v0.2.8 task-2: a resizable sheet glides when its content grows (an
            // inline diff expanding); every other sheet keeps the instant follow.
            // The first measurement is never animated so opening does not bounce.
            if isResizable, hasMeasuredContent {
                withAnimation(Theme.Motion.standard) { contentHeight = height }
            } else {
                contentHeight = height
            }
            hasMeasuredContent = true
        }
        .onPreferenceChange(SheetResizableKey.self) { isResizable = $0 }
        .onPreferenceChange(SheetExpandKey.self) { expandRequest = $0 }
    }
}
