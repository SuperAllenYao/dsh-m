import SwiftUI

/// Permission sheet (v5 07 / M5): selectable permission preset + read-only
/// approval policy, sandbox mode and model.
///
/// Sources: `permissions.currentValue`, `approval/policy`, `sandbox/mode` and the
/// `permissionPresets/catalog` proxy (`presetOptions`/`presetDefault`). Tapping a
/// preset row writes through `POST /session/permission`; the view model owns the
/// in-flight/error state, this view only renders it.
struct PermissionSheet: View {
    var permissionsValue: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var modelSelection: String?
 /// M5: selectable presets from `permissionPresets/catalog` (empty while the
 /// first fetch runs or when an older host has no catalog endpoint).
    var presetOptions: [PermissionPresetOption] = []
 /// M5: host-recommended preset, used as the selection fallback until the
 /// session's own `permissions.currentValue` lands.
    var presetDefault: String?
    var isSwitching = false
    var isCatalogLoading = false
    var errorText: String?
    var onSelectPreset: (String) -> Void = { _ in }
    var onRetryCatalog: () -> Void = {}

    private var selectedPresetValue: String? {
        permissionsValue ?? presetDefault
    }

    private func policyLabel(_ policy: String?) -> String {
        switch policy {
        case "ask": return L10n.t("每次询问（ask）")
        case "never": return L10n.t("不再询问（never）")
        case .some(let value): return value
        case .none: return L10n.t("未知")
        }
    }

 /// Local fallback explanation when the catalog omits `description`.
    private func presetDescription(_ value: String?) -> String {
        switch value {
        case "read-only": return L10n.t("只能读取工作区，不能写入或执行命令")
        case "workspace-write": return L10n.t("可在工作区内写入，越权操作需要审批")
        case "danger-full-access": return L10n.t("可读写任意路径并执行命令，无需审批")
        case .some(let other): return other
        case .none: return L10n.t("尚未同步")
        }
    }

    private func presetDetail(_ option: PermissionPresetOption) -> String {
        if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return presetDescription(option.value)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.t("会话权限"), icon: "lock.shield") {
                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.Palette.accent)
                        .accessibilityIdentifier("permission-switching")
                }
            }
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    presetSection
                    infoSection
                    if let errorText, !errorText.isEmpty {
                        errorRow(errorText)
                    }
                    Text(L10n.t("点选即可切换本会话的权限预设；桌面端会同步审批策略与沙箱模式。"))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

 // MARK: - Preset section (M5: selectable)

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionLabel(text: "权限预设 · permissions.currentValue")
            if presetOptions.isEmpty {
                presetFallback
            } else {
                ForEach(presetOptions) { option in
                    presetRow(option)
                }
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private func presetRow(_ option: PermissionPresetOption) -> some View {
        let selected = selectedPresetValue == option.value
        return Button {
            onSelectPreset(option.value)
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(presetDetail(option))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isSwitching, selected {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.Palette.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(selected ? Theme.Palette.accentBorder : Theme.Palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .accessibilityIdentifier("permission-preset-\(option.value)")
        .accessibilityLabel(option.name)
        .accessibilityValue(presetDetail(option))
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

 /// Read-only fallback when no catalog is available (first load in flight, an
 /// older host without the endpoint, or a failed fetch with retry).
    private var presetFallback: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(SessionStatusStrip.permissionLabel(permissionsValue))
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if isCatalogLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.Palette.accent)
                } else {
                    Text(permissionsValue ?? "—")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Text(presetDescription(permissionsValue))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            if !isCatalogLoading {
                Button(L10n.t("重试加载预设")) { onRetryCatalog() }
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.accent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("permission-catalog-retry")
            }
        }
    }

 // MARK: - Read-only rows

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            infoRow(label: L10n.t("审批策略 · approval/policy"), value: policyLabel(approvalPolicy))
            Divider().overlay(Theme.Palette.border)
            infoRow(label: L10n.t("沙箱模式 · sandbox/mode"), value: sandboxMode ?? "—")
            if let modelSelection, !modelSelection.isEmpty {
                Divider().overlay(Theme.Palette.border)
                infoRow(label: L10n.t("模型 · modelSelection.lastUsed"), value: modelSelection)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.danger)
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("permission-switch-error")
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }
}
