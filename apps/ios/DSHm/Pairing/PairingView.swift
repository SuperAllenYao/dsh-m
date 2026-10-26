import SwiftUI

/// Pairing entry (M2a, design §5.6): QR scanner first, then the 8-digit pairing
/// code flow and the remote-relay server config; the legacy manual form lives
/// under 「高级 / 排障」.
struct PairingView: View {
    @EnvironmentObject private var app: AppModel

    @State private var showManual = false
    @State private var showCodeEntry = false
    @State private var showRelayConfig = false
    @State private var manualPrefill: String?
    @State private var isPairing = false
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var cameraUnavailable = false
    @State private var advancedExpanded = false
    @State private var relayConfig: RelayServerConfig? = RelayConfigStore.load()

    private var scannerUnavailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return cameraUnavailable
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                BrandMark()
                    .padding(.top, Theme.Spacing.xs)

                ScreenTitle(title: "连接 Mac", subtitle: "扫描 Mac 上 DSH 的配对二维码，或输入 8 位配对码")

                scannerCard

                HStack(spacing: Theme.Spacing.xs) {
                    StatusDot(color: statusColor, size: 6, pulsing: isPairing)
                    Text(statusText)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pair-status")

                if let errorText {
                    InlineErrorView(message: errorText)
                        .accessibilityIdentifier("pair-error")
                }
                if let infoText {
                    InlineInfoView(message: infoText)
                        .accessibilityIdentifier("pair-info")
                }

                VStack(spacing: Theme.Spacing.s) {
                    Button {
                        showCodeEntry = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "number.square")
                                .font(.system(size: 14, weight: .semibold))
                            Text("输入 8 位配对码")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(glow: true))
                    .accessibilityIdentifier("pair-code-entry")

                    Button {
                        showRelayConfig = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "network")
                                .font(.system(size: 13, weight: .semibold))
                            Text(relayConfig.map { L10n.f("远程服务器 · %@", $0.displayTarget) } ?? L10n.t("配置远程服务器"))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textSecondary, border: Theme.Palette.border))
                    .accessibilityIdentifier("relay-config-entry")
                    .accessibilityValue(relayConfig?.displayTarget ?? L10n.t("未配置"))
                }

                advancedSection

                Text("配对后设备凭据保存在钥匙串；App 只连接你扫码的这台 Mac。")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, Theme.Spacing.pageInset)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showManual) {
            ManualPairingView(prefill: manualPrefill) {
                app.didPair()
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showCodeEntry) {
            PairingCodeEntryView()
                .environmentObject(app)
        }
        .sheet(isPresented: $showRelayConfig) {
            RelayServerConfigView { config in
                relayConfig = config
                infoText = config.map { L10n.f("已保存远程服务器配置：%@", $0.displayTarget) }
                errorText = nil
            }
        }
        .onAppear {
 // E2E scaffolding (env-gated, no product behavior): DSHM_E2E=1
 // expands the advanced/troubleshooting fold so the existing
 // real-device pairing test reaches the manual form.
            if app.isE2EMode || app.envPairingPayload != nil {
                advancedExpanded = true
            }
            relayConfig = RelayConfigStore.load()
            guard let payload = app.envPairingPayload, app.link.credentials == nil else { return }
 // E2E scaffolding (env-gated, no product behavior): DSHM_AUTOPAIR=1
 // pairs directly from the launch payload for simulator smoke runs.
            if ProcessInfo.processInfo.environment["DSHM_AUTOPAIR"] == "1" {
                autoPair(text: payload)
            } else {
                openManual(prefill: payload)
            }
        }
        .onChange(of: app.link.phase) { phase in
            if phase.isConnected {
                app.didPair()
            }
        }
    }

 // MARK: - Scanner card

    private var scannerCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Theme.Palette.surface)
            if scannerUnavailable {
                placeholder
            } else {
                QRScannerView(
                    onCode: { code in handleScan(code) },
                    onUnavailable: { cameraUnavailable = true }
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                ScannerCorners()
                    .padding(Theme.Spacing.xl)
            }
        }
        .frame(height: 300)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("pair-scanner")
    }

    private var placeholder: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("相机不可用")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("模拟器没有摄像头：请使用「输入 8 位配对码」，或在「高级 / 排障」里粘贴配对载荷。")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button {
                withAnimation(Theme.Motion.quick) {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text("高级 / 排障")
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pair-advanced-toggle")

            if advancedExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Button {
                        openManual(prefill: nil)
                    } label: {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text("手动配对（配对载荷 / 一次性配对码）")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.textSecondary, border: Theme.Palette.border))
                    .accessibilityIdentifier("pair-manual-button")

                    Text("排障用：粘贴 dsh-m.pair 配对载荷 JSON，或手填 origin + 一次性配对码。")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
    }

    private var statusColor: Color {
        if isPairing { return Theme.Palette.warning }
        if case .needsRepair = app.link.phase { return Theme.Palette.danger }
        return Theme.Palette.accent
    }

    private var statusText: String {
        if isPairing { return L10n.t("正在配对…") }
 // Spec §3 A4/A5: after a failed attempt the scanner is armed again (it
 // resets 1.25 s after each delivery); tell the user, generically, that a
 // rescan is possible — no link-type wording.
        if errorText != nil { return L10n.t("可重新扫描二维码") }
        switch app.link.phase {
        case .connected: return L10n.t("已配对，正在进入工作区")
        case .reconnecting: return L10n.t("已配对，正在重连")
        case .connecting: return L10n.t("已配对，正在连接")
        case .needsRepair(let reason): return reason
        default: return L10n.t("等待扫描")
        }
    }

 // MARK: - Actions

    private func openManual(prefill: String?) {
        manualPrefill = prefill
        showManual = true
    }

    private func autoPair(text: String) {
        guard let payload = PairingPayload.parse(text) else {
            errorText = L10n.t("启动参数中的配对载荷不是合法 JSON")
            return
        }
        pair(payload: payload)
    }

    private func handleScan(_ code: String) {
        guard !isPairing else { return }
        if RelayServerConfig.looksLikeRelayConfig(code) {
            saveRelayConfig(text: code)
            return
        }
        guard let payload = PairingPayload.parse(code) else {
            errorText = L10n.t("二维码不是 DSH-m 配对载荷")
            return
        }
        pair(payload: payload)
    }

    private func saveRelayConfig(text: String) {
        switch RelayServerConfig.parse(text) {
        case .success(let config):
            RelayConfigStore.save(config)
            relayConfig = config
            errorText = nil
            infoText = L10n.f("已保存远程服务器配置：%@", config.displayTarget)
        case .failure(let error):
            errorText = error.message
        case .none:
            errorText = L10n.t("不是 dshm-relay:// 服务器配置")
        }
    }

    private func pair(payload: PairingPayload) {
        isPairing = true
        errorText = nil
        infoText = nil
        Task {
            do {
                _ = try await app.link.pair(payload: payload, deviceName: AppSettings.deviceName)
                isPairing = false
                relayConfig = RelayConfigStore.load()
                app.didPair()
            } catch {
                errorText = error.localizedDescription
                isPairing = false
            }
        }
    }
}

/// Lightweight positive/informational banner (sibling of InlineErrorView).
struct InlineInfoView: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.accentBorder, lineWidth: 1)
        )
    }
}

/// Four corner brackets framing the QR viewfinder (no scan-line noise, per baseline).
struct ScannerCorners: View {
    var color: Color = Theme.Palette.accent.opacity(0.7)
    var length: CGFloat = 22
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            Path { path in
 // top-left
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
 // top-right
                path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
 // bottom-right
                path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
 // bottom-left
                path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

#Preview {
    PairingView().environmentObject(AppModel())
}
