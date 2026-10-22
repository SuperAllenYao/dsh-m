import SwiftUI
import UIKit

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
                Button(L10n.f("显示全部 %lld 行", lines.count)) { showAll = true }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
struct AttachmentThumbnail: View {
    var ref: ImageRef
    @ObservedObject var attachments: AttachmentStore
    var maxHeight: CGFloat = 200
    var onTap: (() -> Void)? = nil

    var body: some View {
        Group {
            if let image = attachments.image(for: ref) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.border, lineWidth: 1))
                    .onTapGesture { onTap?() }
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
        .onAppear { attachments.ensureLoaded(ref) }
        .accessibilityIdentifier("attachment-image")
    }
}
