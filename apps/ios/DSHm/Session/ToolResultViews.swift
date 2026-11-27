import SwiftUI
import UIKit

// MARK: - 文件入口 → 打开目标（DD-03 / AC-04、AC-05、AC-06）

/// 行内文件入口（工具行文件名、工具详情文件标题、变更列表文件路径）共用的接线：
/// 取出/接收文件路径，再交给 `FileOpenRouter` 按扩展名分类（文本 → 文件面板；
/// 图片 → 全屏预览）。
///
/// 入口只负责「哪个文件」，图片/文本判定统一取 router 的 `imageExtensions`
/// （AC-15：四处入口共用同一分类口径）。
enum FileEntryTarget {
    /// 参数里带目标文件的工具（与 `ToolCallItem.summary` 的文件名分支同一组）。
    private static let toolNames: Set<String> = ["read", "edit", "write", "read_image"]

    /// 参数键：这几个工具用 `file_path`；兼容只给 `path` 的宿主。
    private static let argumentKeys = ["file_path", "path"]

    /// 工具调用指向的文件路径；非文件工具返回 nil。
    ///
    /// 先判工具名再读 `arguments`：参数是惰性解码的（`ToolCallItem.arguments` 首次访问才
    /// 解 JSON 并缓存），不可点的行不该为此付出解码成本。
    static func path(for item: ToolCallItem) -> String? {
        guard toolNames.contains(item.name) else { return nil }
        let arguments = item.arguments
        for key in argumentKeys {
            guard let raw = arguments[key]?.stringValue else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// 工具调用 → 打开目标；非文件工具或空路径时 nil（调用方保持原行为）。
    static func openTarget(for item: ToolCallItem) -> FileOpenTarget? {
        guard let path = path(for: item) else { return nil }
        return resolve(path)
    }

    /// 已知文件路径（工具参数、变更列表的 `file.path`）→ 打开目标。
    ///
    /// 先走 router 的完整分类（它还能处理 `file://`、百分号转义与 query/fragment）；
    /// router 判为「不像文件路径」时再按扩展名兜底——这里的入参本身就是文件，
    /// `Makefile` 这类没有扩展名也不带目录的路径不该失去入口，默认进文件面板。
    static func resolve(_ rawPath: String) -> FileOpenTarget? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let target = FileOpenRouter.target(forLinkTarget: trimmed) { return target }
        // 图片/文本的唯一判定口径仍是 router 的扩展名集合（AC-15）。
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return FileOpenRouter.imageExtensions.contains(ext)
            ? .imagePreview(path: trimmed)
            : .filePanel(path: trimmed)
    }

    /// 行内展示的文件名：与 `ToolCallItem.summary` 同口径（basename），
    /// 参数只给 `path` 时退回路径末段。
    static func displayName(for item: ToolCallItem, path: String) -> String {
        let summary = item.summary
        return summary.isEmpty ? (path as NSString).lastPathComponent : summary
    }
}

// MARK: - lazy-fetch 动作（协议 v1 契约 §7）

/// 工具结果展开入口的「取全文」动作（`SessionViewModel.fetchEventFull(seq:)`）。
///
/// 通过 Environment 注入：`ToolResultContentView` 在任意层级（主流程行 / 过程组 /
/// 详情 sheet / 嵌套调用）都能拿到，不必把回调一路穿过 cell 的 Equatable 比较。
struct LazyFullFetchAction {
    let handler: @MainActor (Int) async -> Void

    func callAsFunction(seq: Int) async {
        await handler(seq)
    }
}

private struct LazyFullFetchKey: EnvironmentKey {
    static let defaultValue: LazyFullFetchAction? = nil
}

extension EnvironmentValues {
 /// nil = 没有 lazy-fetch（非详情页 / 测试宿主 / 非投影模式）。
    var lazyFullFetch: LazyFullFetchAction? {
        get { self[LazyFullFetchKey.self] }
        set { self[LazyFullFetchKey.self] = newValue }
    }
}

// MARK: - Markdown / text

/// Block-level markdown (headings / lists / code blocks / tables / quotes /...).
///
/// The public surface is unchanged so every existing call site (assistant body,
/// user bubble, relay card) gets block rendering automatically. See
/// `MarkdownDocument.swift` + `MarkdownBlockViews.swift`.
struct MarkdownText: View {
    var text: String
    var color: Color = Theme.Palette.textPrimary

    var body: some View {
        MarkdownDocumentView(text: text, color: color)
    }
}

// MARK: - Code / output blocks

struct MonoBlock: View {
    var text: String
    var maxLines: Int? = 40
    var color: Color = Theme.Palette.textSecondary
 /// 协议 v1 lazy-fetch（契约 §7）：本块文本是截断版、且提供了 `onRequestFull`。
 /// true 时「显示全部 N 行」先发一次窄页请求取全文（拿到后本块重建为完整文本，
 /// 再点才是零网络的本地展开）；false = 现有行为（零变化）。
    var needsLazyFetch: Bool = false
    var onRequestFull: (() -> Void)? = nil
    @State private var showAll = false

    private var lines: [String] { text.components(separatedBy: "\n") }
    private var visibleText: String {
        guard let maxLines, !showAll, lines.count > maxLines else { return text }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(visibleText)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
            if let maxLines, !showAll, lines.count > maxLines {
                Button(L10n.f("显示全部 %lld 行", lines.count)) {
                    if needsLazyFetch, let onRequestFull {
 // 契约 §7：截断行先取单事件全文（失败降级保持截断内容）。
                        onRequestFull()
                    } else {
                        showAll = true
                    }
                }
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("show-full-output")
            }
        }
    }
}

/// read tool result: numbered code lines from meta.lines.
struct NumberedCodeView: View {
    var path: String?
    var lang: String?
    var offset: Int?
    var totalLines: Int?
    var lines: [JSONValue]
    var fallbackText: String

    @Environment(\.fileOpenAction) private var fileOpenAction

    /// AC-05：标题里的文件标题就是打开入口；没有承载方（`fileOpenAction == nil`，
    /// 预览/测试宿主）或路径为空时保持纯文本标题，不出现点了没反应的按钮。
    private var fileOpenTarget: FileOpenTarget? {
        guard fileOpenAction != nil, let path, !path.isEmpty else { return nil }
        return FileEntryTarget.resolve(path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fileHeader
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(line["number"]?.int ?? 0))
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(line["text"]?.stringValue ?? "")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                .padding(Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
        }
    }

    /// 文件标题行（设计稿 `#detail` 的 `.reshead`：整行可点）。
    ///
    /// 只发打开动作：面板由上层（会话详情）呈现并替换当前弹层，本视图不持有弹层状态。
    @ViewBuilder
    private var fileHeader: some View {
        if let target = fileOpenTarget, let open = fileOpenAction {
            Button {
                open(target)
            } label: {
                headerContent.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool-detail-file-title")
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(path ?? "read")
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let totalLines {
                Text(L10n.f("%lld/%lld 行", lines.count, totalLines))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

/// edit/write tool result: meta.diffs [{path, oldText, newText}].
struct DiffView: View {
    var diffs: [JSONValue]
    var operation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                        Text(diff["path"]?.stringValue ?? operation ?? "diff")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let operation {
                            Text(operation)
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    if let oldText = diff["oldText"]?.stringValue, !oldText.isEmpty {
                        diffLines(prefix: "-", text: oldText, color: Theme.Palette.danger)
                    }
                    if let newText = diff["newText"]?.stringValue, !newText.isEmpty {
                        diffLines(prefix: "+", text: newText, color: Theme.Palette.accent)
                    }
                }
            }
        }
    }

    private func diffLines(prefix: String, text: String, color: Color) -> some View {
        let lines = text.components(separatedBy: "\n").prefix(8)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(prefix + line)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(color.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xs)
        }
        .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
    }
}

/// grep/glob matched files.
struct FileMatchListView: View {
    var files: [JSONValue]
    var total: Int?
    var shape: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(L10n.f("%lld 个匹配", files.count) + (total.map { L10n.f(" / 共 %lld", $0) } ?? ""))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ForEach(Array(files.prefix(12).enumerated()), id: \.offset) { _, file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file["path"]?.stringValue ?? file.stringValue ?? "")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let matches = file["matches"]?.arrayValue, !matches.isEmpty {
                        Text(matches.prefix(3).compactMap { $0.stringValue }.joined(separator: " · "))
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            if files.count > 12 {
                Text(L10n.f("… 另 %lld 个", files.count - 12))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

/// web_search sources.
struct WebSourcesView: View {
    var sources: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sources.prefix(6).enumerated()), id: \.offset) { _, source in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(source["title"]?.stringValue ?? source["url"]?.stringValue ?? "")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// Image attachment thumbnail (bytes via unary session/attachment).
///
/// 缩略图本身就是预览入口（DD-05 / AC-14）：**整块可点，含加载中与失败占位**——
/// 附件字节还没到时也必须能点开，否则失败态（AC-20）没有入口；
/// 点击只把「该行的图片组 + 起始下标」交给上层 `imagePreviewAction`，
/// 加载中 / 失败 / 重试的展示全部由预览层承担（缩略图不弹错误）。
struct AttachmentThumbnail: View {
    var ref: ImageRef
    @ObservedObject var attachments: AttachmentStore
    var maxHeight: CGFloat = 200
    var onTap: (() -> Void)? = nil
    /// 可寻址标识（E2E / 无障碍）：调用点传 `<来源>-<seq>-<index>`，
    /// 缺省保持既有的 `attachment-image`（前缀查询仍可命中）。
    /// 必须挂在缩略图自身的可访问元素上：父级容器若只加 identifier 会
    /// 下发覆盖子标识（DEF-007），因此各调用点父容器已用 `children: .contain`。
    var a11yIdentifier: String = "attachment-image"

    var body: some View {
        Group {
            if let image = attachments.image(for: ref) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Theme.Palette.codeBackground)
                    VStack(spacing: 6) {
                        if attachments.failed.contains(ref.attachmentId ?? "") {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Text(L10n.t("图片加载失败"))
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        } else {
                            ProgressView().tint(Theme.Palette.accent)
                            Text(ref.name ?? L10n.t("加载图片…"))
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
                .frame(width: 180, height: 120)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
            }
        }
        // 整块命中（含上方的加载中 / 失败占位）：内容形状覆盖两种分支的实际绘制区域。
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onAppear { attachments.ensureLoaded(ref) }
        .accessibilityIdentifier(a11yIdentifier)
    }
}
