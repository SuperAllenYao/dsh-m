import SwiftUI
import UIKit

// MARK: - Render variant

/// Markdown 渲染密度。
///
/// `.body` 是会话正文的现有样式（默认值，字号/间距与 v2.15.0 保持不变）；
/// `.compact` 供「思考」这类紧凑区域使用：整体降一档字号，但保留代码块、
/// 表格等块级能力 —— 桌面端思考内容同样走 MarkdownText（用户问题 6）。
enum MarkdownRenderVariant: Equatable {
    case body
    case compact
}

private struct MarkdownRenderVariantKey: EnvironmentKey {
    static let defaultValue: MarkdownRenderVariant = .body
}

extension EnvironmentValues {
 /// 当前 Markdown 渲染密度，由 `MarkdownDocumentView(variant:)` 注入。
    var markdownRenderVariant: MarkdownRenderVariant {
        get { self[MarkdownRenderVariantKey.self] }
        set { self[MarkdownRenderVariantKey.self] = newValue }
    }
}

// MARK: - Markdown typography tokens

/// Type ramp for rendered markdown. Sizes come from the type scale;
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

 // MARK: 渲染变体取值

 /// 正文档：body = 14（现状），compact = 13（思考块）。
    static func bodyFont(_ variant: MarkdownRenderVariant) -> Font {
        variant == .compact ? Theme.Typography.caption : Theme.Typography.body
    }

    static func heading(level: Int, variant: MarkdownRenderVariant) -> Font {
        guard variant == .compact else { return heading(level: level) }
        switch level {
        case 1: return Theme.Typography.cardTitle                 // 15 semibold
        case 2: return Theme.Typography.bodyMedium                // 14 medium
        case 3: return Font.system(size: 13, weight: .semibold)
        default: return Theme.Typography.label                    // 12 medium
        }
    }

    static func headingSize(level: Int, variant: MarkdownRenderVariant) -> CGFloat {
        guard variant == .compact else { return headingSize(level: level) }
        switch level {
        case 1: return 15
        case 2: return 14
        case 3: return 13
        default: return 12
        }
    }

    static func tableHeaderFont(_ variant: MarkdownRenderVariant) -> Font {
        variant == .compact ? Theme.Typography.captionMedium : tableHeader
    }

    static func tableBodyFont(_ variant: MarkdownRenderVariant) -> Font {
        variant == .compact ? Theme.Typography.caption : Theme.Typography.body
    }

 /// 行内代码字号：桌面端 `font-size:.875em`。app 正文 14 → 12，compact 13 → 11。
    static func inlineCodeFontSize(_ variant: MarkdownRenderVariant) -> CGFloat {
        variant == .compact ? 11 : 12
    }

    static func lineSpacing(_ variant: MarkdownRenderVariant) -> CGFloat {
        variant == .compact ? 3 : 4
    }
}

// MARK: - Inline markdown

enum MarkdownInline {
 /// Inline-only markdown (bold / italic / strikethrough / inline code / links).
 ///
 /// Block syntax is handled by `MarkdownDocument`; inline code and links get
 /// explicit attributes so they stay visually distinct after rendering.
 ///
 /// 行内代码（v7 task-6，桌面 parity）：中性灰底 chip + 中性文字色 + 等宽字体，
 /// 不再是主题色文字。桌面端样式来自 app.asar 解包核对：
 /// `._markdown_1ypvv_5:not(pre)>code`（bg = --dsw-alias-markdown-inline-code
 /// dark #292929；border.5px #ffffff0f；radius 8px；padding 0 5px；font 12px mono）。
 ///
 /// **取舍**：SwiftUI `AttributedString` 只支持矩形 `backgroundColor`，没有 per-run
 /// 的圆角 / 描边 / 内边距。这里用 thin space（U+2009）在代码前后各补约 2.7pt 近似
 /// 桌面端左右 5px padding，底色随 run 一起铺开；8px 圆角与 0.5px 描边无法在 Text
 /// run 上表达，故放弃（要真圆角需自绘 inline flow layout，成本高、暂不做）。
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
 // 行内代码要插入 padding 字符，range 会失效：从后往前替换。
        let codeRuns = styled.filter { $0.isCode }.map { $0.range }
        for range in codeRuns.reversed() {
            let content = String(result[range].characters)
            var chip = AttributedString("\u{2009}" + content + "\u{2009}")
            chip.inlinePresentationIntent = .code
            chip.font = .system(size: codeFontSize, weight: .regular, design: .monospaced)
            chip.foregroundColor = Theme.Palette.textPrimary
            chip.backgroundColor = Theme.Palette.inlineCodeBackground
            result.replaceSubrange(range, with: chip)
        }
        for item in styled where item.isLink {
            result[item.range].foregroundColor = Theme.Palette.accent
            result[item.range].underlineStyle = .single
        }
        return result
    }
}

// MARK: - Inline flow（行内代码真圆角 chip；v7 task-7）

/// 行内 Markdown 的流式排布 token。
///
/// 行内代码要真圆角/描边/内边距，SwiftUI `Text` + AttributedString 做不到（background
/// 只能画矩形、没有 per-run 圆角），所以把 inline markdown 拆成可断行 token，用下面的
/// 自定义 `Layout` 排布；不含行内代码的文本继续走原单 Text 路径（保选择与性能）。
struct MarkdownInlineToken: Equatable {
    enum Kind: Equatable {
 /// 可断行文本（Latin 单词 / CJK 单字 / 标点）。
        case text
 /// 行内代码 chip（原子单元；超宽时由 Layout 给整行并允许内部换行）。
        case code
 /// 空白（换行到行首时折叠为 0 宽）。
        case whitespace
    }

    var kind: Kind
    var text: String
    var bold = false
    var italic = false
    var strikethrough = false
    var link: URL?
 /// 行首禁则：CJK 收尾标点（。、；」等）不允许出现在行首（桌面浏览器 CSS 行为一致）。
    var noBreakBefore = false
}

/// inline markdown → 流式 token。
///
/// 解析复用 Foundation 的 inline-only AttributedString：bold / italic / strikethrough /
/// link / code 已经被解析成 run 属性，避免自己写一套 inline 语法解析。
enum MarkdownInlineTokenizer {
 /// 是否含行内代码（决定走 flow 还是原单 Text 路径）；先用反引号做 O(n) 快速排除。
    static func containsInlineCode(_ source: String) -> Bool {
        guard source.contains("`") else { return false }
        return tokenize(source).contains { $0.kind == .code }
    }

 /// 纯文本投影（复制文本用）：token 文本直接拼接（inline 标记已被解析掉）。
    static func plainText(_ source: String) -> String {
        tokenize(source).map(\.text).joined()
    }

    static func tokenize(_ source: String) -> [MarkdownInlineToken] {
        guard !source.isEmpty else { return [] }
        let attributed = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        var tokens: [MarkdownInlineToken] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                tokens.append(MarkdownInlineToken(kind: .code, text: text))
                continue
            }
            var node = MarkdownInlineToken(kind: .text, text: "")
            node.bold = intent.contains(.stronglyEmphasized)
            node.italic = intent.contains(.emphasized)
            node.strikethrough = intent.contains(.strikethrough)
            node.link = run.link
            tokens.append(contentsOf: split(text, style: node))
        }
        return tokens
    }

 // MARK: 断行切分

    private enum CharClass { case whitespace, cjk, other }

    private static func split(_ text: String, style: MarkdownInlineToken) -> [MarkdownInlineToken] {
        var tokens: [MarkdownInlineToken] = []
        var buffer = ""
        var bufferClass: CharClass?

        func flush() {
            guard !buffer.isEmpty else { return }
            var token = style
            token.kind = bufferClass == .whitespace ? .whitespace : .text
            token.text = buffer
            tokens.append(token)
            buffer = ""
            bufferClass = nil
        }

        for character in text {
            let charClass: CharClass
            if character.isWhitespace {
                charClass = .whitespace
            } else if isCJK(character) {
                charClass = .cjk
            } else {
                charClass = .other
            }
            if charClass == .cjk {
 // CJK 逐字可断行（中日韩没有词间空格）；收尾标点标记行首禁则。
                flush()
                var token = style
                token.text = String(character)
                token.noBreakBefore = isClosingPunctuation(character)
                tokens.append(token)
                continue
            }
            if let current = bufferClass, current != charClass {
                flush()
            }
            buffer.append(character)
            bufferClass = charClass
        }
        flush()
        return tokens
    }

 /// CJK 收尾标点：不允许出现在行首（行尾禁则），排版规则与桌面浏览器一致。
    private static func isClosingPunctuation(_ character: Character) -> Bool {
        "。，、；：！？）］｝」』】〕〉》…‥～".contains(character)
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x2EFF, 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}

/// tokenization 缓存（token 与字号/变体无关，只按原文缓存；flow 只用于含代码的段落）。
final class MarkdownInlineTokenCache {
    static let shared = MarkdownInlineTokenCache()

    private final class Box {
        let tokens: [MarkdownInlineToken]
        init(_ tokens: [MarkdownInlineToken]) { self.tokens = tokens }
    }

    private let cache = NSCache<NSString, Box>()

    init(countLimit: Int = 600) {
        cache.countLimit = countLimit
    }

    func tokens(for text: String) -> [MarkdownInlineToken] {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.tokens }
        let tokens = MarkdownInlineTokenizer.tokenize(text)
        cache.setObject(Box(tokens), forKey: key)
        return tokens
    }

    func removeAll() { cache.removeAllObjects() }
}

/// token 种类下发给自定义 Layout（空白 token 换行到行首时要折叠）。
private struct MarkdownInlineTokenKindKey: LayoutValueKey {
    static let defaultValue: MarkdownInlineToken.Kind = .text
}

/// 行首禁则下发给自定义 Layout（CJK 收尾标点不许换到行首）。
private struct MarkdownInlineNoBreakBeforeKey: LayoutValueKey {
    static let defaultValue = false
}

/// 行内流式布局：token 从左到右排，超出宽度换行；行内按 firstTextBaseline 对齐，
/// 行距沿用 Markdown variant 的 lineSpacing，整体 leading 对齐。
fileprivate struct MarkdownInlineFlowPlacedToken {
    var index: Int
    var x: CGFloat
    var size: CGSize
    var baseline: CGFloat
}

fileprivate struct MarkdownInlineFlowLine {
    var tokens: [MarkdownInlineFlowPlacedToken]
    var width: CGFloat
    var height: CGFloat
}

/// 行内流式布局结果缓存（P0 滚动长帧修复）。
///
/// 自定义 Layout 的 sizeThatFits + placeSubviews 每次都会对每个 token 调
/// Text.sizeThatFits/dimensions；长消息（几十~上百个行内代码 chip）在滚动时
/// 每个布局 pass 都重测一遍，真机实测长帧全部落在超长文本行物化/布局上。
/// 这里按 (缓存签名, 布局宽度) 缓存**整段行结构**（含每 token 的尺寸/坐标/基线），
/// 后续布局 pass 直接命中，不再测量子视图。
fileprivate enum MarkdownInlineFlowLayoutCache {
    private static let lock = NSLock()
    private static var storage: [String: [MarkdownInlineFlowLine]] = [:]
    private static let limit = 256

    static func lines(for key: String) -> [MarkdownInlineFlowLine]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    static func store(_ lines: [MarkdownInlineFlowLine], for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = lines
    }
}

struct MarkdownInlineFlowLayout: Layout {
    var lineSpacing: CGFloat
 /// 布局缓存签名（文本 + 字体/字号/动态字号/变体由调用方拼好）。
    var cacheKey: String = ""

    private typealias PlacedToken = MarkdownInlineFlowPlacedToken
    private typealias Line = MarkdownInlineFlowLine

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let width = proposal.width ?? (lines.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        let lines = lines(subviews: subviews, maxWidth: maxWidth)
        var y = bounds.minY
        for line in lines {
            let baseline = line.tokens.map(\.baseline).max() ?? 0
            for token in line.tokens {
                let dy = baseline - token.baseline
                subviews[token.index].place(
                    at: CGPoint(x: bounds.minX + token.x, y: y + dy),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(token.size)
                )
            }
            y += line.height + lineSpacing
        }
    }


 /// 缓存命中校验：行结构里的 token 下标必须仍落在当前 subviews 范围内。
 /// （缓存键含文本指纹，但哈希碰撞/token 结构变化时宁可重算也不能越界崩溃。）
    private static func cacheIsValid(_ lines: [Line], subviewCount: Int) -> Bool {
        for line in lines {
            for token in line.tokens where token.index < 0 || token.index >= subviewCount {
                return false
            }
        }
        return true
    }

    private func lines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
 // 宽度可能是.infinity（SwiftUI 在 unspecified proposal 下会这样问）：
 // 直接 Int(.infinity) 会 fatalError（真机 EXC_BREAKPOINT，
 // MarkdownInlineFlowLayout.lines）。无限宽度不缓存，宽度键用 "inf" 占位。
        let widthKey = maxWidth.isFinite ? String(Int(maxWidth.rounded())) : "inf"
        let cacheKey = "\(self.cacheKey)|w\(widthKey)"
        if maxWidth.isFinite, !self.cacheKey.isEmpty,
           let cached = MarkdownInlineFlowLayoutCache.lines(for: cacheKey),
           Self.cacheIsValid(cached, subviewCount: subviews.count) {
            return cached
        }
        var lines: [Line] = []
        var current = Line(tokens: [], width: 0, height: 0)
        var x: CGFloat = 0
        var maxBaseline: CGFloat = 0
        var maxDescent: CGFloat = 0
        var hasContent = false

        func finishLine() {
            guard hasContent else { return }
            current.width = x
            current.height = maxBaseline + maxDescent
            lines.append(current)
            current = Line(tokens: [], width: 0, height: 0)
            x = 0
            maxBaseline = 0
            maxDescent = 0
            hasContent = false
        }

        for index in subviews.indices {
            let kind = subviews[index][MarkdownInlineTokenKindKey.self]
            let noBreakBefore = subviews[index][MarkdownInlineNoBreakBeforeKey.self]
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let dimensions = subviews[index].dimensions(in: .unspecified)
            let baseline = dimensions[VerticalAlignment.firstTextBaseline]

            if kind == .whitespace && !hasContent {
 // 行首空白折叠：不占宽，放到行首（空格本身不可见）。
                current.tokens.append(PlacedToken(index: index, x: 0, size: .zero, baseline: 0))
                continue
            }

 // 超宽 token（长 chip / 超长单词）：独占一行，允许内部换行。
            if maxWidth.isFinite, maxWidth > 0, ideal.width > maxWidth {
                finishLine()
                let wrapped = subviews[index].sizeThatFits(
                    ProposedViewSize(width: maxWidth, height: nil)
                )
                current.tokens.append(PlacedToken(
                    index: index,
                    x: 0,
                    size: CGSize(width: maxWidth, height: wrapped.height),
                    baseline: baseline
                ))
                x = maxWidth
                maxBaseline = baseline
                maxDescent = wrapped.height - baseline
                hasContent = true
                finishLine()
                continue
            }

 // 行首禁则：CJK 收尾标点（。、；」等）即使放不下也不换行（允许小幅溢出），
 // 与桌面端浏览器的 line-break 规则一致。
            if hasContent && x + ideal.width > maxWidth && !noBreakBefore {
                finishLine()
                if kind == .whitespace {
                    current.tokens.append(PlacedToken(index: index, x: 0, size: .zero, baseline: 0))
                    continue
                }
            }
            current.tokens.append(PlacedToken(index: index, x: x, size: ideal, baseline: baseline))
            x += ideal.width
            maxBaseline = max(maxBaseline, baseline)
            maxDescent = max(maxDescent, ideal.height - baseline)
            hasContent = true
        }
        finishLine()
        if !self.cacheKey.isEmpty {
            MarkdownInlineFlowLayoutCache.store(lines, for: cacheKey)
        }
        return lines
    }
}

/// 行内代码 chip 视图：桌面端 1:1（bg #292929 / 0.5px 描边 / 8 圆角 / 左右 5pt / 12pt mono）。
struct MarkdownInlineCodeChip: View {
    var text: String
    var fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.Palette.inlineCodeText)
            .fixedSize(horizontal: false, vertical: true)
 // 桌面端行高 19px（--dsw-font-markdown-code = 12px/19px）：单行 chip 用
 // 最小内容行高对齐桌面可视高度；超宽 chip 内部换行时按实际多行高度长高。
            .frame(minHeight: Theme.MarkdownInlineChip.contentMinHeight)
            .padding(.horizontal, Theme.MarkdownInlineChip.horizontalPadding)
            .background(
 // CSS border-radius 是正圆角；.continuous（Apple squircle）在同数值下
 // 视觉更圆，真机对照会显得比桌面端更圆，故用.circular。
                RoundedRectangle(cornerRadius: Theme.Radius.inlineCode, style: .circular)
                    .fill(Theme.Palette.inlineCodeBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.inlineCode, style: .circular)
                    .strokeBorder(
                        Theme.Palette.inlineCodeBorder,
                        lineWidth: Theme.MarkdownInlineChip.borderWidth
                    )
            )
    }
}

/// 行内流式文本视图：文本 token + 代码 chip token 混排。
struct MarkdownInlineFlowView: View {
    var tokens: [MarkdownInlineToken]
    var color: Color
    var font: Font
    var codeFontSize: CGFloat
    var lineSpacing: CGFloat
 /// 布局缓存签名：文本 + 字体/字号/动态字号（尺寸相关；颜色不影响布局）。
    var layoutCacheKey: String = ""

    var body: some View {
        MarkdownInlineFlowLayout(lineSpacing: lineSpacing, cacheKey: layoutCacheKey) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
                    .layoutValue(key: MarkdownInlineTokenKindKey.self, value: token.kind)
                    .layoutValue(key: MarkdownInlineNoBreakBeforeKey.self, value: token.noBreakBefore)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
 // 自定义 Layout 的 token 是并列 Text；合并成一个无障碍元素，读屏按整段朗读。
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func tokenView(_ token: MarkdownInlineToken) -> some View {
        switch token.kind {
        case .code:
            MarkdownInlineCodeChip(text: token.text, fontSize: codeFontSize)
        case .whitespace:
            Text(token.text).font(font)
        case .text:
            let boldFont = token.bold ? font.bold() : font
            let styledFont = token.italic ? boldFont.italic() : boldFont
            Text(token.text)
                .font(styledFont)
                .foregroundStyle(token.link == nil ? color : Theme.Palette.accent)
                .strikethrough(token.strikethrough)
                .underline(token.link != nil)
        }
    }
}

/// Renders one inline-markdown string as a selectable, wrapping text.
///
/// v7 task-7：含行内代码的文本走 `MarkdownInlineFlowView`（自定义 Layout 才能画真圆角
/// chip / 0.5px 描边 / 左右 5pt padding）；自定义布局无法用 `.textSelection`，改用
/// `.contextMenu` 提供「复制文本」。不含行内代码的文本继续走原单 Text 路径（保选择+性能）。
struct MarkdownInlineText: View {
    var text: String
    var color: Color
 /// 显式字号（标题/表格这种自带字号的位置传值）；nil = 按渲染变体取正文档字号。
    var font: Font? = nil
    var codeFontSize: CGFloat? = nil
    var lineSpacing: CGFloat? = nil

    @Environment(\.markdownRenderVariant) private var variant
 /// 动态字号参与布局缓存签名（字号变化后行宽/换行会变）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let resolvedFont = font ?? MarkdownTypography.bodyFont(variant)
        let resolvedCodeFontSize = codeFontSize ?? MarkdownTypography.inlineCodeFontSize(variant)
        let resolvedLineSpacing = lineSpacing ?? MarkdownTypography.lineSpacing(variant)
        if MarkdownInlineTokenizer.containsInlineCode(text) {
            MarkdownInlineFlowView(
                tokens: MarkdownInlineTokenCache.shared.tokens(for: text),
                color: color,
                font: resolvedFont,
                codeFontSize: resolvedCodeFontSize,
                lineSpacing: resolvedLineSpacing,
 // 布局缓存签名：只含影响尺寸的输入（文本内容 + 字体标识 + 字号 +
 // 行距 + 渲染变体 + 动态字号）；颜色/主题不影响换行与尺寸。
                layoutCacheKey: "\(text.hashValue)|\(String(describing: resolvedFont))"
                    + "|\(resolvedCodeFontSize)|\(resolvedLineSpacing)|\(variant)|\(dynamicTypeSize)"
            )
            .contextMenu {
                Button(L10n.t("复制文本")) {
                    UIPasteboard.general.string = MarkdownInlineTokenizer.plainText(text)
                }
            }
        } else {
            Text(MarkdownInline.attributed(text, codeFontSize: resolvedCodeFontSize))
                .font(resolvedFont)
                .foregroundStyle(color)
                .lineSpacing(resolvedLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Document view

/// Block-level Markdown renderer behind `MarkdownText`.
///
/// Parsing is cached by source text (`MarkdownDocumentCache`); texts above
/// `MarkdownRenderPolicy.maxParseBytes` fall back to a single plain text block.

/// 超长 Markdown 行的**分帧渲染**。
///
/// 依据：真机 fast fling 下的 50–100ms 长帧全部伴随「超长消息行（用户/助手长文本）
/// 首次物化」（rowAppear marks: 4960-text-1 / 4967-user 等，行内 block 30–80 个）。
/// 一帧内布局几十个 Text 是主要成本；把 block 分批送进布局可把单帧成本压到阈值内，
/// 视觉上内容在 ~2–4 帧内补齐（不删内容、不改样式）。
///
/// 默认开启（用户口径：滚动丝滑优先；渲染分批不改交互、不删内容）。
/// env DSHM_MD_PROGRESSIVE=0 关闭（before/after 取证用）。
enum MarkdownProgressivePolicy {
 /// 默认**关闭**。
 ///
 /// 曾经默认开启过：场景 I（App 内 2600pt/s 连续滚动）数据显示，分帧追加会让
 /// 长消息行在连续多帧里反复重排——89 个 >50ms 长帧里 76 个落在
 /// mdAppendBlocks 后 100ms 内（append 窗口帧 p95=65ms），比「一次性布局」
 /// 明显的多帧抖动更差。故回退默认关闭；待「追加不触发已渲染 block 重排」
 /// （EquatableView/布局缓存）验证后再开启。
 /// DSHM_MD_PROGRESSIVE=1 开启（实验/取证用）。
    static let isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_MD_PROGRESSIVE"] == "1"
        #else
        return false
        #endif
    }()
 /// 超过该 block 数的长文档才分帧（普通短消息零行为变化）。
 /// 真机 autoscroll 数据：长帧行的 block 数集中在 10–19（chars 1000–1800），
 /// 阈值压到 8 才能覆盖这些行。
    static let blockThreshold: Int = 8
 /// 首帧同步渲染的 block 数（6：首帧 Text 布局成本 ≈ 原来的一半以下）。
    static let initialBlocks: Int = 6
 /// 之后每个 runloop 追加的 block 数（6：每帧增量有界）。
    static let chunkBlocks: Int = 6
}

struct MarkdownDocumentView: View {
    var text: String
    var color: Color = Theme.Palette.textPrimary
 /// 渲染密度。会话正文保持默认 `.body`；思考块传 `.compact`（用户问题 6）。
    var variant: MarkdownRenderVariant = .body

 /// 分帧渲染时已追加的 block 数（0 = 只有首屏 initialBlocks）。
    @State private var appendedBlocks: Int = 0

    var body: some View {
        Group {
            if MarkdownRenderPolicy.shouldParse(text) {
                blocksView
            } else {
                plainTextView
            }
        }
        .environment(\.markdownRenderVariant, variant)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var blocksView: some View {
        let blocks = MarkdownDocumentCache.shared.blocks(for: text)
        if MarkdownRenderPolicy.shouldFlatten(text: text, blockCount: blocks.count) {
 // 方案①：超长消息 → 预构建 AttributedString + 单 Text（首现只剩一次
 // 原生 Text 布局；行高预测量走同一条 sizeThatFits 自动受益）。
            flattenedTextView(blocks: blocks)
        } else {
            blockListView(blocks: blocks)
        }
    }

 /// 单视图富文本（方案①）：整条消息一个 Text；选择/长按复制/链接点击全保留。
 /// 含代码块时按代码块切段（prose 仍单 Text，代码段用换行版代码视图 + 复制），
 /// 这样长消息的每个代码块也有一键复制入口（v7）。
    @ViewBuilder
    private func flattenedTextView(blocks: [MarkdownBlock]) -> some View {
        let blockCount = blocks.count
 // code review P2: decide from the parsed blocks, not from a
 // freshly-built segment array — code-free long messages keep the single
 // attributed-string path with no extra construction/cache entry.
        let hasCode = blocks.contains { block in
            if case .codeBlock = block { return true }
            return false
        }
        Group {
            if hasCode && MarkdownRenderPolicy.isFlattenSegmentsEnabled {
                let segments = MarkdownFlattenCache.shared.segments(for: text, variant: variant)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let attributed):
                            Text(attributed)
                                .foregroundStyle(color)
                                .lineSpacing(MarkdownTypography.lineSpacing(variant))
                                .monospacedDigit()
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .code(let language, let code):
                            MarkdownCodeBlockView(language: language, code: code, wrap: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .onAppear {
                    #if DEBUG
                    ScrollHitchProbe.mark("mdAppearFlatSeg", ["chars": text.count, "blocks": blockCount])
                    #endif
                }
            } else {
                Text(MarkdownFlattenCache.shared.attributedString(for: text, variant: variant))
                    .foregroundStyle(color)
                    .lineSpacing(MarkdownTypography.lineSpacing(variant))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        #if DEBUG
                        ScrollHitchProbe.mark("mdAppearFlat", ["chars": text.count, "blocks": blockCount])
                        #endif
                    }
            }
        }
    }

    private func blockListView(blocks: [MarkdownBlock]) -> some View {
        let visibleCount = visibleBlockCount(total: blocks.count)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(blocks.prefix(visibleCount).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onAppear {
 // 帧探针：长 Markdown 行物化瞬间（char/block 规模）——滚动长帧归因用。
            #if DEBUG
            ScrollHitchProbe.mark("mdAppear", ["chars": text.count, "blocks": blocks.count])
            #endif
            scheduleProgressiveBlocks(total: blocks.count)
        }
        .onChange(of: text) { _, _ in
 // 内容变化（流式/重建）后从头再来一次分帧，避免状态错位。
            appendedBlocks = 0
            scheduleProgressiveBlocks(total: blocks.count)
        }
    }

 /// 当前应渲染的 block 数：普通文档全量；超长文档按分帧策略逐步补齐。
    private func visibleBlockCount(total: Int) -> Int {
        guard MarkdownProgressivePolicy.isEnabled,
              total > MarkdownProgressivePolicy.blockThreshold else {
            return total
        }
        return min(total, MarkdownProgressivePolicy.initialBlocks + appendedBlocks)
    }

 /// 每个 runloop 追加一批 block（单帧布局成本有界），直到补齐。
    private func scheduleProgressiveBlocks(total: Int) {
        guard MarkdownProgressivePolicy.isEnabled,
              total > MarkdownProgressivePolicy.blockThreshold else { return }
        let current = min(total, MarkdownProgressivePolicy.initialBlocks + appendedBlocks)
        guard current < total else { return }
        DispatchQueue.main.async {
            let newCount = min(
                total,
                MarkdownProgressivePolicy.initialBlocks + appendedBlocks
                    + MarkdownProgressivePolicy.chunkBlocks
            )
            let added = newCount - min(total, MarkdownProgressivePolicy.initialBlocks + appendedBlocks)
            guard added > 0 else { return }
            appendedBlocks += added
            #if DEBUG
            ScrollHitchProbe.mark("mdAppendBlocks", ["added": added, "total": total])
            #endif
            scheduleProgressiveBlocks(total: total)
        }
    }

    private var plainTextView: some View {
        Text(text)
            .font(MarkdownTypography.bodyFont(variant))
            .foregroundStyle(color)
            .lineSpacing(MarkdownTypography.lineSpacing(variant))
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

    @Environment(\.markdownRenderVariant) private var variant

    var body: some View {
        MarkdownInlineText(
            text: text,
            color: color,
            font: MarkdownTypography.heading(level: level, variant: variant),
            codeFontSize: max(11, MarkdownTypography.headingSize(level: level, variant: variant) - 2),
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

    @Environment(\.markdownRenderVariant) private var variant

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let task = item.task {
                Image(systemName: task == .checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(task == .checked ? Theme.Palette.accent : Theme.Palette.textTertiary)
            } else {
                Text(marker)
                    .font(MarkdownTypography.bodyFont(variant))
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

/// Fenced code block: 桌面端 parity（v7 task-6，app.asar 解包核对）。
///
/// 桌面端样式：容器 bg = --dsw-alias-markdown-code-block（dark #1b1b1c）、
/// radius = --dsw-radius-lg（16px）；顶部信息栏 bg =
/// --dsw-alias-markdown-code-block-banner（dark #2c2c2e）、padding 9px 14px、
/// infostring 用 11px mono + label-primary；内容 padding 16px、11px mono。
///
/// v7 复制：头栏常显（无语言显示「代码」），右侧复制按钮；
/// 点击复制纯代码，对勾 +「已复制」1 秒后恢复（桌面端同款反馈）。
/// `wrap: true` 供 flatten 长消息切段使用——保持换行、无横向滚动，
/// 与 flatten 既有的「代码块换行」视觉一致。
struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    var wrap: Bool = false

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var languageLabel: String {
        if let language, !language.isEmpty { return language }
        return L10n.t("代码")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(Theme.Palette.codeBlockBackground)
 // 桌面代码块 border-radius 16px 来自 CSS var(--dsw-radius-lg)，正圆角。
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.codeBlock, style: .circular))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(languageLabel)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copyCode) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    if copied {
                        Text(L10n.t("已复制"))
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(copied ? Theme.Palette.waiting : Theme.Palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t(copied ? "已复制" : "复制代码"))
            .accessibilityIdentifier("code-copy")
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.codeBlockBanner)
    }

    @ViewBuilder
    private var content: some View {
        if wrap {
            Text(code.isEmpty ? " " : code)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.m)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        resetTask?.cancel()
        withAnimation(Theme.Motion.quick) { copied = true }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.quick) { copied = false }
        }
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

    @Environment(\.markdownRenderVariant) private var variant

    var body: some View {
        let widths = MarkdownTableMetrics.columnWidths(for: table)
        let spacing = Theme.Spacing.s
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(
                    table.header,
                    widths: widths,
                    spacing: spacing,
                    font: MarkdownTypography.tableHeaderFont(variant),
                    textColor: color
                )
                .padding(.vertical, Theme.Spacing.xs)
                Rectangle()
                    .fill(Theme.Palette.border)
                    .frame(width: totalWidth, height: 1)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    row(
                        cells,
                        widths: widths,
                        spacing: spacing,
                        font: MarkdownTypography.tableBodyFont(variant),
                        textColor: color
                    )
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
