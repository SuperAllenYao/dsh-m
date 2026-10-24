import Foundation
import SwiftUI

// MARK: - Unified diff row model (pure; unit-tested in SheetFitHeightTests)

/// One rendered unified-diff line, with GitHub-style old/new line numbers.
struct DiffDisplayLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case added
        case removed
        case context
    }

    /// Flattened index inside its file's diff (stable ForEach identity).
    var id: Int
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    /// Code without the leading marker; the marker gets its own tinted column.
    var text: String
}

/// One rendered hunk: header text plus classified lines.
struct DiffDisplayHunk: Equatable, Identifiable {
    var id: Int
    var header: String
    var lines: [DiffDisplayLine]
}

/// Flattened diff ready for layout.
struct DiffDisplay: Equatable {
    var hunks: [DiffDisplayHunk]
    /// Lines dropped by the render cap (DiffRowBuilder.maxLines); 0 = complete.
    var truncatedLineCount: Int

    var isEmpty: Bool { hunks.isEmpty }
}

/// Converts ChangesDiffValue.hunks into renderable rows.
///
/// Kept free of SwiftUI so the classification / line-number / truncation rules
/// stay unit-testable. The wire format is a standard unified diff: every line
/// starts with "+" (added), "-" (removed) or a space (context), and each hunk
/// carries the starting line number of both sides.
enum DiffRowBuilder {
    /// Hard render cap: a generated 20k-line file must not stall layout.
    static let maxLines = 2_000

    /// Standard unified hunk header: @@ -oldStart,oldLines +newStart,newLines @@
    static func hunkHeader(_ hunk: ChangesDiffValue.Hunk) -> String {
        String(
            format: "@@ -%d,%d +%d,%d @@",
            hunk.oldStart ?? 0,
            hunk.oldLines ?? 0,
            hunk.newStart ?? 0,
            hunk.newLines ?? 0
        )
    }

    /// Classifies a raw unified-diff line ("+" added, "-" removed, else context).
    static func kind(ofRawLine raw: String) -> DiffDisplayLine.Kind {
        guard let first = raw.first else { return .context }
        switch first {
        case "+": return .added
        case "-": return .removed
        default: return .context
        }
    }

    /// Strips the unified-diff marker so the code column does not repeat it.
    static func code(ofRawLine raw: String) -> String {
        guard let first = raw.first, first == "+" || first == "-" || first == " " else {
            return raw
        }
        return String(raw.dropFirst())
    }

    /// Builds rows and walks both line counters hunk by hunk.
    ///
    /// Context consumes both counters, "-" only the old one and "+" only the new
    /// one. At most maxLines lines are returned; the remainder is reported in
    /// truncatedLineCount so the sheet can render a truncation notice.
    static func build(
        hunks: [ChangesDiffValue.Hunk]?,
        maxLines: Int = maxLines
    ) -> DiffDisplay {
        guard let hunks, !hunks.isEmpty, maxLines > 0 else {
            return DiffDisplay(hunks: [], truncatedLineCount: 0)
        }
        var displayHunks: [DiffDisplayHunk] = []
        var emitted = 0
        var dropped = 0
        for (hunkIndex, hunk) in hunks.enumerated() {
            let remaining = maxLines - emitted
            guard remaining > 0 else {
                dropped += hunk.lines.count
                continue
            }
            var oldNumber = hunk.oldStart ?? 0
            var newNumber = hunk.newStart ?? 0
            var rows: [DiffDisplayLine] = []
            rows.reserveCapacity(min(hunk.lines.count, remaining))
            for (lineIndex, raw) in hunk.lines.enumerated() {
                guard lineIndex < remaining else {
                    dropped += hunk.lines.count - lineIndex
                    break
                }
                let kind = kind(ofRawLine: raw)
                var oldValue: Int?
                var newValue: Int?
                switch kind {
                case .added:
                    newValue = newNumber
                    newNumber += 1
                case .removed:
                    oldValue = oldNumber
                    oldNumber += 1
                case .context:
                    oldValue = oldNumber
                    newValue = newNumber
                    oldNumber += 1
                    newNumber += 1
                }
                rows.append(
                    DiffDisplayLine(
                        id: emitted,
                        kind: kind,
                        oldNumber: oldValue,
                        newNumber: newValue,
                        text: code(ofRawLine: raw)
                    )
                )
                emitted += 1
            }
            if !rows.isEmpty {
                displayHunks.append(
                    DiffDisplayHunk(id: hunkIndex, header: hunkHeader(hunk), lines: rows)
                )
            }
        }
        return DiffDisplay(hunks: displayHunks, truncatedLineCount: dropped)
    }
}

// MARK: - Detail sheet

private enum FileDiffState: Equatable {
    case loading
    case loaded(ChangesDiffValue)
    case failed(String)
}

/// File-change detail sheet (protocol §3.9): exactly-fetched summary/diff via the
/// link proxy, or the meta.diffs fallback when the Host no longer holds the data.
///
/// v0.2.8 (task-2): GitHub-style inline diff. Tapping a file row expands that
/// file's unified diff in place (no pushed second-level page); several files can
/// be open at once and loaded diffs are cached. The popup is opt-in resizable:
/// dragging the grabber up grows it, dragging down shrinks it toward a fixed
/// comfort floor (it is content-independent, so a tall diff can still be shrunk),
/// and opening a diff auto-expands it into the 55%-75% band when it is short.
struct FileChangesSheet: View {
    @ObservedObject var viewModel: SessionViewModel
    var changes: TurnFileChanges

    /// Per-file diff state keyed by summary index.
    @State private var diffStates: [Int: FileDiffState] = [:]
    /// Indexes of the file rows currently expanded.
    @State private var expanded: Set<Int> = []
    /// Bumped whenever a diff opens: asks the popup for one auto-expand.
    @State private var expandRequest = 0

    /// Live value: the sheet follows the view model instead of the value captured
    /// at tap time, so aggregate numbers are replaced by the exact ones in place.
    private var effectiveChanges: TurnFileChanges {
        viewModel.latestTurnFileChanges ?? changes
    }

    /// Only the exact-fetch summary carries /api/changes.diff indices; the
    /// meta.diffs fallback has no hunk data, so its rows stay inert.
    private var canOpenDiffs: Bool {
        effectiveChanges.source == .exactFetch && effectiveChanges.seq != nil
    }

    /// Width of one diff row: the popup is full-width and the list is inset by the
    /// page inset on both sides. Rows paint their tinted background across this
    /// width even when the code itself is shorter.
    private var diffRowWidth: CGFloat {
        max(0, UIScreen.main.bounds.width - Theme.Spacing.pageInset * 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.t("本轮文件变更"))
            Rectangle().fill(Theme.Palette.border).frame(height: 1)
            fileList
        }
        // task-2: opt-in grabber resize (up = taller, down = fixed comfort floor).
        .sheetResizable()
        // task-2: opening a diff asks for one auto-expand to a readable height.
        .sheetExpandRequest(expandRequest)
        // task-2: opening the sheet is an explicit ask for the exact numbers;
        // re-arm a previously failed fetch instead of pinning the fallback.
        .onAppear { viewModel.retryFileChangesExactFetchIfNeeded() }
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                summaryHeader
                if effectiveChanges.source == .metaDiffsFallback {
                    InlineErrorView(message: L10n.t("Host 已释放该轮变更详情（404 或连接未就绪），以下文件来自工具结果 meta.diffs 聚合。"))
                }
                ForEach(Array(effectiveChanges.files.enumerated()), id: \.offset) { index, file in
                    fileSection(index: index, file: file)
                }
            }
            .padding(.horizontal, Theme.Spacing.pageInset)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .measureSheetContentHeight()
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("file-changes-list")
    }

    private var summaryHeader: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(effectiveChanges.source == .exactFetch ? L10n.t("来源：Host /api/changes.summary") : L10n.t("来源：tool/result.meta.diffs 兜底"))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.xs)
            Text("+" + String(effectiveChanges.added))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Diff.addMark)
            Text("-" + String(effectiveChanges.deleted))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Diff.delMark)
        }
    }

    // MARK: File section: GitHub-style header + inline diff

    @ViewBuilder
    private func fileSection(index: Int, file: ChangesSummaryValue.File) -> some View {
        let isExpanded = expanded.contains(index)
        VStack(spacing: 0) {
            fileRow(index: index, file: file, isExpanded: isExpanded)
            if isExpanded {
                diffSection(index: index, file: file)
                    .transition(.opacity)
            }
        }
        .background(Theme.Diff.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Diff.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func fileRow(index: Int, file: ChangesSummaryValue.File, isExpanded: Bool) -> some View {
        if canOpenDiffs {
            Button {
                toggle(index: index)
            } label: {
                fileRowContent(file: file, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("file-change-row-" + String(index))
        } else {
            // meta.diffs fallback rows are not expandable but still carry the same
            // E2E identifier as exact-fetch rows.
            fileRowContent(file: file, isExpanded: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("file-change-row-" + String(index))
        }
    }

    private func fileRowContent(file: ChangesSummaryValue.File, isExpanded: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Group {
                if canOpenDiffs {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Diff.muted)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            Image(systemName: fileIcon(for: file.path))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Diff.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName(file))
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Diff.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Diff.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.xs)
            changeBar(added: file.added ?? 0, deleted: file.deleted ?? 0)
            if let added = file.added, added > 0 {
                Text("+" + String(added))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Diff.addMark)
            }
            if let deleted = file.deleted, deleted > 0 {
                Text("-" + String(deleted))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Diff.delMark)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Diff.surface)
        .contentShape(Rectangle())
    }

    /// GitHub's addition/deletion proportion bar.
    private func changeBar(added: Int, deleted: Int) -> some View {
        let total = added + deleted
        let width: CGFloat = 32
        return HStack(spacing: 2) {
            if added > 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Diff.addMark)
                    .frame(width: barWidth(added, total: total, width: width), height: 4)
            }
            if deleted > 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Diff.delMark)
                    .frame(width: barWidth(deleted, total: total, width: width), height: 4)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func barWidth(_ value: Int, total: Int, width: CGFloat) -> CGFloat {
        guard total > 0 else { return width }
        return max(2, (width - 2) * CGFloat(value) / CGFloat(total))
    }

    // MARK: Inline unified diff

    @ViewBuilder
    private func diffSection(index: Int, file: ChangesSummaryValue.File) -> some View {
        VStack(spacing: 0) {
            diffFileHeader(index: index, file: file)
            switch diffStates[index] {
            case .some(.loaded(let diff)):
                diffBody(diff: diff)
            case .some(.failed(let message)):
                diffFailure(index: index, message: message)
            case .some(.loading), .none:
                diffLoading
            }
        }
        .background(Theme.Diff.canvas)
    }

    /// File header of the expanded diff: path + +N/-N + collapse arrow.
    private func diffFileHeader(index: Int, file: ChangesSummaryValue.File) -> some View {
        Button {
            toggle(index: index)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Diff.muted)
                    .frame(width: 12)
                Text(file.path)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Diff.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.xs)
                if let added = file.added, added > 0 {
                    Text("+" + String(added))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Diff.addMark)
                }
                if let deleted = file.deleted, deleted > 0 {
                    Text("-" + String(deleted))
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Diff.delMark)
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Diff.hunkHeader)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Diff.border).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("diff-file-header")
    }

    @ViewBuilder
    private func diffBody(diff: ChangesDiffValue) -> some View {
        let display = DiffRowBuilder.build(hunks: diff.hunks)
        VStack(alignment: .leading, spacing: 0) {
            if diff.coarse == true {
                Text("coarse")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Diff.muted)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.top, 6)
                    .accessibilityIdentifier("diff-coarse")
            }
            if display.isEmpty {
                Text(L10n.t("该文件没有可展示的文本 diff。"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Diff.muted)
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The whole diff block scrolls horizontally as one unit; long code
                // lines keep their own width instead of wrapping.
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(display.hunks) { hunk in
                            hunkHeaderRow(hunk.header)
                            ForEach(hunk.lines) { line in
                                diffLineRow(line)
                            }
                        }
                        if display.truncatedLineCount > 0 {
                            truncationNotice(display.truncatedLineCount)
                        }
                    }
                }
            }
        }
    }

    /// Old line number | new line number | marker | code (GitHub row layout).
    private func diffLineRow(_ line: DiffDisplayLine) -> some View {
        HStack(spacing: 0) {
            lineNumberCell(line.oldNumber, kind: line.kind)
            lineNumberCell(line.newNumber, kind: line.kind)
            Text(marker(for: line.kind))
                .font(Theme.Typography.diffLine)
                .foregroundStyle(markerColor(for: line.kind))
                .frame(width: Theme.Diff.markerWidth, height: Theme.Diff.lineHeight)
                .background(rowBackground(for: line.kind))
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.Typography.diffLine)
                .foregroundStyle(Theme.Diff.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 4)
                .padding(.trailing, Theme.Spacing.s)
                .frame(height: Theme.Diff.lineHeight)
                .accessibilityIdentifier(lineIdentifier(for: line.kind))
        }
        .frame(minWidth: diffRowWidth, alignment: .leading)
        .background(rowBackground(for: line.kind))
    }

    private func lineNumberCell(_ number: Int?, kind: DiffDisplayLine.Kind) -> some View {
        Text(number.map { String($0) } ?? "")
            .font(Theme.Typography.diffGutter)
            .foregroundStyle(gutterNumberColor(for: kind))
            .lineLimit(1)
            .padding(.trailing, 6)
            .frame(width: Theme.Diff.gutterWidth, height: Theme.Diff.lineHeight, alignment: .trailing)
            .background(gutterBackground(for: kind))
    }

    private func hunkHeaderRow(_ header: String) -> some View {
        Text(header)
            .font(Theme.Typography.diffLine)
            .foregroundStyle(Theme.Diff.hunkHeaderText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minWidth: diffRowWidth, minHeight: Theme.Diff.lineHeight, alignment: .leading)
            .background(Theme.Diff.hunkHeader)
            .accessibilityIdentifier("diff-hunk-header")
    }

    private func truncationNotice(_ dropped: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "scissors")
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.f("已截断：仅显示前 %lld 行，另有 %lld 行未渲染", DiffRowBuilder.maxLines, dropped))
                .font(Theme.Typography.caption)
                .lineLimit(2)
        }
        .foregroundStyle(Theme.Palette.warning)
        .padding(Theme.Spacing.s)
        .frame(width: diffRowWidth, alignment: .leading)
        .background(Theme.Diff.surface)
        .accessibilityIdentifier("diff-truncated")
    }

    private var diffLoading: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.Palette.accent)
            Text(L10n.t("正在读取文件对比…"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Diff.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.s)
        .accessibilityIdentifier("diff-loading")
    }

    private func diffFailure(index: Int, message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.danger)
            Button {
                diffStates[index] = nil
                loadDiff(index: index)
            } label: {
                Text(L10n.t("重试"))
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diff-retry-" + String(index))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.s)
        .accessibilityIdentifier("diff-error")
    }

    // MARK: Diff colors / markers

    private func rowBackground(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.Diff.addedLine
        case .removed: return Theme.Diff.removedLine
        case .context: return .clear
        }
    }

    private func gutterBackground(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.Diff.addedGutter
        case .removed: return Theme.Diff.removedGutter
        case .context: return .clear
        }
    }

    private func gutterNumberColor(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.Diff.addMark
        case .removed: return Theme.Diff.delMark
        case .context: return Theme.Diff.muted
        }
    }

    private func markerColor(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .added: return Theme.Diff.addMark
        case .removed: return Theme.Diff.delMark
        case .context: return .clear
        }
    }

    private func marker(for kind: DiffDisplayLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func lineIdentifier(for kind: DiffDisplayLine.Kind) -> String {
        switch kind {
        case .added: return "diff-line-added"
        case .removed: return "diff-line-removed"
        case .context: return "diff-line-context"
        }
    }

    // MARK: File helpers

    private func fileName(_ file: ChangesSummaryValue.File) -> String {
        file.display ?? (file.path as NSString).lastPathComponent
    }

    private func fileIcon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "json", "js", "mjs", "ts", "tsx", "jsx": return "curlybraces"
        case "html", "htm", "xml": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss": return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf": return "photo"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc.text"
        }
    }

    // MARK: Expand + load

    private func toggle(index: Int) {
        let isExpanding = !expanded.contains(index)
        withAnimation(Theme.Motion.quick) {
            if isExpanding {
                expanded.insert(index)
            } else {
                expanded.remove(index)
            }
        }
        guard isExpanding else { return }
        // v0.2.8: ask the popup to grow into its comfortable band (only raises a
        // sheet that is still shorter than the 55% threshold; a manually taller
        // sheet is left alone and remains freely resizable).
        expandRequest += 1
        guard diffStates[index] == nil else { return }
        loadDiff(index: index)
    }

    private func loadDiff(index: Int) {
        guard let seq = effectiveChanges.seq, canOpenDiffs else { return }
        diffStates[index] = .loading
        Task { @MainActor in
            if let diff = await viewModel.loadFileDiff(seq: seq, index: index) {
                diffStates[index] = .loaded(diff)
            } else {
                diffStates[index] = .failed(L10n.t("无法读取该文件对比（Host 内存已释放或请求失败）。"))
            }
        }
    }
}
