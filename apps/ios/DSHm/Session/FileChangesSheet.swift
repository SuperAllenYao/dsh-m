import SwiftUI

/// File-change detail sheet (protocol §3.9): exactly-fetched summary/diff via the
/// link proxy, or the meta.diffs fallback when the Host no longer holds the data.
struct FileChangesSheet: View {
    @ObservedObject var viewModel: SessionViewModel
    var changes: TurnFileChanges

    /// Live value: while the exact summary is still loading (or was just retried),
    /// the sheet follows the view model instead of the value captured at tap time.
    private var effectiveChanges: TurnFileChanges {
        viewModel.latestTurnFileChanges ?? changes
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: L10n.t("本轮文件变更"))
                Rectangle().fill(Theme.Palette.border).frame(height: 1)
                if effectiveChanges.isLoading {
                    loadingView
                } else {
                    fileList
                }
            }
            // The sheet draws its own unified header; the navigation bar stays
            // available for the pushed file-diff pages.
            .toolbar(.hidden, for: .navigationBar)
            // task-2: opening the sheet is an explicit ask for the exact numbers;
            // re-arm a previously failed fetch instead of pinning the fallback.
            .onAppear { viewModel.retryFileChangesExactFetchIfNeeded() }
        }
    }

    /// task-2: exact numbers still loading — show a neutral loading state instead
    /// of the meta.diffs fallback (which reads like the desktop numbers but is not).
    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
                .tint(Theme.Palette.accent)
            Text(L10n.t("正在读取精确数据…"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.pageInset)
        .accessibilityIdentifier("file-changes-loading")
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(effectiveChanges.source == .exactFetch ? L10n.t("来源：Host /api/changes.summary") : L10n.t("来源：tool/result.meta.diffs 兜底"))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Spacer()
                    Text("+\(effectiveChanges.added) -\(effectiveChanges.deleted)")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                if effectiveChanges.source == .metaDiffsFallback {
                    InlineErrorView(message: L10n.t("Host 已释放该轮变更详情（404 或连接未就绪），以下文件来自工具结果 meta.diffs 聚合。"))
                }

                ForEach(Array(effectiveChanges.files.enumerated()), id: \.offset) { index, file in
                    if effectiveChanges.source == .exactFetch, let seq = effectiveChanges.seq {
                        NavigationLink {
                            FileDiffLoaderView(
                                viewModel: viewModel,
                                seq: seq,
                                index: index,
                                path: file.display ?? (file.path as NSString).lastPathComponent
                            )
                        } label: {
                            row(index: index, file: file, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("file-change-row-\(index)")
                    } else {
                        // task-4: fallback（meta.diffs 聚合）行不是可点链接，但 E2E
                        // 要像 exact-fetch 行一样计数/定位，因此同样挂
                        // file-change-row-<i>（fixture 契约 §4 的待补项）。
                        // combine 让整行成为一个 AX 元素，identifier 才稳定可查。
                        row(index: index, file: file, showsChevron: false)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("file-change-row-\(index)")
                    }
                }
            }
            .padding(Theme.Spacing.pageInset)
            .measureSheetContentHeight()
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("file-changes-list")
    }

    private func row(index: Int, file: ChangesSummaryValue.File, showsChevron: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.display ?? (file.path as NSString).lastPathComponent)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(file.path)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let added = file.added, added > 0 {
                Text("+\(added)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.accent)
            }
            if let deleted = file.deleted, deleted > 0 {
                Text("-\(deleted)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Loads one file's diff through `/api/changes.diff` (pushed inside the sheet's
/// NavigationStack so the presentation is not rebuilt by parent state changes).
struct FileDiffLoaderView: View {
    @ObservedObject var viewModel: SessionViewModel
    let seq: Int
    let index: Int
    let path: String

    @State private var diff: ChangesDiffValue?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let diff {
                ChangeDiffView(diff: diff, fallbackPath: path)
            } else if let errorText {
                ScrollView {
                    InlineErrorView(message: errorText)
                        .padding(Theme.Spacing.pageInset)
                }
            } else {
                VStack(spacing: Theme.Spacing.xs) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("正在读取文件对比…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .navigationTitle("文件对比")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard diff == nil, errorText == nil else { return }
            let loaded = await viewModel.loadFileDiff(seq: seq, index: index)
            if let loaded {
                diff = loaded
            } else {
                errorText = L10n.t("无法读取该文件对比（Host 内存已释放或请求失败）。")
            }
        }
    }
}

/// Unified-diff hunks from `/api/changes.diff`.
struct ChangeDiffView: View {
    var diff: ChangesDiffValue
    var fallbackPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(diff.display ?? diff.path ?? fallbackPath ?? "diff")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if diff.coarse == true {
                        Text("coarse")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                ForEach(Array((diff.hunks ?? []).enumerated()), id: \.offset) { _, hunk in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@@ -\(hunk.oldStart ?? 0),\(hunk.oldLines ?? 0) +\(hunk.newStart ?? 0),\(hunk.newLines ?? 0) @@")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(color(for: line))
                        }
                    }
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.Palette.border, lineWidth: 1)
                    )
                }
                if (diff.hunks ?? []).isEmpty {
                    Text("该文件没有可展示的文本 diff。")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(Theme.Spacing.pageInset)
        }
        .accessibilityIdentifier("changes-diff")
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return Theme.Palette.accent }
        if line.hasPrefix("-") { return Theme.Palette.danger }
        return Theme.Palette.textSecondary
    }
}
