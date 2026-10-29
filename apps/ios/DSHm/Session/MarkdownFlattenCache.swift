import SwiftUI

// MARK: - Flattener

/// 方案①：超长 Markdown 行的「单视图富文本渲染」。
///
/// 真机证据：回填期 fast fling 的 50–230ms 长帧全部归因于超长 Markdown 行首次物化
/// （mdAppear 紧邻 hitch）——几十个 block 的 SwiftUI 视图树构建 + 两次布局；
/// 解析早已缓存，贵在**视图树物化本身**。分帧追加（MarkdownProgressivePolicy）
/// 实测引发多帧反复重排，已回退。
///
/// 这里把超长文档的全部 block **flatten 成一个 AttributedString**，首现只剩一个
/// 原生 Text 的布局/挂载。拼接是纯 CPU 纯函数，任意线程可调；结果按原文缓存
/// 并在 MarkdownPrewarm 的后台预热批里预构建，首现零解析零拼装。
///
/// 已拍板的 UX 代价（仅超长消息，普通消息走原块级渲染不变）：
/// - 行内代码 chip 从「真圆角 + 0.5px 描边」变底色高亮（MarkdownInline.attributed
/// 的既有形态）；选择能力反而更好（整行连续选择）。
/// - 代码块扁平化：语言横幅与内容变等宽字体 + 底色 run，横向滚动消失。
/// - 表格扁平化：单元格以分隔符拼成连续文本。
/// - 引用竖线变「▎」字符前缀；分隔线变「─」字符行。
/// 选择 / 长按复制 / 链接点击全保留（单 Text + textSelection）。
enum MarkdownFlattener {

 /// blocks → 单个 AttributedString（纯函数；不含缓存）。
    static func attributedString(blocks: [MarkdownBlock], variant: MarkdownRenderVariant) -> AttributedString {
        var result = AttributedString()
        var first = true
        for block in blocks {
            if !first { result.append(blockSpacer) }
            first = false
            append(block, to: &result, variant: variant)
        }
        return result
    }

 /// blocks → segments（纯函数；不含缓存）。连续的非代码块合成一个文本段，
 /// 代码块单独成段；段间距由调用方 VStack 负责，段内不加首尾空行。
    static func segments(blocks: [MarkdownBlock], variant: MarkdownRenderVariant) -> [MarkdownFlattenSegment] {
        var out: [MarkdownFlattenSegment] = []
        var current = AttributedString()
        var hasContent = false

        func flush() {
            guard hasContent else { return }
            out.append(.text(current))
            current = AttributedString()
            hasContent = false
        }

        for block in blocks {
            if case .codeBlock(let language, let code) = block {
                flush()
                out.append(.code(language: language, code: code))
                continue
            }
            if hasContent { current.append(blockSpacer) }
            append(block, to: &current, variant: variant)
            hasContent = true
        }
        flush()
        return out
    }

 /// 块间距（一个空行）。
    private static var blockSpacer: AttributedString {
        AttributedString("\n\n")
    }

 /// 块内换行（列表项/引用行/表格行之间）。
    private static var lineBreak: AttributedString {
        AttributedString("\n")
    }

    private static func append(_ block: MarkdownBlock, to result: inout AttributedString, variant: MarkdownRenderVariant) {
        switch block {
        case .heading(let level, let text):
            let size = MarkdownTypography.headingSize(level: level, variant: variant)
            var run = inlineAttributed(text, codeFontSize: max(11, size - 2))
            applyFont(MarkdownTypography.heading(level: level, variant: variant), to: &run)
            result.append(run)

        case .paragraph(let text):
            var run = inlineAttributed(text, codeFontSize: MarkdownTypography.inlineCodeFontSize(variant))
            applyFont(MarkdownTypography.bodyFont(variant), to: &run)
            result.append(run)

        case .list(let list):
            for (index, item) in list.items.enumerated() {
                if index > 0 { result.append(lineBreak) }
                appendListItem(item, at: index, of: list, to: &result, variant: variant)
            }

        case .codeBlock(let language, let code):
            if let language, !language.isEmpty {
                var banner = AttributedString(language + "\n")
                banner.font = Theme.Typography.monoSmall
                banner.foregroundColor = Theme.Palette.textPrimary
                banner.backgroundColor = Theme.Palette.codeBlockBanner
                result.append(banner)
            }
            var codeRun = AttributedString(code.isEmpty ? " " : code)
            codeRun.font = Theme.Typography.monoSmall
            codeRun.foregroundColor = Theme.Palette.textPrimary
            codeRun.backgroundColor = Theme.Palette.codeBlockBackground
            result.append(codeRun)

        case .quote(let lines):
            for (index, line) in lines.enumerated() {
                if index > 0 { result.append(lineBreak) }
                var bar = AttributedString("▎ ")
                bar.font = MarkdownTypography.bodyFont(variant)
                bar.foregroundColor = Theme.Palette.accentBorder
                result.append(bar)
                var content = inlineAttributed(
                    line.isEmpty ? " " : line,
                    codeFontSize: MarkdownTypography.inlineCodeFontSize(variant)
                )
                applyFont(MarkdownTypography.bodyFont(variant), to: &content)
                applyColor(Theme.Palette.textSecondary, to: &content)
                result.append(content)
            }

        case .horizontalRule:
            result.append(ruleLine(font: MarkdownTypography.bodyFont(variant)))

        case .table(let table):
            appendTable(table, to: &result, variant: variant)
        }
    }

    private static func appendListItem(
        _ item: MarkdownListItem,
        at index: Int,
        of list: MarkdownList,
        to result: inout AttributedString,
        variant: MarkdownRenderVariant
    ) {
        let bodyFont = MarkdownTypography.bodyFont(variant)
        if item.level > 0 {
            var indent = AttributedString(String(repeating: "  ", count: item.level))
            indent.font = bodyFont
            result.append(indent)
        }
        var marker: AttributedString
        if let task = item.task {
            marker = AttributedString(task == .checked ? "☑ " : "☐ ")
            marker.font = bodyFont
            marker.foregroundColor = task == .checked ? Theme.Palette.accent : Theme.Palette.textTertiary
        } else {
            marker = AttributedString(list.ordered ? "\(list.start + index). " : "• ")
            marker.font = bodyFont
            marker.foregroundColor = Theme.Palette.textSecondary
        }
        result.append(marker)
        var content = inlineAttributed(
            item.text.isEmpty ? " " : item.text,
            codeFontSize: MarkdownTypography.inlineCodeFontSize(variant)
        )
        applyFont(bodyFont, to: &content)
        result.append(content)
    }

    private static func appendTable(_ table: MarkdownTable, to result: inout AttributedString, variant: MarkdownRenderVariant) {
        let separator = tableSeparator(cellCount: table.header.count)
        appendTableRow(table.header, font: MarkdownTypography.tableHeaderFont(variant), to: &result)
        result.append(lineBreak)
        result.append(ruleLine(font: MarkdownTypography.bodyFont(variant), character: "─", count: max(8, separator.count)))
        for row in table.rows {
            result.append(lineBreak)
            appendTableRow(row, font: MarkdownTypography.tableBodyFont(variant), to: &result)
        }
    }

    private static func appendTableRow(_ cells: [String], font: Font, to result: inout AttributedString) {
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                var divider = AttributedString("  │  ")
                divider.font = font
                divider.foregroundColor = Theme.Palette.border
                result.append(divider)
            }
            var run = inlineAttributed(cell.isEmpty ? " " : cell, codeFontSize: MarkdownTypography.inlineCodeFontSize(.body))
            applyFont(font, to: &run)
            result.append(run)
        }
    }

 /// 分隔线 run（水平线 / 表头分隔）。
    private static func ruleLine(font: Font, character: Character = "─", count: Int = 24) -> AttributedString {
        var rule = AttributedString(String(repeating: character, count: count))
        rule.font = font
        rule.foregroundColor = Theme.Palette.border
        return rule
    }

 /// 表格分隔线的近似长度（8 + 每列 8 字符）。
    private static func tableSeparator(cellCount: Int) -> String {
        String(repeating: "─", count: 8 + cellCount * 8)
    }

 // MARK: 内联属性拼装

    private static func inlineAttributed(_ text: String, codeFontSize: CGFloat) -> AttributedString {
        MarkdownInline.attributed(text, codeFontSize: codeFontSize)
    }

 /// 给没有显式字体的 run 补上块级字体（chip run 的 mono 字体不覆盖）。
    private static func applyFont(_ font: Font, to source: inout AttributedString) {
        var ranges: [Range<AttributedString.Index>] = []
        for run in source.runs where run.font == nil {
            ranges.append(run.range)
        }
        for range in ranges {
            source[range].font = font
        }
    }

 /// 给没有显式前景色的 run 补上颜色（链接 accent / chip 文字不覆盖）。
    private static func applyColor(_ color: Color, to source: inout AttributedString) {
        var ranges: [Range<AttributedString.Index>] = []
        for run in source.runs where run.foregroundColor == nil {
            ranges.append(run.range)
        }
        for range in ranges {
            source[range].foregroundColor = color
        }
    }
}

/// One renderable slice of a flattened long message (v7).
///
/// Prose blocks stay one `AttributedString` run; fenced code blocks become a
/// real `MarkdownCodeBlockView` so long messages keep the one-tap copy entry.
enum MarkdownFlattenSegment {
    case text(AttributedString)
    case code(language: String?, code: String)
}

// MARK: - Cache

/// 超长 Markdown 行的 flatten 结果缓存（key = 变体 + 原文）。
///
/// 镜像 `MarkdownDocumentCache` 模式：NSCache 线程安全、cost = 源文字节数；
/// 后台预热（MarkdownPrewarm）先行写入，首现主线程命中缓存只剩一次原生 Text 布局。
final class MarkdownFlattenCache {

    static let shared = MarkdownFlattenCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private final class SegmentBox {
        let value: [MarkdownFlattenSegment]
        init(_ value: [MarkdownFlattenSegment]) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()
    private let segmentsCache = NSCache<NSString, SegmentBox>()
    private let lock = NSLock()
    private var missCountStorage = 0

    init(countLimit: Int = 200, totalCostLimit: Int = 48 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        segmentsCache.countLimit = countLimit
        segmentsCache.totalCostLimit = totalCostLimit
    }

 /// Number of flattens performed (cache misses); test/diagnostic only.
    var missCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return missCountStorage
    }

    func attributedString(for text: String, variant: MarkdownRenderVariant) -> AttributedString {
        let key = (variant == .compact ? "c|" : "b|") + text as NSString
        if let box = cache.object(forKey: key) {
            return box.value
        }
        let blocks = MarkdownDocumentCache.shared.blocks(for: text)
        let value: AttributedString
        #if DEBUG
        value = PerfProbe.shared.measure("mdFlatten", ["len": text.count, "blocks": blocks.count]) {
            MarkdownFlattener.attributedString(blocks: blocks, variant: variant)
        }
        #else
        value = MarkdownFlattener.attributedString(blocks: blocks, variant: variant)
        #endif
        lock.lock()
        missCountStorage += 1
        lock.unlock()
        cache.setObject(Box(value), forKey: key, cost: max(text.utf8.count, 1))
        return value
    }

 /// Segmented form of the same flattened document (code blocks kept apart
 /// for the copy header). Cached separately; the all-text case still uses
 /// `attributedString(for:)`.
    func segments(for text: String, variant: MarkdownRenderVariant) -> [MarkdownFlattenSegment] {
        let key = (variant == .compact ? "cs|" : "bs|") + text as NSString
        if let box = segmentsCache.object(forKey: key) {
            return box.value
        }
        let blocks = MarkdownDocumentCache.shared.blocks(for: text)
        let value = MarkdownFlattener.segments(blocks: blocks, variant: variant)
        segmentsCache.setObject(SegmentBox(value), forKey: key, cost: max(text.utf8.count, 1))
        return value
    }

    func removeAll() {
        cache.removeAllObjects()
        segmentsCache.removeAllObjects()
    }
}
