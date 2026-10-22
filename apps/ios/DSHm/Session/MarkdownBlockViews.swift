import SwiftUI
import UIKit

// MARK: - Markdown typography tokens

/// Type ramp for rendered markdown. Sizes come from the ui-baseline type scale;
/// existing `Theme.Typography` tokens are reused where they match (no new colors).
enum MarkdownTypography {
    static let h1 = Theme.Typography.title                     // 20 semibold
    static let h2 = Font.system(size: 17, weight: .semibold)
    static let h3 = Theme.Typography.cardTitle                 // 15 semibold
    static let h4 = Theme.Typography.bodyMedium                // 14 medium
    static let tableHeader = Font.system(size: 14, weight: .semibold)
    static let inlineCode = Font.system(size: 13, weight: .regular, design: .monospaced)

    static func heading(level: Int) -> Font {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        default: return h4 // h4-h6 share one step, per baseline minimum sizes
        }
    }

    static func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }
}

// MARK: - Inline markdown

enum MarkdownInline {
    /// Inline-only markdown (bold / italic / strikethrough / inline code / links).
    ///
    /// Block syntax is handled by `MarkdownDocument`; inline code and links get
    /// explicit attributes so they stay visually distinct after rendering.
    static func attributed(_ text: String, codeFontSize: CGFloat = 13) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        // Collect first: mutating attributes invalidates run iteration state.
        var styled: [(range: Range<AttributedString.Index>, isCode: Bool, isLink: Bool)] = []
        for run in result.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) ?? false
            styled.append((run.range, isCode, run.link != nil))
        }
        for item in styled {
            if item.isCode {
                result[item.range].font = .system(size: codeFontSize, weight: .regular, design: .monospaced)
                result[item.range].foregroundColor = Theme.Palette.accent
            } else if item.isLink {
                result[item.range].foregroundColor = Theme.Palette.accent
                result[item.range].underlineStyle = .single
            }
        }
        return result
    }
}

/// Renders one inline-markdown string as a selectable, wrapping text.
struct MarkdownInlineText: View {
    var text: String
    var color: Color
    var font: Font = Theme.Typography.body
    var codeFontSize: CGFloat = 13
    var lineSpacing: CGFloat = 4

    var body: some View {
        Text(MarkdownInline.attributed(text, codeFontSize: codeFontSize))
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Document view

/// Block-level Markdown renderer behind `MarkdownText`.
///
/// Parsing is cached by source text (`MarkdownDocumentCache`); texts above
/// `MarkdownRenderPolicy.maxParseBytes` fall back to a single plain text block.
struct MarkdownDocumentView: View {
    var text: String
    var color: Color = Theme.Palette.textPrimary

    var body: some View {
        Group {
            if MarkdownRenderPolicy.shouldParse(text) {
                blocksView
            } else {
                plainTextView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocksView: some View {
        let blocks = MarkdownDocumentCache.shared.blocks(for: text)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var plainTextView: some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(color)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Block dispatch

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let color: Color

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownHeadingView(level: level, text: text, color: color)
        case .paragraph(let text):
            MarkdownInlineText(text: text, color: color)
        case .list(let list):
            MarkdownListView(list: list, color: color)
        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code)
        case .quote(let lines):
            MarkdownQuoteView(lines: lines)
        case .horizontalRule:
            MarkdownHorizontalRuleView()
        case .table(let table):
            MarkdownTableView(table: table, color: color)
        }
    }
}

// MARK: - Heading

struct MarkdownHeadingView: View {
    let level: Int
    let text: String
    let color: Color

    var body: some View {
        MarkdownInlineText(
            text: text,
            color: color,
            font: MarkdownTypography.heading(level: level),
            codeFontSize: max(11, MarkdownTypography.headingSize(level: level) - 2),
            lineSpacing: 2
        )
        .padding(.top, level <= 2 ? Theme.Spacing.xxs : 0)
    }
}

// MARK: - Lists

struct MarkdownListView: View {
    let list: MarkdownList
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                MarkdownListItemView(
                    item: item,
                    marker: marker(at: index),
                    color: color
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func marker(at index: Int) -> String {
        list.ordered ? "\(list.start + index)." : "•"
    }
}

struct MarkdownListItemView: View {
    let item: MarkdownListItem
    let marker: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let task = item.task {
                Image(systemName: task == .checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(task == .checked ? Theme.Palette.accent : Theme.Palette.textTertiary)
            } else {
                Text(marker)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
            MarkdownInlineText(text: item.text.isEmpty ? " " : item.text, color: color)
        }
        .padding(.leading, CGFloat(item.level) * Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Code block

/// Fenced code block: MonoBlock-style surface (horizontal scroll, mono type,
/// code background) plus an optional language label.
struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.top, Theme.Spacing.xs)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quote

struct MarkdownQuoteView: View {
    let lines: [String]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Palette.accentBorder)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Color.clear.frame(height: Theme.Spacing.xxs)
                    } else {
                        MarkdownInlineText(text: line, color: Theme.Palette.textSecondary, lineSpacing: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Horizontal rule

struct MarkdownHorizontalRuleView: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(height: 1)
            .padding(.vertical, Theme.Spacing.xxs)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Table

/// Pipe table: bold header + hairline separator, left-aligned cells, adaptive
/// column widths, horizontal scrolling when wider than the bubble.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let color: Color

    var body: some View {
        let widths = MarkdownTableMetrics.columnWidths(for: table)
        let spacing = Theme.Spacing.s
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, widths: widths, spacing: spacing, font: MarkdownTypography.tableHeader, textColor: color)
                    .padding(.vertical, Theme.Spacing.xs)
                Rectangle()
                    .fill(Theme.Palette.border)
                    .frame(width: totalWidth, height: 1)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    row(cells, widths: widths, spacing: spacing, font: Theme.Typography.body, textColor: color)
                        .padding(.vertical, Theme.Spacing.xs)
                }
            }
            .frame(width: totalWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(
        _ cells: [String],
        widths: [CGFloat],
        spacing: CGFloat,
        font: Font,
        textColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                let cell = index < cells.count ? cells[index] : ""
                MarkdownInlineText(text: cell.isEmpty ? " " : cell, color: textColor, font: font)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

/// Approximate intrinsic column widths (UIKit measurement of the plain-text
/// projection). Caps keep a single wordy cell from stretching the table too far;
/// anything wider than the viewport scrolls horizontally.
enum MarkdownTableMetrics {
    static let minColumnWidth: CGFloat = 44
    static let maxColumnWidth: CGFloat = 280
    private static let cellSlack: CGFloat = 4

    static func columnWidths(for table: MarkdownTable) -> [CGFloat] {
        let columns = table.header.count
        guard columns > 0 else { return [] }
        var widths = [CGFloat](repeating: minColumnWidth, count: columns)
        let bodyFont = UIFont.systemFont(ofSize: 14)
        let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        for (index, cell) in table.header.enumerated() {
            widths[index] = max(widths[index], measure(cell, font: headerFont))
        }
        for row in table.rows {
            for (index, cell) in row.enumerated() where index < columns {
                widths[index] = max(widths[index], measure(cell, font: bodyFont))
            }
        }
        return widths.map { min(maxColumnWidth, max(minColumnWidth, $0)) }
    }

    private static func measure(_ markdown: String, font: UIFont) -> CGFloat {
        let plain = plainText(markdown)
        guard !plain.isEmpty else { return 0 }
        let width = (plain as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + cellSlack
    }

    /// Rough plain-text projection: strips inline markers so measurement is not
    /// inflated by `**`, backticks or link destinations.
    private static func plainText(_ markdown: String) -> String {
        var result = stripLinkDestinations(markdown)
        for token in ["**", "__", "~~", "`"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "_", with: "")
        return result
    }

    private static func stripLinkDestinations(_ text: String) -> String {
        guard text.contains("](") else { return text }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let closeBracket = text[cursor...].firstIndex(of: "]") else {
                result += text[cursor...]
                break
            }
            let afterBracket = text.index(after: closeBracket)
            if afterBracket < text.endIndex, text[afterBracket] == "(",
               let closeParen = text[afterBracket...].firstIndex(of: ")") {
                result += text[cursor..<closeBracket]
                cursor = text.index(after: closeParen)
            } else {
                result += text[cursor...afterBracket]
                cursor = afterBracket
            }
        }
        return result
    }
}
