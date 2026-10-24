import SwiftUI
import UIKit

/// Renders tool/result.message[].content + meta per tool shape (v5 05).
struct ToolResultContentView: View {
    var result: ToolResultItem
    var toolName: String
    @ObservedObject var attachments: AttachmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(result.images, id: \.self) { ref in
                AttachmentThumbnail(ref: ref, attachments: attachments, maxHeight: 220)
            }
            if let meta = result.meta {
                metaRendering(meta: meta)
            }
            if !result.text.isEmpty {
                if result.meta?["cwd"] != nil, result.meta?["lines"] == nil, result.meta?["diffs"] == nil {
                    MonoBlock(text: result.text, maxLines: 30, color: result.isError ? Theme.Palette.danger : Theme.Palette.textSecondary)
                } else if result.images.isEmpty {
                    MonoBlock(text: result.text, maxLines: 30, color: result.isError ? Theme.Palette.danger : Theme.Palette.textSecondary)
                }
            }
            if let cwd = result.meta?["cwd"]?.stringValue {
                Text("cwd: " + cwd)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("tool-result-content")
    }

    @ViewBuilder
    private func metaRendering(meta: JSONValue) -> some View {
        if let diffs = meta["diffs"]?.arrayValue {
            DiffView(diffs: diffs, operation: meta["operation"]?.stringValue)
        } else if let lines = meta["lines"]?.arrayValue {
            NumberedCodeView(
                path: meta["path"]?.stringValue,
                lang: meta["lang"]?.stringValue,
                offset: meta["offset"]?.int,
                totalLines: meta["totalLines"]?.int,
                lines: lines,
                fallbackText: result.text
            )
        } else if let files = meta["files"]?.arrayValue {
            FileMatchListView(files: files, total: meta["total"]?.int, shape: meta["shape"]?.stringValue)
        } else if let paths = meta["paths"]?.arrayValue {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: L10n.f("%lld 个路径", paths.count))
                ForEach(Array(paths.prefix(20).enumerated()), id: \.offset) { _, path in
                    Text(path.stringValue ?? "")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else if let sources = meta["sources"]?.arrayValue {
            WebSourcesView(sources: sources)
        } else if let url = meta["url"]?.stringValue {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(url)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let status = meta["statusCode"]?.int {
                    Text("HTTP \(status)")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        } else if let path = meta["path"]?.stringValue {
            Text(path)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Per-turn file change card. Data source (protocol §3.9):
/// `/api/changes.summary` via the link exact-fetch proxy (Host memory) with
/// tool/result.meta.diffs as the 404 fallback. Tapping opens the file list/diff.
struct FileChangesCard: View {
    var changes: TurnFileChanges
    var onTap: () -> Void

    /// 来源只有两种，#2：任何时刻都不表达「读取中」——精确数据未就绪时先显示
    /// 工具聚合数字，exact 到达后原地替换（绝不出现 spinner/占位文案）。
    private var sourceLabel: String {
        switch changes.source {
        case .exactFetch: return "Host"
        case .metaDiffsFallback: return L10n.t("工具聚合")
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text("本轮文件变更")
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(sourceLabel)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                // #2（2026-10-24 用户拍板）：卡片始终显示数字，不出现 loading/转圈。
                // 与桌面端口径一致：标题文件数用 Host 的 total（不是 files 数组长度）；
                // exact 未就绪时这就是工具聚合数字，精确数据到达后同一行原地替换。
                Text(L10n.f("%lld 个文件 · +%lld -%lld", changes.titleFileCount, changes.added, changes.deleted))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .accessibilityIdentifier("file-changes-card")
    }
}
