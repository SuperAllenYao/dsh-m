import SwiftUI

/// M2a pairing-code entry (design §5.3/§5.6): discovers `_dshm._tcp` Macs,
/// lets the user pick one when several are visible, takes exactly eight digits
/// with a number pad and auto-submits. Falls back to the configured relay server
/// when no Mac is discovered (public lookup flow, §5.4).
struct PairingCodeEntryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = PairingCodeFlowModel()
    @State private var showRelayConfig = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ScreenTitle(
                        title: "输入配对码",
                        subtitle: "在 Mac 的「设置 → DSH-m 手机连接」查看 8 位配对码"
                    )

                    discoveryCard

                    codeCard

                    Text("配对码 2 分钟有效，输错 5 次作废，仅可使用一次。")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(Theme.Spacing.pageInset)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("pair-code-cancel")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showRelayConfig) {
                RelayServerConfigView { config in
                    model.applyRelayConfig(config)
                }
            }
            .onAppear {
                model.onRedemption = { redemption in
                    app.link.adopt(credentials: redemption.credentials)
                    app.didPair()
                    dismiss()
                }
                model.start()
                #if DEBUG
                if let prefilled = E2EScaffolding.pairCode {
                    model.prefillCode(prefilled)
                }
                if E2EScaffolding.forcesRelayPairing {
 // Public relay path for the simulator E2E (design §5.4).
                    model.useRelay()
                }
                #endif
                codeFocused = true
            }
            .onDisappear {
                model.stop()
            }
        }
    }

 // MARK: - Discovery

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                SectionLabel(text: "局域网 Mac")
                Spacer()
                Button {
                    model.rediscover()
                } label: {
                    Text("重新发现")
                }
                .font(Theme.Typography.captionMedium)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("pair-code-rediscover")
            }

            VStack(spacing: Theme.Spacing.xxs) {
                ForEach(model.macs) { mac in
                    macRow(mac)
                }
                if model.macs.isEmpty, let hint = model.discoveryHint {
                    Text(hint)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pair-code-discovery-hint")
                }
            }
            .padding(Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            relayRow
        }
    }

    private func macRow(_ mac: DiscoveredMac) -> some View {
        Button {
            model.selectMac(mac.id)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.displayName)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(String(mac.hostId.prefix(8)) + " · " + (mac.protocolVersion ?? "dsh-m/1"))
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                if model.selectedMacId == mac.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pair-code-host-row")
    }

    @ViewBuilder
    private var relayRow: some View {
        if model.hasRelayConfig {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    if model.prefersRelay {
                        model.useLAN()
                    } else {
                        model.useRelay()
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: model.prefersRelay ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.prefersRelay ? L10n.t("通过远程服务器配对（已选）") : L10n.t("改用远程服务器配对"))
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(model.prefersRelay ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, 8)
                    .background(
                        model.prefersRelay ? Theme.Palette.accentSoft : Theme.Palette.surface,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            model.prefersRelay ? Theme.Palette.accentBorder : Theme.Palette.border,
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pair-code-use-relay")
                Spacer(minLength: 0)
                Button {
                    showRelayConfig = true
                } label: {
                    Text("服务器配置")
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pair-code-relay-config")
            }
        } else {
            Button {
                showRelayConfig = true
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: "network")
                        .font(.system(size: 12, weight: .semibold))
                    Text("未配置远程服务器，配置后可在公网配对")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pair-code-relay-config")
        }
    }

 // MARK: - Code input

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(text: "配对码")

            ZStack {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(0..<PairingCodeInput.length, id: \.self) { index in
                        codeDigitBox(index)
                    }
                }
 // Single invisible-caret UITextField over the boxes: keeps the
 // 8-box OTP look while giving XCUITest one stable `pair-code-field`.
                TextField("", text: codeBinding)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                    .focused($codeFocused)
                    .accessibilityIdentifier("pair-code-field")
                    .accessibilityValue(model.code.digits)
            }

            if let failure = model.failure {
                InlineErrorView(message: failure.message)
                    .accessibilityIdentifier("pair-code-error")
            }

            if let attempts = model.attemptsLeft {
                Text(L10n.f("剩余尝试次数：%lld", attempts))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.warning)
                    .accessibilityIdentifier("pair-code-attempts")
            }

            Button {
                model.submit()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if model.phase.isSubmitting {
                        ProgressView().tint(Theme.Palette.accentInk)
                    }
                    Text(submitTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle(glow: true, enabled: model.canSubmit && !model.phase.isSubmitting))
            .disabled(!model.canSubmit || model.phase.isSubmitting)
            .accessibilityIdentifier("pair-code-submit")

            Text(model.phase.isSubmitting ? L10n.t("正在配对…") : L10n.t("输入满 8 位数字后自动提交"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private var submitTitle: String {
        if model.phase.isSubmitting { return L10n.t("正在配对…") }
        if model.failure != nil { return L10n.t("重试") }
        return L10n.t("配对")
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { model.code.digits },
            set: { model.updateCode($0) }
        )
    }

    private func codeDigitBox(_ index: Int) -> some View {
        let characters = Array(model.code.digits)
        let filled = index < characters.count
        let isError = model.failure != nil
        return ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Palette.codeBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(
                            isError ? Theme.Palette.dangerBorder : (filled ? Theme.Palette.accentBorder : Theme.Palette.border),
                            lineWidth: 1
                        )
                )
            if filled {
                Text(String(characters[index]))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
    }
}
