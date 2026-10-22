import SwiftUI

/// Manual pairing: paste a QR payload JSON, or enter link origin + one-time code.
struct ManualPairingView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var onPaired: () -> Void

    @State private var payloadText: String
    @State private var origin: String
    @State private var pairToken: String = ""
    @State private var pin: String = ""
    @State private var deviceName: String = AppSettings.deviceName
    @State private var isPairing = false
    @State private var errorText: String?

    init(prefill: String?, onPaired: @escaping () -> Void) {
        self.onPaired = onPaired
        _payloadText = State(initialValue: prefill ?? "")
        _origin = State(initialValue: AppSettings.lastOrigin)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ScreenTitle(title: "手动配对", subtitle: "粘贴 Mac 上显示的配对载荷，或输入配对码")

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        SectionLabel(text: "配对载荷 JSON（可选）")
                        TextEditor(text: $payloadText)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 132)
                            .padding(Theme.Spacing.xs)
                            .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
                            .accessibilityIdentifier("pair-payload")
                        Text("粘贴 Mac 上「DSH-m 手机连接」显示的二维码内容（dsh-m.pair JSON）；也可以只填地址 + 一次性配对码。")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Rectangle().fill(Theme.Palette.border).frame(height: 1)
                        Text("或")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Rectangle().fill(Theme.Palette.border).frame(height: 1)
                    }

                    field(title: "地址 origin", text: $origin, placeholder: "https://127.0.0.1:3466", identifier: "pair-origin", keyboard: .URL)
                    field(title: "配对码", text: $pairToken, placeholder: L10n.t("Mac 上显示的一次性配对码"), identifier: "pair-token", keyboard: .default)
                    field(title: "证书指纹（可选）", text: $pin, placeholder: L10n.t("SHA-256 leaf 指纹，留空则首次信任并固定"), identifier: "pair-pin", keyboard: .default)
                    field(title: "设备名称", text: $deviceName, placeholder: "iPhone", identifier: "pair-device-name", keyboard: .default)

                    if let errorText {
                        InlineErrorView(message: errorText)
                            .accessibilityIdentifier("pair-error")
                    }

                    Button {
                        connect()
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if isPairing {
                                ProgressView().tint(Theme.Palette.accentInk)
                            }
                            Text(isPairing ? L10n.t("正在配对…") : L10n.t("连接"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(glow: true, enabled: !isPairing))
                    .disabled(isPairing)
                    .accessibilityIdentifier("pair-connect")

                    Text("配对码 90 秒内有效且只能使用一次；配对成功后设备凭据保存在钥匙串。")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(Theme.Spacing.pageInset)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .onAppear {
 // Sheet content may be created before the prefill binding lands;
 // fall back to the launch-env payload (E2E / simulator runs).
                if payloadText.isEmpty, let envPayload = app.envPairingPayload {
                    payloadText = envPayload
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func field(title: String, text: Binding<String>, placeholder: String, identifier: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            SectionLabel(text: title)
            TextField(placeholder, text: text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(height: 44)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
                .accessibilityIdentifier(identifier)
        }
    }

    private func connect() {
        guard !isPairing else { return }
        isPairing = true
        errorText = nil
        Task {
            do {
                let payload = try buildPayload()
                let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await app.link.pair(payload: payload, deviceName: name.isEmpty ? AppSettings.deviceName : name)
                isPairing = false
                onPaired()
                dismiss()
            } catch {
                errorText = error.localizedDescription
                isPairing = false
            }
        }
    }

    private func buildPayload() throws -> PairingPayload {
        if let parsed = PairingPayload.parse(payloadText) {
            return parsed
        }
        let token = pairToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw LinkError.transport(L10n.t("请粘贴配对载荷 JSON，或输入配对码"))
        }
        var originText = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if originText.isEmpty { originText = AppSettings.lastOrigin }
        if !originText.contains("://") { originText = "https://\(originText)" }
        let pinText = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinText.isEmpty, PinFormat.normalize(pinText) == nil {
            throw LinkError.transport(L10n.t("证书指纹格式不正确（需要 SHA-256 十六进制）"))
        }
        return PairingPayload.manual(
            origin: originText,
            pairToken: token,
            pin: pinText.isEmpty ? nil : pinText,
            deviceNameHint: deviceName
        )
    }
}

#Preview {
    ManualPairingView(prefill: nil, onPaired: {})
        .environmentObject(AppModel())
}
