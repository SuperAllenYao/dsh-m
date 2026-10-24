import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

 // MARK: - iOS edge-swipe back (requirement)

 /// >0 while the top detail follows the finger to the right.
    @State private var popOffset: CGFloat = 0
    @State private var popDragging = false
 /// A completed pop is animating out; further input is ignored.
    @State private var popSubmitted = false

 /// Whether the workspace list page has ever been the base page. It stays
 /// mounted from then on (see the comment in `body`); a cold-start deep link
 /// straight into a session does not pay the list's cache/network work behind
 /// the detail — the list mounts when the user first goes back to it.
    @State private var baseListMounted = false

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
 // (requirements #3/#4): the workspace list is the permanent base
 // page — it stays mounted while a session detail is on top. That removes
 // the 1-3s "returned list cannot scroll" freeze (the whole list + view
 // model used to be torn down and rebuilt) and lets the iOS left-edge
 // swipe-back reveal the live previous page under the finger.
            if shouldMountBaseList {
                WorkspaceListView()
                    .allowsHitTesting(!isSessionRoute)
                    .accessibilityHidden(isSessionRoute)
            }
            if case .session(let address) = app.route {
                sessionLayer(for: address)
            }
            if case .pairing = app.route {
                PairingView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.Palette.accent)
        .environment(\.locale, app.language.locale ?? Locale.current)
        .overlay(alignment: .bottom) {
            toastOverlay
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                e2ePushMarkers
                e2eFirstScreenMarkers
            }
        }
        .onChange(of: app.route) { route in
            if case .workspaces = route { baseListMounted = true }
            resetPopTransition()
        }
        .onAppear {
            if case .workspaces = app.route { baseListMounted = true }
        }
        .task {
            app.start()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
 // P0-5: reuse the live TLS/mux when possible; only reconnect when
 // the transport is actually down (decision lives in AppModel so it
 // is unit-testable and cannot duplicate an in-flight attempt).
                app.handleAppBecameActive()
                app.push.reRegister()
            case .background:
                app.handleAppEnteredBackground()
            default:
                break
            }
        }
    }

    private var isSessionRoute: Bool {
        if case .session = app.route { return true }
        return false
    }

 /// See `baseListMounted`: the list is the persistent base page once visited.
    private var shouldMountBaseList: Bool {
        if app.route == .pairing { return false }
        if case .workspaces = app.route { return true }
        return baseListMounted
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

 /// One session detail above the base page, with the interactive edge-pop
 /// transition (iOS swipe-back, requirement).
    @ViewBuilder
    private func sessionLayer(for address: SessionFollowAddress) -> some View {
        ZStack(alignment: .leading) {
            if app.subagentRoute != nil, let snapshot = app.backSnapshot {
 // Subagent detail: the parent page cannot stay mounted (a second live
 // detail would duplicate streams and pollute the E2E detail metrics),
 // so its frozen bitmap is revealed under the finger instead.
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            SessionDetailView(address: address, subagentContext: app.subagentRoute?.context)
 // Identity must change between sessions: route stays in the same
 // `.session` branch when moving parent -> subagent child, and SwiftUI
 // would otherwise keep the old SessionDetailView's StateObject (parent
 // viewModel) instead of reopening the child.
                .id(address.sessionId)
                .allowsHitTesting(!popDragging && !popSubmitted)
                .offset(x: popOffset)
 // Simultaneous: vertical scrolls keep going to the message list, and
 // only a horizontal drag that *starts* in the 22pt leading edge turns
 // into an interactive pop.
                .simultaneousGesture(popGesture)
        }
    }

    private var popGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard !popSubmitted else { return }
                if !popDragging {
 // Decision seams are pure (SessionPopGestureTests): the pop only
 // starts from the leading edge and only for a horizontal-dominant
 // drag; a vertical drag stays with the message list scroll view.
                    guard SessionPopGesture.beginsPop(
                        startX: value.startLocation.x,
                        translation: value.translation
                    ) else { return }
                    popDragging = true
                }
                popOffset = min(max(0, value.translation.width), screenWidth)
            }
            .onEnded { value in
                guard popDragging, !popSubmitted else {
                    popDragging = false
                    if !popSubmitted, popOffset != 0 {
                        withAnimation(reduceMotion ? nil : Theme.Motion.standard) { popOffset = 0 }
                    }
                    return
                }
                let shouldPop = SessionPopGesture.completesPop(
                    projectedTranslation: value.predictedEndTranslation.width,
                    velocity: value.velocity.width,
                    screenWidth: screenWidth
                )
                if shouldPop {
                    completePop()
                } else {
                    withAnimation(reduceMotion ? nil : Theme.Motion.standard) { popOffset = 0 }
                    popDragging = false
                }
            }
    }

 /// Slides the detail off to the right (revealing the previous page) and then
 /// performs the route change.
    private func completePop() {
        popSubmitted = true
        let duration: TimeInterval = reduceMotion ? 0 : 0.2
        withAnimation(reduceMotion ? nil : .easeOut(duration: duration)) {
            popOffset = screenWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            app.backFromSession()
            resetPopTransition()
        }
    }

    private func resetPopTransition() {
        popOffset = 0
        popDragging = false
        popSubmitted = false
    }

 /// M4 §3.5: transient feedback for notification-action approvals
 /// ("allowed" / "rejected" / fallback hint). Auto-dismissed by
 /// `AppModel.showToast`.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = app.toast {
            Text(toast)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: 1))
                .padding(.bottom, 48)
                .transition(.opacity)
                .accessibilityIdentifier("app-toast")
        }
    }

 /// E2E-only visibility markers: silent pushes
 /// received and the last notification-action approval result, read by the
 /// real-device release script. Hidden leaf elements — the container carries no
 /// accessibilityIdentifier (a container id would shadow them).
    @ViewBuilder
    private var e2ePushMarkers: some View {
        if app.isE2EMode {
            VStack(alignment: .leading, spacing: 0) {
                Text("push-sync-count")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("push-sync-count")
                    .accessibilityLabel(String(app.silentPushCount))
                    .accessibilityValue(String(app.silentPushCount))
                Text("push-approval-result")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("push-approval-result")
                    .accessibilityLabel(app.lastApprovalActionResult ?? "none")
                    .accessibilityValue(app.lastApprovalActionResult ?? "none")
            }
        }
    }

 /// E2E-only first-screen / foreground-resume evidence (P0-4/P0-5). Values are
 /// nil outside E2E, so production builds render nothing. Hidden leaf elements
 /// with their own identifiers; the VStack container carries no id (a 容
 /// a container id would shadow them).
    @ViewBuilder
    private var e2eFirstScreenMarkers: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let metrics = app.firstScreenMetricsValue {
                Text("first-screen-metrics")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("first-screen-metrics")
                    .accessibilityLabel(metrics)
                    .accessibilityValue(metrics)
            }
            if let metrics = app.foregroundMetricsValue {
                Text("foreground-metrics")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("foreground-metrics")
                    .accessibilityLabel(metrics)
                    .accessibilityValue(metrics)
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppModel())
}
