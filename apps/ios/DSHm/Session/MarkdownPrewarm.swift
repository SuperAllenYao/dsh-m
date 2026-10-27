import Foundation

/// 文本行 Markdown 的**后台预解析**（P0：滚动长帧修复）。
///
/// 真机证据：fast fling 下剩余的 50–95ms 长帧全部发生在超长 single(text/user) 行
/// 首次物化（rowAppear/mdAppear 紧邻 hitch）；其中 Markdown 的 block 解析与
/// inline token（行内代码 chip）分词是主线程首次开销。
///
/// 这里在「显示窗口 / items 变化」时把即将进入视口的文本行丢给后台预解析：
/// - 只做纯 CPU 解析（MarkdownParser / MarkdownInlineTokenizer 都是纯函数）；
/// - 结果写入 NSCache（线程安全），主线程首次渲染直接命中缓存，只做布局/绘制；
/// - utility 优先级 + 去重 + 字符预算，绝不影响主线程滚动。
enum MarkdownPrewarm {
    private static let lock = NSLock()
 /// 已预热的文本（FNV-1a 64 位指纹）——避免同一文本反复排队。
    private static var warmed: Set<UInt64> = []
    private static var inFlight = false
    private static let warmedCap = 4000

 /// 预热一批文本（内部去重/预算/单飞；调用方可以在任意线程/任意频率调用）。
    static func prewarm(texts: [String], budgetCharacters: Int = 120_000) {
        guard !texts.isEmpty else { return }
        var selected: [String] = []
        var used = 0
        lock.lock()
        for text in texts {
            guard !text.isEmpty, MarkdownRenderPolicy.shouldParse(text) else { continue }
            let fingerprint = fnv1a(text)
            if warmed.contains(fingerprint) { continue }
            if used + text.count > budgetCharacters { continue }
            warmed.insert(fingerprint)
            selected.append(text)
            used += text.count
        }
        if warmed.count > warmedCap {
            warmed.removeAll(keepingCapacity: true)
        }
        let shouldStart = !inFlight && !selected.isEmpty
        if shouldStart { inFlight = true }
        lock.unlock()
        guard shouldStart else { return }

        Task.detached(priority: .utility) {
            for text in selected {
                let blocks = MarkdownDocumentCache.shared.blocks(for: text)
 // 方案①：超长行后台预 flatten（拼装进 NSCache），首现只剩一次原生
 // Text 布局；走单视图的行不再需要 inline token 预热。
                if MarkdownRenderPolicy.shouldFlatten(text: text, blockCount: blocks.count) {
                    _ = MarkdownFlattenCache.shared.attributedString(for: text, variant: .body)
                    continue
                }
                for inline in blocks.flatMap(\.prewarmInlineTexts) where !inline.isEmpty {
                    guard MarkdownInlineTokenizer.containsInlineCode(inline) else { continue }
                    _ = MarkdownInlineTokenCache.shared.tokens(for: inline)
                }
            }
            lock.lock()
            inFlight = false
            lock.unlock()
        }
    }

 /// 预热一条消息列表里的文本行（仅文本/用户/通知/子代理预览等会走 Markdown 的行）。
    static func prewarm(items: [SessionMessageItem], budgetCharacters: Int = 120_000) {
        var texts: [String] = []
        var used = 0
        for item in items {
            let text: String?
            switch item {
            case .liveText(let value):
                text = value
            case .group(let group):
                guard case .single(let row) = group else { continue }
                switch row.content {
                case .text(let value): text = value
                case .user(let bubble): text = bubble.text
                case .notice(let card): text = card.text
                case .relay(let card): text = card.text
                case .goal(let objective, _): text = objective
                default: text = nil
                }
            default:
                text = nil
            }
            guard let text, !text.isEmpty else { continue }
            if used + text.count > budgetCharacters { break }
            texts.append(text)
            used += text.count
        }
        prewarm(texts: texts, budgetCharacters: budgetCharacters)
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

extension MarkdownBlock {
 /// 该 block 内会被 MarkdownInlineText 渲染的内联文本（预解析 inline token 用）。
    var prewarmInlineTexts: [String] {
        switch self {
        case .heading(_, let text), .paragraph(let text):
            return [text]
        case .list(let list):
            return list.items.map(\.text)
        case .codeBlock:
            return []
        case .quote(let lines):
            return lines
        case .horizontalRule:
            return []
        case .table(let table):
            return [table.header].flatMap { $0 } + table.rows.flatMap { $0 }
        }
    }
}
