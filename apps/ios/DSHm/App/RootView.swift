import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            switch app.route {
            case .pairing:
                PairingView()
            case .workspaces:
                WorkspaceListView()
            case .session(let address):
                SessionDetailView(address: address, subagentContext: app.subagentRoute?.context)
 // Identity must change between sessions: route stays in the
 // same `.session` branch when moving parent -> subagent child,
 // and SwiftUI would otherwise keep the old SessionDetailView's
 // StateObject (parent viewModel) instead of reopening the child.
                    .id(address.sessionId)
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
