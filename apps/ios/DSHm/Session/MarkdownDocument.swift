import Foundation

// MARK: - Block model

/// One block-level Markdown element.
///
/// Inline syntax (bold / italic / strikethrough / inline code / links) is *not*
/// parsed here: blocks keep their raw inline source and the renderer funnels it
/// through `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(MarkdownList)
    case codeBlock(language: String?, code: String)
 /// Quote lines with the leading `>` marker stripped; empty strings keep blank lines.
    case quote([String])
    case horizontalRule
    case table(MarkdownTable)
}

struct MarkdownList: Equatable {
    var ordered: Bool
 /// First number of an ordered list; `1` for unordered lists.
    var start: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Equatable {
    var text: String
 /// Nesting depth. The parser/renderer support two levels: 0 (top) and 1 (nested).
    var level: Int
 /// Task-list checkbox state (`- [ ]` / `- [x]`), `nil` for plain items.
    var task: MarkdownTaskState?
}

enum MarkdownTaskState: Equatable {
    case unchecked
    case checked
}

struct MarkdownTable: Equatable {
    var header: [String]
    var rows: [[String]]
}

// MARK: - Render policy

/// Guard rails for rendering assistant/user markdown inside a SwiftUI body.
enum MarkdownRenderPolicy {
 /// Anything larger than this is shown as one plain text block instead of being
 /// parsed: streaming bodies can grow large and block parsing on every frame.
    static let maxParseBytes = 512 * 1024

    static func shouldParse(_ text: String) -> Bool {
        text.utf8.count <= maxParseBytes
    }

 // MARK: 方案①单视图富文本

 /// 超长消息切「一个预构建 AttributedString + 单 Text」渲染（方案①），
 /// 普通消息保持块级渲染。真机归因：回填期 fast fling 的 50–230ms 长帧
 /// 全部落在超长 Markdown 行首次物化（mdAppear）；block 解析已缓存，
 /// 贵在几十个 block 的 SwiftUI 视图树构建 + 两次布局。
 /// 阈值依据真机数据：长帧行 chars 1000–1800 / blocks 10–19。
    static let flattenCharThreshold = 800
    static let flattenBlockThreshold = 10

 /// 默认开启；DEBUG 下 `DSHM_MD_SINGLEVIEW=0` 关闭（before/after 取证用）。
    static let isFlattenEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_MD_SINGLEVIEW"] != "0"
        #else
        return true
        #endif
    }()

    static func shouldFlatten(text: String, blockCount: Int) -> Bool {
        guard isFlattenEnabled, !text.isEmpty, shouldParse(text) else { return false }
        return text.count > flattenCharThreshold || blockCount >= flattenBlockThreshold
    }
}

// MARK: - Parser

/// Minimal block-level Markdown parser (pure Swift, no dependencies).
///
/// Supported blocks: ATX headings, paragraphs, unordered/ordered lists with one
/// level of nesting, task lists, fenced code blocks (含嵌套在列表项里的深层缩进围栏),
/// indented code blocks, blockquotes, thematic breaks and pipe tables. Deliberately
/// tolerant: malformed input degrades to paragraph text instead of throwing.
enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }
        let lines = splitLines(text)
        var blocks: [MarkdownBlock] = []
        blocks.reserveCapacity(max(1, lines.count / 3))
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                index += 1
                continue
            }
            if let fence = parseFenceStart(line) {
                let consumed = consumeFencedCode(lines, from: index, fence: fence)
                blocks.append(.codeBlock(language: fence.language, code: consumed.code))
                index = consumed.nextIndex
                continue
            }
 // 缩进代码块只在「文档开头或空行之后」起始：CommonMark 里它不能打断段落；
 // 紧跟围栏/列表项的行保留原语义（避免把列表里的缩进说明文字误渲染成代码）。
            if index == 0 || isBlank(lines[index - 1]),
               let consumed = consumeIndentedCode(lines, from: index) {
                blocks.append(.codeBlock(language: nil, code: consumed.code))
                index = consumed.nextIndex
                continue
            }
            if let heading = parseATXHeading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if isThematicBreak(line) {
                blocks.append(.horizontalRule)
                index += 1
                continue
            }
            if let consumed = consumeTable(lines, from: index) {
                blocks.append(.table(consumed.table))
                index = consumed.nextIndex
                continue
            }
            if isBlockquoteLine(line) {
                let consumed = consumeBlockquote(lines, from: index)
                blocks.append(.quote(consumed.lines))
                index = consumed.nextIndex
                continue
            }
            if let marker = parseListMarker(line) {
                let consumed = consumeList(lines, from: index, first: marker)
                blocks.append(.list(consumed.list))
                index = consumed.nextIndex
                continue
            }
            let consumed = consumeParagraph(lines, from: index)
            blocks.append(.paragraph(consumed.text))
            index = max(consumed.nextIndex, index + 1)
        }
        return blocks
    }

 // MARK: Lines

    private static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

 /// Returns the characters after at most three leading spaces, or nil when the
 /// line is indented by four or more spaces (which CommonMark treats as code).
    private static func indentStripped(_ line: String) -> [Character]? {
        let chars = Array(line)
        var index = 0
        while index < chars.count, index < 4, chars[index] == " " { index += 1 }
        guard index <= 3 else { return nil }
        return Array(chars[index...])
    }

 // MARK: Headings

    private static func parseATXHeading(_ line: String) -> (level: Int, text: String)? {
        let chars = Array(line)
        var index = 0
        while index < chars.count, index < 4, chars[index] == " " { index += 1 }
        guard index <= 3, index < chars.count, chars[index] == "#" else { return nil }
        var level = 0
        while index + level < chars.count, chars[index + level] == "#" { level += 1 }
        guard (1...6).contains(level) else { return nil }
        let contentStart = index + level
        if contentStart < chars.count {
            guard chars[contentStart] == " " || chars[contentStart] == "\t" else { return nil }
        }
        var content = contentStart < chars.count ? String(chars[contentStart...]) : ""
        content = content.trimmingCharacters(in: .whitespaces)
 // Optional closing sequence: `## Title ##` -> "Title"; `# C#` keeps the sharp.
        var closingHashes = 0
        while content.hasSuffix("#") {
            content.removeLast()
            closingHashes += 1
        }
        if closingHashes > 0 {
            if content.isEmpty {
 // all hashes were the closing sequence
            } else if content.hasSuffix(" ") || content.hasSuffix("\t") {
                content = content.trimmingCharacters(in: .whitespaces)
            } else {
                content += String(repeating: "#", count: closingHashes)
            }
        }
        return (level, content)
    }

 // MARK: Thematic break

    private static func isThematicBreak(_ line: String) -> Bool {
        let chars = Array(line)
        var index = 0
        while index < chars.count, index < 4, chars[index] == " " { index += 1 }
        guard index <= 3 else { return false }
        var marker: Character?
        var count = 0
        var cursor = index
        while cursor < chars.count {
            let char = chars[cursor]
            if char == " " || char == "\t" {
                cursor += 1
                continue
            }
            guard char == "-" || char == "*" || char == "_" else { return false }
            if let marker, marker != char { return false }
            marker = char
            count += 1
            cursor += 1
        }
        return count >= 3
    }

 // MARK: Fenced code

    private struct Fence {
        var character: Character
        var length: Int
        var language: String?
 /// 围栏起始行的缩进列数（tab 记 4 列）。用于闭合围栏匹配与内容去缩进。
        var indent: Int = 0
    }

 /// 识别围栏起始行。
 ///
 /// 桌面端（CommonMark）允许围栏嵌在列表项/引用里，这时其缩进会 ≥4 列，
 /// 例如 `1. 步骤：` 下面 5 空格缩进的 ```yaml。App 的列表模型是「一行一项」
 /// 的扁平结构，无法承载嵌套块，所以这里放宽为**任意缩进都识别为围栏**，
 /// 由主循环把它提级渲染成代码块（内容按围栏缩进去缩）；否则这类内容会
 /// 被列表的惰性续行吞成普通文本（用户问题 6）。
    private static func parseFenceStart(_ line: String) -> Fence? {
        let chars = Array(line)
        var indent = 0
        var cursor = 0
        while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
            indent += chars[cursor] == "\t" ? 4 : 1
            cursor += 1
        }
        guard cursor < chars.count else { return nil }
        let first = chars[cursor]
        guard first == "`" || first == "~" else { return nil }
        var run = 0
        while cursor + run < chars.count, chars[cursor + run] == first { run += 1 }
        guard run >= 3 else { return nil }
        let rest = cursor + run < chars.count
            ? String(chars[(cursor + run)...]).trimmingCharacters(in: .whitespaces)
            : ""
 // A backtick info string may not contain backticks (CommonMark).
        if first == "`", rest.contains("`") { return nil }
        let language = rest.isEmpty
            ? nil
            : rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return Fence(character: first, length: run, language: language, indent: indent)
    }

    private static func isFenceClose(_ line: String, fence: Fence) -> Bool {
        let chars = Array(line)
        var index = 0
        var columns = 0
 // 闭合围栏允许的缩进：顶格围栏沿用 CommonMark 的「至多 3 空格」；深层围栏
 // 则允许缩进到与起始行齐平（列表里嵌套的围栏，闭合行同样带缩进）。
        let allowance = max(3, fence.indent)
        while index < chars.count, columns < allowance,
              chars[index] == " " || chars[index] == "\t" {
            columns += chars[index] == "\t" ? 4 : 1
            index += 1
        }
        guard index < chars.count, chars[index] == fence.character else { return false }
        var run = 0
        while index + run < chars.count, chars[index + run] == fence.character { run += 1 }
        guard run >= fence.length else { return false }
        return chars[(index + run)...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func consumeFencedCode(
        _ lines: [String],
        from start: Int,
        fence: Fence
    ) -> (code: String, nextIndex: Int) {
        var index = start + 1
        var codeLines: [String] = []
        while index < lines.count {
            if isFenceClose(lines[index], fence: fence) {
                return (codeLines.joined(separator: "\n"), index + 1)
            }
            codeLines.append(dedent(lines[index], by: fence.indent))
            index += 1
        }
 // Unterminated fence: consume everything that is left.
        return (codeLines.joined(separator: "\n"), lines.count)
    }

 /// 去掉至多 `columns` 列前导空白（tab 记 4 列）。围栏缩进多深，就把它内容的
 /// 同量缩进去掉，这样提级渲染后代码块左侧不会留下一大段空白。
    private static func dedent(_ line: String, by columns: Int) -> String {
        guard columns > 0 else { return line }
        let chars = Array(line)
        var index = 0
        var consumed = 0
        while index < chars.count, consumed < columns,
              chars[index] == " " || chars[index] == "\t" {
            let width = chars[index] == "\t" ? 4 : 1
            if consumed + width > columns { break }
            consumed += width
            index += 1
        }
        guard index > 0 else { return line }
        return index < chars.count ? String(chars[index...]) : ""
    }

 // MARK: Indented code

 /// 缩进代码块（4 空格或 1 个 tab 起）：桌面端（CommonMark）渲染为代码块，
 /// App 之前会把它当普通段落（缩进被 trim），用户问题 6 的另一类形态。
 ///
 /// 只在「块起始处」调用（主循环已跳过空行），因此不会把段落里的续行
 /// 误判成代码块 —— CommonMark 里缩进代码块也不能打断段落。
    private static func consumeIndentedCode(
        _ lines: [String],
        from start: Int
    ) -> (code: String, nextIndex: Int)? {
        guard indentedCodeLine(lines[start]) != nil else { return nil }
        var index = start
        var codeLines: [String] = []
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
 // 空行只有后面还跟着缩进行时才算代码内容；块末尾的空行丢掉。
                var lookahead = index + 1
                while lookahead < lines.count, isBlank(lines[lookahead]) { lookahead += 1 }
                if lookahead < lines.count, indentedCodeLine(lines[lookahead]) != nil {
                    codeLines.append("")
                    index = lookahead
                    continue
                }
                break
            }
            guard let stripped = indentedCodeLine(line) else { break }
            codeLines.append(stripped)
            index += 1
        }
        while let last = codeLines.last, last.isEmpty { codeLines.removeLast() }
        guard !codeLines.isEmpty else { return nil }
        return (codeLines.joined(separator: "\n"), index)
    }

 /// 4 空格（或 1 个 tab）缩进行返回去掉这层缩进后的内容，否则 nil。
    private static func indentedCodeLine(_ line: String) -> String? {
        let chars = Array(line)
        if chars.first == "\t" {
            return String(chars.dropFirst())
        }
        var index = 0
        while index < chars.count, index < 4, chars[index] == " " { index += 1 }
        guard index >= 4 else { return nil }
        return index < chars.count ? String(chars[index...]) : ""
    }

 // MARK: Blockquote

    private static func isBlockquoteLine(_ line: String) -> Bool {
        let chars = Array(line)
        var index = 0
        while index < chars.count, index < 4, chars[index] == " " { index += 1 }
        guard index <= 3, index < chars.count else { return false }
        return chars[index] == ">"
    }

    private static func consumeBlockquote(_ lines: [String], from start: Int) -> (lines: [String], nextIndex: Int) {
        var index = start
        var quoted: [String] = []
        while index < lines.count, isBlockquoteLine(lines[index]) {
            let chars = Array(lines[index])
            var cursor = 0
            while cursor < chars.count, cursor < 4, chars[cursor] == " " { cursor += 1 }
            cursor += 1 // consume ">"
            if cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" { cursor += 1 }
            quoted.append(cursor < chars.count ? String(chars[cursor...]) : "")
            index += 1
        }
        while let last = quoted.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            quoted.removeLast()
        }
        return (quoted.isEmpty ? [""] : quoted, index)
    }

 // MARK: Lists

    private struct ListMarker {
        var ordered: Bool
        var start: Int
        var indent: Int
        var content: String
        var task: MarkdownTaskState?

        var level: Int { indent >= 2 ? 1 : 0 }
    }

    private static func parseListMarker(_ line: String) -> ListMarker? {
        let chars = Array(line)
        var indent = 0
        var index = 0
        while index < chars.count, chars[index] == " " || chars[index] == "\t" {
            indent += chars[index] == "\t" ? 4 : 1
            index += 1
        }
        guard index < chars.count else { return nil }
        let ordered: Bool
        let start: Int
        switch chars[index] {
        case "-", "*", "+":
            ordered = false
            start = 1
            index += 1
        case _ where chars[index].isASCII && chars[index].isNumber:
            var digits = ""
            while index < chars.count, chars[index].isASCII, chars[index].isNumber {
                digits.append(chars[index])
                index += 1
            }
            guard index < chars.count, chars[index] == "." || chars[index] == ")",
                  let number = Int(digits) else { return nil }
            ordered = true
            start = number
            index += 1
        default:
            return nil
        }
        guard index < chars.count, chars[index] == " " || chars[index] == "\t" else { return nil }
        index += 1
        var content = index < chars.count ? String(chars[index...]) : ""
        content = content.trimmingCharacters(in: .whitespaces)
        var task: MarkdownTaskState?
        if !ordered, let state = parseTaskMarker(content) {
            task = state.state
            content = state.remaining
        }
        return ListMarker(ordered: ordered, start: start, indent: indent, content: content, task: task)
    }

    private static func parseTaskMarker(_ content: String) -> (state: MarkdownTaskState, remaining: String)? {
        let chars = Array(content)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let box = chars[1]
        let state: MarkdownTaskState
        if box == " " {
            state = .unchecked
        } else if box == "x" || box == "X" {
            state = .checked
        } else {
            return nil
        }
        if chars.count > 3, chars[3] != " ", chars[3] != "\t" { return nil }
        let remaining = String(chars.dropFirst(min(4, chars.count))).trimmingCharacters(in: .whitespaces)
        return (state, remaining)
    }

    private static func consumeList(
        _ lines: [String],
        from start: Int,
        first: ListMarker
    ) -> (list: MarkdownList, nextIndex: Int) {
        var items: [MarkdownListItem] = []
        var index = start
        let ordered = first.ordered
        let listStart = first.start
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { break }
            if let marker = parseListMarker(line) {
 // A different list kind at the top level starts a new list block.
                if marker.ordered != ordered, marker.level == 0 { break }
                items.append(MarkdownListItem(text: marker.content, level: marker.level, task: marker.task))
                index += 1
                continue
            }
            if startsBlock(lines, at: index) { break }
 // Lazy continuation line: fold it into the previous item.
            if var last = items.popLast() {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                if !continuation.isEmpty {
                    last.text = last.text.isEmpty ? continuation : last.text + " " + continuation
                }
                items.append(last)
            }
            index += 1
        }
        return (MarkdownList(ordered: ordered, start: listStart, items: items), index)
    }

 // MARK: Tables

    private static func consumeTable(
        _ lines: [String],
        from start: Int
    ) -> (table: MarkdownTable, nextIndex: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start]
        guard headerLine.contains("|") else { return nil }
        guard let columnCount = tableDelimiterColumnCount(lines[start + 1]) else { return nil }
        let header = tableCells(headerLine)
        guard header.count == columnCount, columnCount > 0 else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) || !line.contains("|") { break }
            if parseFenceStart(line) != nil { break }
            let cells = tableCells(line)
            if cells.isEmpty { break }
            rows.append(normalize(cells, to: columnCount))
            index += 1
        }
        return (MarkdownTable(header: header, rows: rows), index)
    }

    private static func normalize(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

 /// Column count of a table delimiter row (`| --- |:--: |`), nil when the line
 /// is not a delimiter row.
    private static func tableDelimiterColumnCount(_ line: String) -> Int? {
        guard line.contains("|") || line.contains("-") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        for cell in cells where !isDelimiterCell(cell) { return nil }
        return cells.count
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        var chars = Array(cell.trimmingCharacters(in: .whitespaces))
        if chars.first == ":" { chars.removeFirst() }
        if chars.last == ":" { chars.removeLast() }
        guard !chars.isEmpty else { return false }
        return chars.allSatisfy { $0 == "-" }
    }

    private static func tableCells(_ rawLine: String) -> [String] {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|"), !endsWithEscapedPipe(line) { line.removeLast() }
        var cells: [String] = []
        var current = ""
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func endsWithEscapedPipe(_ line: String) -> Bool {
        guard line.hasSuffix("|") else { return false }
        var backslashes = 0
        var index = line.index(before: line.endIndex)
        while index > line.startIndex {
            index = line.index(before: index)
            guard line[index] == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

 // MARK: Paragraph

    private static func consumeParagraph(
        _ lines: [String],
        from start: Int
    ) -> (text: String, nextIndex: Int) {
        var parts: [String] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { break }
            if index > start, startsBlock(lines, at: index) { break }
            parts.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return (parts.joined(separator: "\n"), max(index, start + 1))
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if isBlank(line) { return true }
        if parseFenceStart(line) != nil { return true }
        if parseATXHeading(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if isBlockquoteLine(line) { return true }
        if parseListMarker(line) != nil { return true }
        if line.contains("|"), index + 1 < lines.count,
           tableDelimiterColumnCount(lines[index + 1]) != nil {
            return true
        }
        return false
    }
}

// MARK: - Cache

/// Caches parsed block lists keyed by the full source text.
///
/// SwiftUI re-evaluates `MarkdownText.body` whenever a parent row updates (the
/// streaming assistant row updates every frame); parsing is only repeated when the
/// text actually changed. NSCache bounds memory (cost == source byte count).
final class MarkdownDocumentCache {

    static let shared = MarkdownDocumentCache()

    private let cache: NSCache<NSString, MarkdownDocumentBox>
    private let lock = NSLock()
    private var missCountStorage = 0

    init(countLimit: Int = 400, totalCostLimit: Int = 32 * 1024 * 1024) {
        cache = NSCache()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

 /// Number of parses performed (cache misses); test/diagnostic only.
    var missCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return missCountStorage
    }

    func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let boxed = cache.object(forKey: key) {
            return boxed.blocks
        }
        #if DEBUG
        let blocks = PerfProbe.shared.measure("mdParse", ["len": text.count]) {
            MarkdownParser.parse(text)
        }
        #else
        let blocks = MarkdownParser.parse(text)
        #endif
        lock.lock()
        missCountStorage += 1
        lock.unlock()
        cache.setObject(MarkdownDocumentBox(blocks), forKey: key, cost: max(text.utf8.count, 1))
        return blocks
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private final class MarkdownDocumentBox {
    let blocks: [MarkdownBlock]

    init(_ blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }
}
