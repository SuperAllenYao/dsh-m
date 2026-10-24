import SwiftUI

/// 消息流的一行（groups 之后的尾部内容也作为可滚动行参与同一列表）。
enum SessionMessageItem: Equatable {
    case group(FlowRowGroup)
    case fileChanges(TurnFileChanges)
    case liveText(String)
    case streamError(String)
    case actionError(String)

    var id: String {
        switch self {
        case .group(let group): return group.id
        case .fileChanges: return "\u{1F}footer-file-changes"
        case .liveText: return "\u{1F}footer-live-text"
        case .streamError: return "\u{1F}footer-stream-error"
        case .actionError: return "\u{1F}footer-action-error"
        }
    }
}

/// 列表变化签名：只在「真的会影响渲染」时触发 items 变更处理，
/// 避免每帧对流式内容做 O(rows) 的全量 Equatable 比较（长会话 rows 可达 3000+）。
struct MessageListSignature: Equatable {
    var count: Int
    var firstID: String?
    var lastID: String?
    var liveText: String?
    var running: Bool
    var newestGroupStepCount: Int
 /// 尾部非 group 行（文件变更卡/错误行）的内容指纹：它们在流式过程中会原地更新，
 /// 但 id 不变；不纳入签名会导致卡片状态（如 404 回退文案）不刷新。
    var tailSignature: String
}

/// 纯逻辑：列表更新策略（可单测，不依赖 UI）。
enum MessageListUpdatePolicy {
    static let nearBottomThreshold: CGFloat = 140

 /// 距底部距离 <= 阈值（或内容不足一屏）算「贴底」。
    static func isNearBottom(distanceFromBottom: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        if contentHeight <= viewportHeight + 1 { return true }
        return distanceFromBottom <= nearBottomThreshold
    }

 /// 读历史（不贴底）时：只接收「前置的历史补齐行」，尾部新内容冻结。
 /// 判定条件：已显示行必须是新列表的**严格后缀**（历史补齐只会在前面插入），
 /// 这样尾部追加、中间替换、流式文本变化都不会被误判成补齐。
    static func leadingPrependedItems(displayed: [SessionMessageItem], incoming: [SessionMessageItem]) -> [SessionMessageItem] {
        guard !displayed.isEmpty else { return [] }
        let shownIDs = displayed.map(\.id)
        let incomingIDs = incoming.map(\.id)
        guard incomingIDs.count > shownIDs.count else { return [] }
        guard Array(incomingIDs.suffix(shownIDs.count)) == shownIDs else { return [] }
        return Array(incoming.prefix(incomingIDs.count - shownIDs.count))
    }
}

/// **原生 SwiftUI 消息列表（v0.2.7 方案 B)**
///
/// 用 ScrollView + LazyVStack 取代 inverted UITableView：
/// - 展开/收起完全交回 SwiftUI 布局动画（行视图内部 withAnimation +.clipped()），
/// 不存在「self-sizing 行高与隐式动画错配」这一类跳变；
/// - 置底跟随、读历史冻结尾部、历史补齐保持阅读位置、强制回底等行为在 SwiftUI 层实现；
/// - 行视图与视觉样式完全复用（FlowRowGroupView / FileChangesCard / MarkdownText 等）。
struct SessionMessageListView: View {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
 /// 递增即请求「强制回到底部」（发送消息 / 答完问答时由上层 +1）。
    let scrollToBottomToken: Int
 /// v0.2.7：过程组显示态覆盖（key = FlowRowGroup.id）；默认态由 isRunning + 是否最新组推导。
    var processGroupModes: [String: ProcessGroupMode] = [:]
 /// 运行中固定窗口高度（页面按会话可视高度 1/3 传入）。
    var processGroupWindowHeight: CGFloat = 300
 /// 本轮起点 seq（最后一条用户消息）。只有本轮内的组才可能是「运行中」组。
    var currentTurnStartSeq: Int = Int.min
 /// 点击过程组 header：回调目标态（页面写入覆盖）。
    var onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil
    var onOpenReasoning: ((String) -> Void)? = nil
    let onOpenTool: (ToolCallItem) -> Void
    let onOpenFileChanges: (TurnFileChanges) -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolled: () -> Void
    let onFirstContent: () -> Void
    let onRetry: () -> Void

    private static let space = "session-message-list-space"
    private static let bottomID = "__session_list_bottom__"
    private static let rowVerticalPadding: CGFloat = Theme.Spacing.s / 2

    @State private var displayedItems: [SessionMessageItem]
    @State private var isNearBottom = true
    @State private var didInitialBottom = false
    @State private var metrics = ScrollMetrics()
    @State private var lastScrollToBottomToken: Int = 0
    @State private var userHasScrolled = false

    init(items: [SessionMessageItem],
         sessionId: String,
         attachments: AttachmentStore,
         pendingApprovalCallIds: Set<String>,
         subagentLabels: [String: String],
         isRunning: Bool,
         historyBatchToken: Int,
         scrollToBottomToken: Int,
         processGroupModes: [String: ProcessGroupMode] = [:],
         processGroupWindowHeight: CGFloat = 300,
         currentTurnStartSeq: Int = Int.min,
         onToggleGroupMode: ((String, ProcessGroupMode) -> Void)? = nil,
         onOpenReasoning: ((String) -> Void)? = nil,
         onOpenTool: @escaping (ToolCallItem) -> Void,
         onOpenFileChanges: @escaping (TurnFileChanges) -> Void,
         onNearBottomChange: @escaping (Bool) -> Void,
         onUserScrolled: @escaping () -> Void,
         onFirstContent: @escaping () -> Void,
         onRetry: @escaping () -> Void) {
        self.items = items
        self.sessionId = sessionId
        self.attachments = attachments
        self.pendingApprovalCallIds = pendingApprovalCallIds
        self.subagentLabels = subagentLabels
        self.isRunning = isRunning
        self.historyBatchToken = historyBatchToken
        self.scrollToBottomToken = scrollToBottomToken
        self.processGroupModes = processGroupModes
        self.processGroupWindowHeight = processGroupWindowHeight
        self.currentTurnStartSeq = currentTurnStartSeq
        self.onToggleGroupMode = onToggleGroupMode
        self.onOpenReasoning = onOpenReasoning
        self.onOpenTool = onOpenTool
        self.onOpenFileChanges = onOpenFileChanges
        self.onNearBottomChange = onNearBottomChange
        self.onUserScrolled = onUserScrolled
        self.onFirstContent = onFirstContent
        self.onRetry = onRetry
        _displayedItems = State(initialValue: items)
        _lastScrollToBottomToken = State(initialValue: scrollToBottomToken)
    }

    private var signature: MessageListSignature {
        var newestStepCount = 0
        if case .group(.process(let steps))? = items.last {
            newestStepCount = steps.count
        }
        return MessageListSignature(
            count: items.count,
            firstID: items.first?.id,
            lastID: items.last?.id,
            liveText: liveTextValue,
            running: isRunning,
            newestGroupStepCount: newestStepCount,
            tailSignature: tailSignature
        )
    }

    private var tailSignature: String {
        var parts: [String] = []
        for item in items.reversed() {
            switch item {
            case .group: break
            case .liveText(let text): parts.append("lt:\(text.count)")
            case .streamError(let message): parts.append("se:\(message)")
            case .actionError(let message): parts.append("ae:\(message)")
            case .fileChanges(let changes):
                parts.append("fc:\(changes.source)|\(changes.isLoading)|\(changes.titleFileCount)|\(changes.files.count)|\(changes.added)|\(changes.deleted)")
            }
        }
        return parts.joined(separator: "#")
    }

    private var liveTextValue: String? {
        for item in items.reversed() {
            if case .liveText(let text) = item { return text }
        }
        return nil
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ListOffsetPreferenceKey.self,
                                        value: geo.frame(in: .named(Self.space)).minY
                                    )
                                }
                            )

                        ForEach(displayedItems, id: \.id) { item in
                            rowView(item, isNewest: isNewest(item))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.pageInset)
                                .padding(.vertical, Self.rowVerticalPadding)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: RowFramePreferenceKey.self,
                                            value: [item.id: geo.frame(in: .named(Self.space))]
                                        )
                                    }
                                )
                                .id(item.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ListContentHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.space)
 // 仅首屏用原生底部锚点：保证第一帧就落在最新消息（且 LazyVStack 会物化最后一行）；
 // 首屏完成后立即撤掉，避免行内展开时滚动视图把底部锚住 → 被点行被顶上去。
                .defaultScrollAnchor(didInitialBottom ? nil : .bottom)
                .scrollIndicators(.visible)
                .onPreferenceChange(ListOffsetPreferenceKey.self) { topMinY in
                    metrics.topMinY = topMinY
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(ListContentHeightPreferenceKey.self) { height in
                    metrics.contentHeight = height
                    recomputeNearBottom(proxy: proxy)
                }
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    metrics.rowFrames = frames
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            metrics.interactingUntil = CACurrentMediaTime() + 0.12
                            markUserScrolledIfNeeded()
                        }
                        .onEnded { _ in
 // 松手后还有减速惯性，给一段「用户正在操作」的静默期。
                            metrics.interactingUntil = CACurrentMediaTime() + 0.55
                        }
                )
                .onAppear {
                    metrics.viewportHeight = outer.size.height
                    DispatchQueue.main.async { scheduleInitialBottomFinish() }
                }
                .onChange(of: outer.size.height) { _, height in
                    metrics.viewportHeight = height
                    recomputeNearBottom(proxy: proxy)
                    if isNearBottom { pinBottom(proxy: proxy, animated: false) }
                }
                .onChange(of: signature) { _, _ in
                    applyItemsChange(proxy: proxy)
                }
                .onChange(of: scrollToBottomToken) { _, token in
                    guard token != lastScrollToBottomToken else { return }
                    lastScrollToBottomToken = token
                    displayedItems = items
                    metrics.interactingUntil = 0
                    pinBottom(proxy: proxy, animated: false)
                }
            }
        }
    }

 // MARK: - Row

    @ViewBuilder
    private func rowView(_ item: SessionMessageItem, isNewest: Bool) -> some View {
        switch item {
        case .group(let group):
            let mode = ProcessGroupModeResolver.resolve(
                isRunning: isNewest,
                override: processGroupModes[group.id]
            )
            FlowRowGroupView(
                group: group,
                sessionId: sessionId,
                attachments: attachments,
                pendingApprovalCallIds: pendingApprovalCallIds,
                subagentLabels: subagentLabels,
                isNewestGroupRunning: isNewest,
                mode: mode,
                windowHeight: processGroupWindowHeight,
                onToggleMode: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        onToggleGroupMode?(group.id, ProcessGroupModeResolver.toggled(mode))
                    }
                },
                onOpenReasoning: onOpenReasoning,
                onOpenTool: onOpenTool
            )
            .equatable()
        case .fileChanges(let changes):
            FileChangesCard(changes: changes) { onOpenFileChanges(changes) }
        case .liveText(let text):
            MarkdownText(text: text)
                .padding(Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .accessibilityIdentifier("live-assistant-stream")
        case .streamError(let message):
            InlineErrorView(message: message) { onRetry() }
                .accessibilityIdentifier("session-stream-error")
        case .actionError(let message):
            InlineErrorView(message: message)
        }
    }

    private func isNewest(_ item: SessionMessageItem) -> Bool {
        guard case .group(let group) = item else { return false }
        guard isRunning else { return false }
        guard case .process = group else { return false }
        guard case .group(let last)? = items.last else { return false }
        return last.id == group.id
    }

 // MARK: - Behavior

    private func recomputeNearBottom(proxy: ScrollViewProxy) {
        guard metrics.viewportHeight > 1, metrics.contentHeight > 1 else { return }
        let offset = max(0, -metrics.topMinY)
        let distance = metrics.contentHeight - offset - metrics.viewportHeight
        let near = MessageListUpdatePolicy.isNearBottom(
            distanceFromBottom: distance,
            contentHeight: metrics.contentHeight,
            viewportHeight: metrics.viewportHeight
        )
        guard near != isNearBottom else { return }
        isNearBottom = near
        onNearBottomChange(near)
        if near {
 // 回到贴底：把读历史期间冻结的尾部内容一次性应用，并贴底。
            displayedItems = items
            DispatchQueue.main.async { followBottomIfNotInteracting(proxy: proxy) }
        }
    }

    private func markUserScrolledIfNeeded() {
        guard !userHasScrolled else { return }
        userHasScrolled = true
        onUserScrolled()
    }

 /// 首屏结束：等底部锚点把最后一屏布局出来后再撤销锚点（两拍足够覆盖首次布局）。
    private func scheduleInitialBottomFinish() {
        guard !didInitialBottom else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !self.didInitialBottom else { return }
            self.markInitialBottomIfNeeded()
        }
    }

    private func markInitialBottomIfNeeded() {
        guard !didInitialBottom else { return }
        didInitialBottom = true
        onFirstContent()
    }

    private func pinBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !displayedItems.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func applyItemsChange(proxy: ScrollViewProxy) {
        let newItems = items
        guard !newItems.isEmpty else { return }
        if !didInitialBottom {
            displayedItems = newItems
            DispatchQueue.main.async { scheduleInitialBottomFinish() }
            return
        }
        if isNearBottom {
            displayedItems = newItems
 // 必须等这一帧布局完成后再滚：LazyVStack 的底部锚点尚未物化时 scrollTo 会静默失败。
            DispatchQueue.main.async { followBottomIfNotInteracting(proxy: proxy) }
            return
        }
 // 读历史：只接收前置的历史补齐行，保持阅读位置（用可见行做锚点）。
        let prepended = MessageListUpdatePolicy.leadingPrependedItems(displayed: displayedItems, incoming: newItems)
        guard !prepended.isEmpty else { return }
        let anchorID = visibleAnchorID()
        displayedItems = prepended + displayedItems
        if let anchorID {
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }

    private func followBottomIfNotInteracting(proxy: ScrollViewProxy) {
        guard isNearBottom else { return }
        let now = CACurrentMediaTime()
        if now < metrics.interactingUntil {
            let delay = max(0.05, metrics.interactingUntil - now + 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [proxy] in
                guard self.isNearBottom else { return }
                self.pinBottom(proxy: proxy, animated: false)
            }
            return
        }
        pinBottom(proxy: proxy, animated: false)
    }

    private func visibleAnchorID() -> String? {
        let viewport = metrics.viewportHeight
        var straddling: (String, CGFloat)?
        var firstBelow: (String, CGFloat)?
        for (id, frame) in metrics.rowFrames where frame.maxY > 0 && frame.minY < viewport {
            if frame.minY <= 0.5 {
                if straddling == nil || frame.minY > straddling!.1 { straddling = (id, frame.minY) }
            } else if firstBelow == nil || frame.minY < firstBelow!.1 {
                firstBelow = (id, frame.minY)
            }
        }
        return straddling?.0 ?? firstBelow?.0
    }
}

/// 滚动几何（引用类型，避免每帧滚动都触发 SwiftUI body 重算）。
private final class ScrollMetrics {
    var topMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var rowFrames: [String: CGRect] = [:]
    var interactingUntil: CFTimeInterval = 0
}

private struct ListOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ListContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
