import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            if case .pairing = app.route {
                PairingView()
            } else {
 // (requirement): native iOS navigation. NavigationStack
 // is backed by UINavigationController, so the left-edge swipe and
 // the push/pop transition are Apple's own — the custom
 // DragGesture layer was removed. The workspace list is the stack
 // root and stays mounted under a pushed detail (the list is never
 // torn down while a session is open, so returning is instant).
                NavigationStack(path: navPath) {
                    WorkspaceListView()
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: SessionNavTarget.self) { target in
                            SessionDetailView(
                                address: target.address,
                                subagentContext: target.subagentContext
                            )
 // Identity must change between sessions (
 // device regression): when a deep link REPLACES the
 // top path element, the destination slot survives and
 // @StateObject would otherwise keep the previous
 // session's viewModel (title stayed on the old page).
                            .id(target.address.sessionId)
                            .toolbar(.hidden, for: .navigationBar)
 // Re-enable Apple's own edge-swipe pop (bar hidden =>
 // UIKit gates its recognizer; see the file header).
                            .background(SystemEdgePopBridge())
                        }
                }
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

 /// The stack path is a pure function of `route` + `subagentRoute`; pops the
 /// user drives (system back) write back through `applySessionNavPath`.
 /// Pushes only ever originate in the model, so the two can never fight.
    private var navPath: Binding<[SessionNavTarget]> {
        Binding(
            get: { app.sessionNavPath() },
            set: { app.applySessionNavPath($0) }
        )
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
 // E2E-only navigation debug trail (device app stdout is not captured
 // by xcodebuild; the hidden marker value is readable from the test).
            if app.isE2EMode {
                Text("nav-debug")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("nav-debug")
                    .accessibilityLabel("nav-debug")
                    .accessibilityValue(app.navDebugLog)
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppModel())
}
