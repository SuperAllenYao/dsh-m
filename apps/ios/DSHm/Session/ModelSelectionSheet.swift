import SwiftUI

/// v0.2.0 model selection panel (composer model entry).
///
/// Mirrors the desktop composer model menu's information structure:
/// provider-grouped model list (search above four models), a drilled-in
/// "推理等级" pane, a checkmark for the current selection, a spinner on the
/// pending row, and an error banner that keeps the sheet open for a retry.
struct ModelSelectionSheet: View {
    var catalog: ModelCatalog?
    var current: ModelSelection?
    var isLoading: Bool
    var isSelecting: Bool
 /// Selection submitted and awaiting the Host's answer (row spinner).
    var pending: ModelSelection?
    var errorText: String?
    var onSelect: (ModelSelection) -> Void
    var onRetry: () -> Void
 /// Dismiss the popup (the grabber handles the same gesture).
    var onDismiss: () -> Void

    @State private var query: String = ""
    @State private var showingEfforts = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredGroups: [ModelCatalog.Group] {
        guard let catalog else { return [] }
        guard !trimmedQuery.isEmpty else { return catalog.orderedGroups }
        return catalog.orderedGroups.compactMap { group in
            let models = group.models.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.id.localizedCaseInsensitiveContains(trimmedQuery)
            }
            return models.isEmpty ? nil : ModelCatalog.Group(id: group.id, name: group.name, models: models)
        }
    }

    private var showsSearch: Bool {
        (catalog?.modelCount ?? 0) > 4
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: showingEfforts ? L10n.t("推理等级") : L10n.t("模型"),
                onBack: showingEfforts ? { withAnimation(Theme.Motion.quick) { showingEfforts = false } } : nil,
                titleIdentifier: "model-sheet-title",
                backIdentifier: "model-effort-back"
            )
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            content
        }
        .accessibilityIdentifier("model-sheet")
    }

 // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let catalog {
            ScrollView {
                VStack(spacing: 0) {
                    if showingEfforts {
                        effortRows(catalog)
                    } else {
                        modelList(catalog)
                    }
                    if let errorText, !errorText.isEmpty {
                        InlineErrorView(message: errorText)
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.bottom, Theme.Spacing.s)
                            .accessibilityIdentifier("model-error")
                    }
                }
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("model-list")
        } else if isLoading {
            ScrollView {
                VStack(spacing: Theme.Spacing.s) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text(L10n.t("正在加载模型…"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xxl)
                .measureSheetContentHeight()
                .accessibilityIdentifier("model-loading")
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.s) {
                    InlineErrorView(message: errorText ?? L10n.t("模型目录加载失败"))
                        .accessibilityIdentifier("model-error")
                    Button {
                        onRetry()
                    } label: {
                        Text(L10n.t("重新加载"))
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityIdentifier("model-reload")
                }
                .padding(Theme.Spacing.l)
                .frame(maxWidth: .infinity)
                .measureSheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func modelList(_ catalog: ModelCatalog) -> some View {
        VStack(spacing: 0) {
            if showsSearch {
                searchField
            }
            if let current, !catalog.effortChoices(for: current).isEmpty {
                effortCell(catalog, selection: current)
            }
            VStack(alignment: .leading, spacing: 0) {
                if filteredGroups.isEmpty {
                    Text(L10n.t("暂无可用模型"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
                        .accessibilityIdentifier("model-empty")
                }
                ForEach(filteredGroups) { group in
                    Text(ModelCatalog.groupDisplayName(group))
                        .font(Theme.Typography.captionMedium)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.top, Theme.Spacing.m)
                        .padding(.bottom, Theme.Spacing.xxs)
                    ForEach(group.models) { model in
                        modelRow(catalog, group: group, model: model)
                    }
                }
                ForEach(catalog.failures) { failure in
                    failureRow(failure)
                }
                if catalog.modelCount == 0, catalog.failures.isEmpty {
                    Text(L10n.t("暂无可用模型"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
                        .accessibilityIdentifier("model-empty")
                }
            }
            .padding(.bottom, Theme.Spacing.s)
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField(L10n.t("搜索模型…"), text: $query)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("model-search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("model-search-clear")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func effortCell(_ catalog: ModelCatalog, selection: ModelSelection) -> some View {
        Button {
            withAnimation(Theme.Motion.quick) { showingEfforts = true }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(L10n.t("推理等级"))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: 0)
                Text(catalog.effortName(for: selection) ?? "—")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("model-effort-cell")
        .accessibilityValue(catalog.effortName(for: selection) ?? "")
    }

    private func modelRow(_ catalog: ModelCatalog, group: ModelCatalog.Group, model: ModelCatalog.Model) -> some View {
        let isSelected = current?.provider == group.id && current?.model == model.id
        let isPending = pending?.provider == group.id && pending?.model == model.id
        return Button {
            guard !isSelecting else { return }
            onSelect(catalog.selection(provider: group.id, model: model))
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(model.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPending || (isSelecting && isSelected) {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                        .scaleEffect(0.7)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Theme.Palette.accentSoft : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(isSelecting)
        .accessibilityIdentifier("model-row-\(group.id)-\(model.id)")
        .accessibilityValue(isSelected ? "selected" : "")
    }

    private func effortRows(_ catalog: ModelCatalog) -> some View {
        let choices = current.map { catalog.effortChoices(for: $0) } ?? []
        return VStack(alignment: .leading, spacing: 0) {
                if choices.isEmpty {
                    Text(L10n.t("当前模型未提供推理等级。"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
                        .accessibilityIdentifier("model-effort-empty")
                }
                ForEach(choices) { choice in
                    let isEffective = current.map { catalog.isEffectiveEffort(choice.effortId, for: $0) } ?? false
                    Button {
                        guard !isSelecting, let current else { return }
                        if isEffective {
                            onDismiss()
                            return
                        }
                        onSelect(ModelSelection(
                            provider: current.provider,
                            model: current.model,
                            reasoningEffort: choice.effortId
                        ))
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(choice.name)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer(minLength: 0)
                            if isEffective {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelecting)
                    .accessibilityIdentifier("model-effort-row-\(choice.id)")
                }
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    private func failureRow(_ failure: ModelCatalog.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.f("%@ 加载失败：%@", failure.name, failure.message))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onRetry()
            } label: {
                Text(L10n.t("重新加载"))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("model-failure-\(failure.id)")
    }
}

#if DEBUG
#Preview("Model sheet") {
    ModelSelectionSheet(
        catalog: ModelCatalog(
            defaultSelection: .init(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "high"),
            routableProviders: ["deepseek-official"],
            groups: [
                ModelCatalog.Group(id: "deepseek-official", name: "DeepSeek", models: [
                    ModelCatalog.Model(id: "deepseek-flash", name: "DeepSeek Flash", description: nil, reasoning: .init(
                        efforts: [
                            .init(id: "low", name: "Low", description: nil),
                            .init(id: "high", name: "High", description: nil),
                        ],
                        defaultEffort: "high"
                    )),
                ]),
            ],
            failures: []
        ),
        current: ModelSelection(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "high"),
        isLoading: false,
        isSelecting: false,
        pending: nil,
        errorText: nil,
        onSelect: { _ in },
        onRetry: {},
        onDismiss: {}
    )
}
#endif
