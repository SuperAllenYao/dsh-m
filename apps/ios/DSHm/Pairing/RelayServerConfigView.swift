import SwiftUI

/// M2a 「远程服务器」配置 sheet: scan or paste the one-shot
/// `dshm-relay://<host>:<port>?pin=<b64url>&v=1` string printed by
/// `dshm-relay init` (design §5.4). Stored in UserDefaults; the pin is validated
/// when it is used for lookups, never trusted from the string alone.
struct RelayServerConfigView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var config: RelayServerConfig?
    @State private var text: String = ""
    @State private var errorText: String?
    @State private var showScanner = false
    @State private var cameraUnavailable = false
    /// Phase 2 (设置页完善): removing the saved relay config is destructive
    /// (public-network pairing stops working), so it needs a confirmation.
    @State private var showRemoveConfirm = false

    /// Called after save/removal with the new config (nil when removed).
    var onSaved: ((RelayServerConfig?) -> Void)?

    init(onSaved: ((RelayServerConfig?) -> Void)? = nil) {
        self.onSaved = onSaved
        _config = State(initialValue: RelayConfigStore.load())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ScreenTitle(
                        title: "远程服务器",
                        subtitle: "扫描或粘贴 dshm-relay init 打印的服务器配置，公网配对时用中继定位你的 Mac"
                    )

                    if let config {
                        configuredCard(config)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            SectionLabel(text: "服务器配置")
                            Spacer()
                            Button(showScanner ? L10n.t("收起扫码") : L10n.t("扫码填入")) {
                                showScanner.toggle()
                            }
                            .font(Theme.Typography.captionMedium)
                            .foregroundStyle(Theme.Palette.accent)
                            .accessibilityIdentifier("relay-config-scan")
                        }
                        if showScanner {
                            scannerCard
                        }
                        TextField(
                            "dshm-relay://203.0.113.10:443?pin=…&v=1",
                            text: $text,
                            axis: .vertical
                        )
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                        .padding(Theme.Spacing.s)
                        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
                        .accessibilityIdentifier("relay-config-field")

                        if let errorText {
                            InlineErrorView(message: errorText)
                                .accessibilityIdentifier("relay-config-error")
                        }

                        Button {
                            save()
                        } label: {
                            Text(L10n.t(config == nil ? "保存服务器配置" : "更新服务器配置"))
                        }
                        .buttonStyle(PrimaryButtonStyle(glow: true, enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("relay-config-save")

                        Text("配置非机密数据，保存在本机；连接时用其中的证书 pin 严格校验服务器身份。")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }

                    if config != nil {
                        Button(role: .destructive) {
                            showRemoveConfirm = true
                        } label: {
                            Text("移除服务器配置")
                        }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.Palette.danger, border: Theme.Palette.dangerBorder))
                        .accessibilityIdentifier("relay-config-remove")
                        .confirmationDialog(
                            L10n.t("移除远程服务器配置？"),
                            isPresented: $showRemoveConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(L10n.t("移除"), role: .destructive) {
                                remove()
                            }
                            .accessibilityIdentifier("relay-config-remove-confirm")
                            Button(L10n.t("取消"), role: .cancel) {}
                                .accessibilityIdentifier("relay-config-remove-cancel")
                        } message: {
                            Text(L10n.t("移除后公网/跨网配对将不可用，需要重新执行 dshm-relay init 获取配置。"))
                        }
                    }
                }
                .padding(Theme.Spacing.pageInset)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("relay-config-close")
                }
            }
        }
    }

    private func configuredCard(_ config: RelayServerConfig) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                StatusDot(color: Theme.Palette.accent)
                Text("已配置远程服务器")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(config.displayTarget)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Text(L10n.f("证书 pin：%@ · 配置版本 v%lld", config.shortPin, config.version))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.accentBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relay-config-saved")
    }

    private var scannerCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Palette.surface)
            if cameraUnavailable {
                Text("相机不可用，请粘贴服务器配置")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                QRScannerView(
                    onCode: { code in handleScan(code) },
                    onUnavailable: { cameraUnavailable = true }
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            }
        }
        .frame(height: 200)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("relay-config-scanner")
    }

    private func handleScan(_ code: String) {
        text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        showScanner = false
        save()
    }

    private func save() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = RelayServerConfig.parse(raw) else {
            errorText = L10n.t("不是 dshm-relay:// 服务器配置")
            return
        }
        switch result {
        case .success(let parsed):
            errorText = nil
            config = parsed
            RelayConfigStore.save(parsed)
            onSaved?(parsed)
        case .failure(let error):
            errorText = error.message
        }
    }

    private func remove() {
        RelayConfigStore.save(nil)
        config = nil
        errorText = nil
        onSaved?(nil)
    }
}

#Preview {
    RelayServerConfigView()
}
