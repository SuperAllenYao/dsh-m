import SwiftUI
import UIKit
import UserNotifications

/// Settings (v5.1+ / 体验收尾 task-2): connection management + diagnostics,
/// remote relay server, push permission/registration, local cache, language,
/// version/device info, and destructive-action confirmations.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showRelayConfig = false
    @State private var relayConfig: RelayServerConfig? = RelayConfigStore.load()

 // MARK: - Phase 2 (设置页完善) local UI state

    @State private var showRevokeConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var showDiagnostics = false
    @State private var didCopyDiagnostics = false
 /// System notification authorization, read via getNotificationSettings().
    @State private var notificationAuthorization: UNAuthorizationStatus?
 /// Bytes on disk under `CacheIO.defaultDirectory()`; nil = not readable yet.
    @State private var cacheBytes: Int64?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    connectionSection
                    relaySection
                    pushSection
                    cacheSection
                    languageSection
                    aboutSection
                }
                .padding(Theme.Spacing.pageInset)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("settings-close")
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showRelayConfig) {
            RelayServerConfigView { config in
                relayConfig = config
            }
        }
        .onAppear {
            relayConfig = RelayConfigStore.load()
        }
        .task {
            await refreshNotificationAuthorization()
            refreshCacheSize()
        }
    }

 // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "连接")
            VStack(spacing: 0) {
                infoRow(title: "状态", value: app.link.phase.label)
                    .accessibilityIdentifier("settings-conn-status")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "地址", value: app.link.credentials?.origin ?? L10n.t("未配对"))
                    .accessibilityIdentifier("settings-conn-origin")
                if let credentials = app.link.credentials {
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "设备", value: String(credentials.deviceId.prefix(13)) + "…")
                        .accessibilityIdentifier("settings-conn-device")
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "证书 pin", value: String(credentials.leafPin.prefix(16)) + "…")
                        .accessibilityIdentifier("settings-conn-pin")
                }
                if !app.link.statusDetail.isEmpty {
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "最近错误", value: app.link.statusDetail, danger: true)
                        .accessibilityIdentifier("settings-conn-error")
                }
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            HStack(spacing: Theme.Spacing.s) {
                Button("重新连接") { app.link.reconnectNow() }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textPrimary, border: Theme.Palette.borderStrong))
                    .disabled(app.link.credentials == nil)
                    .accessibilityIdentifier("settings-reconnect")
                Button("断开") { app.link.disconnect(clearCredentials: false) }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textSecondary, border: Theme.Palette.border))
                    .disabled(app.link.credentials == nil)
                    .accessibilityIdentifier("settings-disconnect")
            }

            Button(role: .destructive) {
                showRevokeConfirm = true
            } label: {
                Text("撤销配对并清除凭据")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.danger, border: Theme.Palette.dangerBorder))
            .disabled(app.link.credentials == nil)
            .accessibilityIdentifier("settings-revoke")
            .confirmationDialog(
                L10n.t("撤销配对并清除本机凭据？"),
                isPresented: $showRevokeConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("撤销配对"), role: .destructive) {
                    app.link.clearPairing()
                    dismiss()
                }
                .accessibilityIdentifier("settings-revoke-confirm")
                Button(L10n.t("取消"), role: .cancel) {}
                    .accessibilityIdentifier("settings-revoke-cancel")
            } message: {
                Text(L10n.t("删除后需在 Mac 上重新扫码配对，正在进行的连接会断开。此操作无法撤销。"))
            }

            Text("撤销后本机凭据立即删除；桌面端可在 DSH-m 手机连接页同时移除设备。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)

            diagnosticsBlock
        }
    }

 /// Connection diagnostics (inline expand, no sheet): the four summary rows are
 /// always visible; the full detail list + copy button only when expanded.
    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "连接诊断")

            VStack(spacing: 0) {
                infoRow(title: "最近在线", value: lastConnectedText)
                    .accessibilityIdentifier("settings-diag-last-online")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "候选地址", value: candidateCountText)
                    .accessibilityIdentifier("settings-diag-candidates")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "连接标识", value: shortClientIdText)
                    .accessibilityIdentifier("settings-diag-client-id")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "待处理", value: pendingCountText)
                    .accessibilityIdentifier("settings-diag-pending")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "键盘延迟", value: keyboardLatencyText)
                    .accessibilityIdentifier("settings-diag-keyboard")
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showDiagnostics.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(showDiagnostics ? L10n.t("收起诊断详情") : L10n.t("查看诊断详情"))
                    Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                        .font(Theme.Typography.captionMedium)
                }
                .font(Theme.Typography.captionMedium)
                .foregroundStyle(Theme.Palette.accent)
            }
            .accessibilityIdentifier("settings-diag-toggle")

            if showDiagnostics {
                VStack(spacing: 0) {
                    detailRow(title: "完整地址", value: app.link.credentials?.origin ?? "—", lineLimit: 3)
                        .accessibilityIdentifier("settings-diag-origin-full")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(title: "证书 pin", value: app.link.credentials?.leafPin ?? "—", lineLimit: 3)
                        .accessibilityIdentifier("settings-diag-pin-full")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(title: "设备 id", value: app.link.credentials?.deviceId ?? "—", lineLimit: 3)
                        .accessibilityIdentifier("settings-diag-device-full")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(title: "候选地址", value: candidateListText, lineLimit: 4)
                        .accessibilityIdentifier("settings-diag-candidate-list")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(title: "连接标识", value: app.link.clientId ?? "—", lineLimit: 3)
                        .accessibilityIdentifier("settings-diag-client-id-full")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(title: "配对时间", value: pairedAtText, lineLimit: 2)
                        .accessibilityIdentifier("settings-diag-paired-at")
                    Divider().overlay(Theme.Palette.border)
                    detailRow(
                        title: "最近错误",
                        value: app.link.statusDetail.isEmpty ? "—" : app.link.statusDetail,
                        lineLimit: 5,
                        danger: !app.link.statusDetail.isEmpty
                    )
                    .accessibilityIdentifier("settings-diag-error-full")
                }
                .padding(Theme.Spacing.s)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
                .accessibilityIdentifier("settings-diag-details")

                Button {
                    copyDiagnostics()
                } label: {
                    Text(didCopyDiagnostics ? L10n.t("已复制") : L10n.t("复制诊断信息"))
                }
                .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textPrimary, border: Theme.Palette.borderStrong))
                .accessibilityIdentifier("settings-diag-copy")
            }

            Text("诊断信息仅包含本机保存的连接元数据（地址/证书 pin/设备 id），不含会话内容。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - Remote relay server (M2a §5.4)

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "远程服务器")
            VStack(spacing: 0) {
                infoRow(
                    title: "状态",
                    value: relayConfig.map { L10n.f("已配置 · %@", $0.displayTarget) } ?? L10n.t("未配置")
                )
                .accessibilityIdentifier("settings-relay-status")
                if let relayConfig {
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "证书 pin", value: relayConfig.shortPin)
                        .accessibilityIdentifier("settings-relay-pin")
                }
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            Button("配置远程服务器") { showRelayConfig = true }
                .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textPrimary, border: Theme.Palette.borderStrong))
                .accessibilityIdentifier("settings-relay-config")

            Text("公网配对需要：Mac 插件已连接自建中继服务器，且这里已保存服务器配置（dshm-relay://）。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - Push notifications

    private var pushSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "通知")
            VStack(spacing: 0) {
                infoRow(title: "APNs 状态", value: app.push.status.label)
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "通知权限", value: notificationAuthorizationLabel)
                    .accessibilityIdentifier("settings-notif-permission")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "审批动作分类", value: L10n.t("已注册（允许 / 拒绝）"))
                    .accessibilityIdentifier("settings-notif-category")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "设备 token", value: app.push.deviceTokenHex.map { String($0.prefix(8)) + "…" } ?? "—")
                    .accessibilityIdentifier("settings-notif-token")
                if let registration = app.push.registration {
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "注册模式", value: (registration.mode ?? "—") + " · " + (registration.environment ?? "—"))
                        .accessibilityIdentifier("settings-notif-mode")
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "topic", value: registration.topic ?? "—")
                        .accessibilityIdentifier("settings-notif-topic")
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "token 指纹", value: registration.tokenFingerprint ?? "—")
                        .accessibilityIdentifier("settings-notif-fingerprint")
                }
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            HStack(spacing: Theme.Spacing.s) {
                if notificationAuthorization == .denied {
                    Button("去系统设置") { openSystemSettings() }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textPrimary, border: Theme.Palette.borderStrong))
                        .accessibilityIdentifier("settings-notif-open-settings")
                } else {
                    Button("请求通知权限") { requestNotificationAuthorization() }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textPrimary, border: Theme.Palette.borderStrong))
                        .accessibilityIdentifier("settings-push-permission")
                }
                Button("重新注册") { app.push.reRegister() }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textSecondary, border: Theme.Palette.border))
                    .disabled(app.push.deviceTokenHex == nil)
                    .accessibilityIdentifier("settings-push-reregister")
            }

            if notificationAuthorization == .denied {
                Text("系统通知权限已被拒绝，App 内无法再次弹窗授权；请在系统设置中开启通知。")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
                    .accessibilityIdentifier("settings-notif-denied-hint")
            }

            Text("通知仅含类型/工具名与会话 id，不含正文；点击通知打开对应会话。模拟器无法接收真实 APNs（仅真机验证）。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - Local cache / data

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "缓存与数据")
            VStack(spacing: 0) {
                infoRow(title: "缓存占用", value: cacheSizeText)
                    .accessibilityIdentifier("settings-cache-size")
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            Button(role: .destructive) {
                showClearCacheConfirm = true
            } label: {
                Text("清除缓存")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.danger, border: Theme.Palette.dangerBorder))
            .accessibilityIdentifier("settings-cache-clear")
            .confirmationDialog(
                L10n.t("清除本地缓存？"),
                isPresented: $showClearCacheConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("清除"), role: .destructive) {
                    clearLocalCache()
                }
                .accessibilityIdentifier("settings-cache-clear-confirm")
                Button(L10n.t("取消"), role: .cancel) {}
                    .accessibilityIdentifier("settings-cache-clear-cancel")
            } message: {
                Text(L10n.t("将清除列表快照与会话窗口快照，不影响配对凭据和远程服务器配置；下次启动会重新从 Mac 加载。"))
            }

            Text("缓存仅用于列表与会话秒开，最多保留 7 天，超期自动清理。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "语言")
            Picker("语言", selection: $app.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-language")
            Text("切换后立即生效；英文翻译覆盖主要界面文案，工具/事件细节仍以中文展示。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "关于")
            VStack(spacing: 0) {
                infoRow(title: "DSH-m", value: appVersion)
                    .accessibilityIdentifier("settings-app-version")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "构建", value: buildConfiguration)
                    .accessibilityIdentifier("settings-build")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "Link 协议", value: "dsh-m/1")
                    .accessibilityIdentifier("settings-link-protocol")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "传输", value: "HTTPS + WSS · TLS pin")
                    .accessibilityIdentifier("settings-transport")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "系统", value: systemVersionText)
                    .accessibilityIdentifier("settings-system")
                Divider().overlay(Theme.Palette.border)
                infoRow(title: "设备名称", value: AppSettings.deviceName)
                    .accessibilityIdentifier("settings-device-name")
                if let credentials = app.link.credentials {
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "配对设备", value: credentials.deviceName.isEmpty ? "—" : credentials.deviceName)
                        .accessibilityIdentifier("settings-paired-device")
                    Divider().overlay(Theme.Palette.border)
                    infoRow(title: "配对时间", value: pairedAtText)
                        .accessibilityIdentifier("settings-paired-time")
                }
            }
            .padding(Theme.Spacing.s)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            Text("远端 Mac 插件版本未在握手阶段返回，暂不展示。")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

 // MARK: - Diagnostics values

    private var candidateCountText: String {
        let count = app.link.credentials?.originCandidates?.count ?? 0
        return count == 0 ? "—" : L10n.f("%lld 个地址", count)
    }

    private var candidateListText: String {
        let candidates = app.link.credentials?.originCandidates ?? []
        return candidates.isEmpty ? "—" : candidates.joined(separator: "\n")
    }

    private var shortClientIdText: String {
        guard let clientId = app.link.clientId, !clientId.isEmpty else { return "—" }
        return String(clientId.prefix(8)) + "…"
    }

    private var pendingCountText: String {
        L10n.f("审批 %lld · 作答 %lld", app.link.pendingApprovals.count, app.link.pendingUserQuestions.count)
    }

 /// task-2 keyboard-latency probe: latest sample summary, e.g.
 /// "willShow 42ms · didShow 180ms · mainQueue 3ms"; "—" when the probe is
 /// disabled (no DSHM_KEYBOARD_PROBE=1) or has not recorded a cycle yet.
    private var keyboardLatencyText: String {
        KeyboardLatencyProbe.lastMetricsText ?? "—"
    }

    private var lastConnectedText: String {
        guard let date = app.link.lastConnectedAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.displayLocale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var pairedAtText: String {
        guard let credentials = app.link.credentials else { return "—" }
        let date = Date(timeIntervalSince1970: Double(credentials.pairedAt) / 1000)
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.displayLocale)
        )
    }

    private var notificationAuthorizationLabel: String {
        guard let status = notificationAuthorization else { return "—" }
        switch status {
        case .authorized: return L10n.t("已允许")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined: return L10n.t("未询问")
        case .provisional, .ephemeral: return L10n.t("临时允许")
        @unknown default: return L10n.t("未知")
        }
    }

    private var cacheSizeText: String {
        guard let cacheBytes else { return "—" }
        guard cacheBytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    private var systemVersionText: String {
        "iOS \(UIDevice.current.systemVersion)"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return version + " (" + build + ")"
    }

 // MARK: - Actions

    private func requestNotificationAuthorization() {
        app.push.requestAuthorization()
 // The system prompt result is not awaitable here; re-read the settings once
 // the user has had time to answer so the authorization row updates.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshNotificationAuthorization()
        }
    }

    @MainActor
    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorization = settings.authorizationStatus
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshCacheSize() {
        cacheBytes = Self.directorySize(at: CacheIO.defaultDirectory())
    }

 /// Removes every file in `Caches/DSHmCache` (list snapshot + render snapshot +
 /// session-window snapshots). Pairing credentials (Keychain) and UserDefaults
 /// settings are untouched; these caches are accelerators and reload from the Mac.
    private func clearLocalCache() {
        let directory = CacheIO.defaultDirectory()
        if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in items {
                CacheIO.remove(url)
            }
        }
        refreshCacheSize()
    }

    private static func directorySize(at directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticText
        didCopyDiagnostics = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopyDiagnostics = false
        }
    }

 /// Plain-text snapshot for support/debugging: only local connection metadata.
    private var diagnosticText: String {
        var lines: [String] = []
        lines.append(L10n.t("连接诊断"))
        lines.append("App: \(appVersion)")
        lines.append("iOS: \(UIDevice.current.systemVersion) (\(UIDevice.current.model))")
        lines.append("\(L10n.t("状态")): \(app.link.phase.label)")
        if let credentials = app.link.credentials {
            lines.append("\(L10n.t("地址")): \(credentials.origin)")
            lines.append("\(L10n.t("设备")): \(credentials.deviceId)")
            lines.append("\(L10n.t("证书 pin")): \(credentials.leafPin)")
            lines.append("generation: \(app.link.generation)")
        } else {
            lines.append("\(L10n.t("地址")): —")
        }
        lines.append("\(L10n.t("候选地址")): \(candidateListText.replacingOccurrences(of: "\n", with: ", "))")
        lines.append("\(L10n.t("连接标识")): \(app.link.clientId ?? "—")")
        lines.append("\(L10n.t("最近在线")): \(lastConnectedText)")
        lines.append("\(L10n.t("待处理")): \(pendingCountText)")
        lines.append("\(L10n.t("键盘延迟")): \(keyboardLatencyText)")
        lines.append("\(L10n.t("最近错误")): \(app.link.statusDetail.isEmpty ? "—" : app.link.statusDetail)")
        lines.append("\(L10n.t("远程服务器")): \(relayConfig?.displayTarget ?? L10n.t("未配置"))")
        lines.append("\(L10n.t("通知权限")): \(notificationAuthorizationLabel)")
        lines.append("APNs: \(app.push.status.label)")
        return lines.joined(separator: "\n")
    }

 // MARK: - Rows

    private func infoRow(title: String, value: String, danger: Bool = false) -> some View {
        infoRow(title: title, value: value, danger: danger, lineLimit: 2)
    }

    private func detailRow(title: String, value: String, lineLimit: Int, danger: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(L10n.t(title))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(danger ? Theme.Palette.danger : Theme.Palette.textPrimary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private func infoRow(title: String, value: String, danger: Bool, lineLimit: Int) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(L10n.t(title))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(danger ? Theme.Palette.danger : Theme.Palette.textPrimary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}
