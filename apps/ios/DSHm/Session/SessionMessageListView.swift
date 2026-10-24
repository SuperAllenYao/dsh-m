import SwiftUI
import UIKit
#if DEBUG
import QuartzCore
#endif

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

/// cell 内容实际高度（SwiftUI 内部状态变化后上报给 table，用于自撑高重测）。
private struct RowContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 过程组行高取证开关：真机 DEBUG 构建下设 `DSHM_PROCDBG=1` 时，
/// 每次行重测后打印可见过程组的行高与 hosting 内容高度（默认关闭，零开销）。
enum ProcessGroupDebug {
    static let enabled = ProcessInfo.processInfo.environment["DSHM_PROCDBG"] == "1"
}

/// 布局回调型 UITableView：每次布局完成（屏幕提交前）通知协调器做「锚点行位置保持」。
final class AnchoredTableView: UITableView {
    var onLayoutPass: (() -> Void)?
    private var isReentrant = false
    override func layoutSubviews() {
        #if DEBUG
        let probeStart = CACurrentMediaTime()
        #endif
        super.layoutSubviews()
        guard !isReentrant else {
            #if DEBUG
            PerfProbe.shared.record("layoutPass", ms: (CACurrentMediaTime() - probeStart) * 1000, ["reentrant": 1])
            #endif
            return
        }
        isReentrant = true
        onLayoutPass?()
        isReentrant = false
        #if DEBUG
        PerfProbe.shared.record("layoutPass", ms: (CACurrentMediaTime() - probeStart) * 1000, [
            "visible": visibleCells.count,
            "h": Double(bounds.height),
        ])
        #endif
    }
}

/// **UIKit 消息列表底座（反转布局 + 布局期锚定）** —— v0.2.6 滚动稳定性重构，。
///
/// 架构（业界聊天列表的标准做法）：
/// - `UITableView` 整体上下翻转（`scaleY(-1)`），cell 再翻转回来；数据源**新→旧**排列。
/// 于是「向历史方向补数据」= 向数据源**尾部追加**：已有内容的 content 坐标不变，
/// 可见内容与滚动位置**结构性不受影响**（不依赖行高估算、不需要任何 offset 补偿）。
/// - 行视图仍复用 SwiftUI（`UIHostingConfiguration`，iOS 16+），渲染逻辑零改动。
/// - 「用户正在读历史、尚未回到底部」时，新的流式行先不插入（标准聊天语义：新消息在回到底部时出现）：
/// 避免反转布局里向数据头插入造成可见位移；回到近底部时一次性应用。
/// - 用户贴底时新消息直接出现在底部（offset 0 = 视觉底部，无需滚动）。
struct SessionMessageListView: UIViewRepresentable {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
 /// 递增即请求「强制回到底部」（发送消息 / 答完问答时由上层 +1）。
    let scrollToBottomToken: Int
 /// v0.2.7：过程组显示态覆盖（key = `FlowRowGroup.id`）；默认态由 isRunning + 是否最新组推导。
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let tableView = AnchoredTableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.showsVerticalScrollIndicator = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = 160
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.allowsSelection = false
 // 反转：视觉底部 = contentOffset 0。
        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
        context.coordinator.attach(tableView: tableView)
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(items: items, batchToken: historyBatchToken)
    }

    static func dismantleUIView(_ tableView: UITableView, coordinator: Coordinator) {
        coordinator.detach()
    }

 // MARK: - Cell

    final class MessageCell: UITableViewCell {
        static let reuseID = "SessionMessageCell"
        var rowID: String = ""
 /// 用于上报「cell 内容高度」→ 触发自撑高重测（点击展开这类 SwiftUI 内部状态变化
 /// 不会让 UITableView 自动重测行高，内容会一直被旧行高裁剪）。
        weak var coordinator: Coordinator?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            selectionStyle = .none
 // 展开/收起动画期间按 cell 边界裁剪内容，避免行高过渡中内容溢出压到相邻行。
            contentView.clipsToBounds = true
 // 反转回来，让 SwiftUI 内容正立。
            transform = CGAffineTransform(scaleX: 1, y: -1)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ parent: SessionMessageListView, item: SessionMessageItem, isNewest: Bool) {
            #if DEBUG
            let probeStart = CACurrentMediaTime()
            #endif
            rowID = item.id
            contentConfiguration = UIHostingConfiguration {
                Group {
                    switch item {
                    case .group(let group):
                        let mode = ProcessGroupModeResolver.resolve(
                            isRunning: isNewest,
                            override: parent.processGroupModes[group.id]
                        )
                        FlowRowGroupView(
                            group: group,
                            sessionId: parent.sessionId,
                            attachments: parent.attachments,
                            pendingApprovalCallIds: parent.pendingApprovalCallIds,
                            subagentLabels: parent.subagentLabels,
                            isNewestGroupRunning: isNewest,
                            mode: mode,
                            windowHeight: parent.processGroupWindowHeight,
                            onToggleMode: {
                                parent.onToggleGroupMode?(group.id, ProcessGroupModeResolver.toggled(mode))
                            },
                            onOpenReasoning: parent.onOpenReasoning,
                            onOpenTool: parent.onOpenTool
                        )
                    case .fileChanges(let changes):
                        FileChangesCard(changes: changes) { parent.onOpenFileChanges(changes) }
                    case .liveText(let text):
                        MarkdownText(text: text)
                            .padding(Theme.Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                            .accessibilityIdentifier("live-assistant-stream")
                    case .streamError(let message):
                        InlineErrorView(message: message) { parent.onRetry() }
                            .accessibilityIdentifier("session-stream-error")
                    case .actionError(let message):
                        InlineErrorView(message: message)
                    }
                }
                .padding(.horizontal, Theme.Spacing.pageInset)
                .padding(.vertical, Theme.Spacing.s / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: RowContentHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(RowContentHeightKey.self) { [weak self] height in
 // [weak self] 防止 cell↔hosting 循环引用；coordinator 在 cellForRow 里注入。
                    guard let self else { return }
                    self.coordinator?.rowContentHeightChanged(rowID: item.id, contentHeight: height)
                }
 // 只有用户主动点开的展开体（思考块/子代理卡/问题详情）才上报「用户交互」，
 // 供 coordinator 区分「用户点击导致的行高变化」与「布局期/流式内容的高度变化」。
                .environment(\.userToggleReporter, { [weak self] in
                    self?.coordinator?.noteUserToggle(rowID: item.id)
                })
            }
            .margins(.all, 0)
            #if DEBUG
            PerfProbe.shared.record("cellConfig", ms: (CACurrentMediaTime() - probeStart) * 1000)
            #endif
        }
    }

 // MARK: - Coordinator

    final class Coordinator: NSObject, UITableViewDelegate {
        var parent: SessionMessageListView
        weak var tableView: AnchoredTableView?
        private var dataSource: UITableViewDiffableDataSource<String, String>?
        private var lastItems: [SessionMessageItem] = []       // 视觉顺序：旧→新
        private var groupLookup: [String: FlowRowGroup] = [:]
        private var didInitialBottom = false
        private var isNearBottom = true
        private var userHasScrolled = false
 /// 读历史期间被冻结的尾部内容（回到近底部时一次性应用）。
        private var frozenItems: [SessionMessageItem]?
 /// 用户主动展开/收起的行（时间戳）：只有这些行的行高变化才走「入口行固定」锚点会话，
 /// 其余（首屏布局/流式内容/历史补齐）走无锚点重测，避免滚动被吸回旧位置。
        private var pendingUserToggleRowIDs: [String: CFAbsoluteTime] = [:]
        private var userIsScrolling = false
        private var isAdjustingOffset = false
 /// 静止阅读时的冻结锚点（最上方可见行 + 屏幕位置）；每次布局后保持它不动。
        private var desiredAnchor: (rowID: String, screenY: CGFloat)?
 /// 已处理到的「强制回底」请求序号（发送消息 / 答完问答）。
        private var lastScrollToBottomToken: Int = 0
 /// 上一次布局时的视口高度：键盘/内联行/输入框增高会改变它，读历史时需要补偿。
        private var lastViewportHeight: CGFloat = 0
 /// v0.2.7：上一次应用时的过程组显示态覆盖，用于把「点击/阶段切换」转成行重测。
        private var lastGroupModes: [String: ProcessGroupMode] = [:]
 /// 上一次应用时的 running 标记：true→false 时最新组要从窗口态切到折叠态。
        private var lastRunningFlag = false
 /// 展开/收起动画时长（用户指定 150ms，非线性 ease-in-out）。
        private static let modeToggleDuration: TimeInterval = 0.15

        init(_ parent: SessionMessageListView) {
            self.parent = parent
        }

        func attach(tableView: AnchoredTableView) {
            self.tableView = tableView
            tableView.onLayoutPass = { [weak self] in self?.stabilizeAfterLayout() }
            tableView.delegate = self
            tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
            lastScrollToBottomToken = parent.scrollToBottomToken
            lastViewportHeight = tableView.bounds.height
            lastRunningFlag = parent.isRunning
            lastGroupModes = parent.processGroupModes
            let dataSource = UITableViewDiffableDataSource<String, String>(tableView: tableView) { [weak self] tableView, indexPath, itemID in
                guard let self,
                      let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as? MessageCell,
                      let item = self.item(for: itemID) else {
                    return UITableViewCell()
                }
                cell.coordinator = self   // 点击展开后上报内容高度 → 触发自撑高重测
                cell.configure(self.parent, item: item, isNewest: self.isNewest(item))
                #if DEBUG
                ScrollJitterProbe.shared?.register(rowID: itemID, view: cell)
                #endif
                return cell
            }
            self.dataSource = dataSource
            #if DEBUG
            ScrollJitterProbe.shared?.attach(table: tableView)
            installProbeObservers(tableView)
            #endif
        }

        func detach() {
            heightAnimationSession = nil
            animatedRowHeight = nil
            legacyHeightRefreshWork?.cancel()
            legacyHeightRefreshWork = nil
            #if DEBUG
            offsetObservation?.invalidate()
            offsetObservation = nil
            sizeObservation?.invalidate()
            sizeObservation = nil
            if let tableView { ScrollJitterProbe.shared?.detachTable(tableView) }
            ScrollJitterProbe.shared?.stop()
            #endif
        }

        #if DEBUG
        private var offsetObservation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?

 /// 取证：谁在「用户没滚动、代码也没主动调 offset」时改了 contentOffset/contentSize？
 /// KVO 回调同步发生在变更点，callStackSymbols 直接给出调用来源。
        private func installProbeObservers(_ tableView: UITableView) {
            guard ScrollJitterProbe.shared != nil else { return }
            offsetObservation = tableView.observe(\.contentOffset, options: [.old, .new]) { [weak self] table, change in
                guard let self, self.didInitialBottom,
                      !self.userIsScrolling, !self.isAdjustingOffset,
                      !table.isTracking, !table.isDecelerating else { return }
                guard let old = change.oldValue, let new = change.newValue else { return }
                let delta = new.y - old.y
                guard abs(delta) > 1.0 else { return }
                ScrollJitterProbe.shared?.event("offsetKVO", [
                    "delta": Double(delta),
                    "off": Double(new.y),
                    "ch": Double(table.contentSize.height),
                    "stack": Coordinator.compactStack(),
                ])
            }
            sizeObservation = tableView.observe(\.contentSize, options: [.old, .new]) { [weak self] table, change in
                guard let self, self.didInitialBottom,
                      !self.userIsScrolling, !self.isAdjustingOffset,
                      !table.isTracking, !table.isDecelerating else { return }
                guard let old = change.oldValue, let new = change.newValue else { return }
                let delta = new.height - old.height
                guard abs(delta) > 2.0 else { return }
                ScrollJitterProbe.shared?.event("sizeKVO", [
                    "delta": Double(delta),
                    "ch": Double(new.height),
                    "off": Double(table.contentOffset.y),
                    "stack": Coordinator.compactStack(),
                ])
            }
        }

        static func compactStack(_ limit: Int = 18) -> String {
            Thread.callStackSymbols.prefix(limit).compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 4 else { return nil }
                return String(parts[1]) + "!" + String(parts[3])
            }.joined(separator: ";")
        }
        #endif

        private func item(for id: String) -> SessionMessageItem? {
            if let group = groupLookup[id] { return .group(group) }
            return lastItems.first { $0.id == id }
        }

        #if DEBUG
 /// DSHM_PROCDBG=1 取证：行高（UIKit 自撑高结果）vs hosting 内容实际高度。
 /// 二者不一致即为「内容溢出旧行高」的直接证据。
        private func logProcessRowHeights(_ tableView: UITableView, reason: String) {
            guard ProcessGroupDebug.enabled else { return }
            var parts: [String] = []
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let id = dataSource?.itemIdentifier(for: indexPath), id.hasPrefix("process-") else { continue }
                let rowHeight = tableView.rectForRow(at: indexPath).height
                let hosting = tableView.cellForRow(at: indexPath)?.contentView.subviews.first?.bounds.height ?? -1
                parts.append("\(id.suffix(8)) row=\(Int(rowHeight)) hosting=\(Int(hosting))")
            }
            guard !parts.isEmpty else { return }
            print("[procdbg] \(reason) " + parts.joined(separator: " | "))
        }
        #endif

        private func isNewest(_ item: SessionMessageItem) -> Bool {
            guard parent.isRunning else { return false }
            guard case .group(let group) = item else { return false }
 // v0.2.7：必须是**本轮**（最后一条用户消息之后）的最后一个过程组。
 // 只看「最后一个组」会让刚发消息时的上一轮组闪成运行中窗口；
 // 只看「本轮」会让同一轮里更早的组也当成运行中（它们已经结束了）。
            guard group.firstSeq > parent.currentTurnStartSeq else { return false }
            return group.id == parent.items.last(where: { if case .group = $0 { return true }; return false })?.id
        }

 // MARK: - 交互式展开/收起的锚点与方向

 /// 本次 apply 里被点击切换显示态的过程组（同一时刻通常只有一个）；
 /// 若同时有多个，优先取「展开方向」的那个（展开才需要方向/自动上移处理）。
        private static func toggledGroupTarget(
            old: [String: ProcessGroupMode],
            new: [String: ProcessGroupMode],
            newIDs: Set<String>
        ) -> String? {
            let changed = new.keys.filter { newIDs.contains($0) && old[$0] != new[$0] }
            guard !changed.isEmpty else { return nil }
            if let expanding = changed.first(where: { isExpandMode(new[$0]) }) { return expanding }
            return changed.sorted().first
        }

 /// 展开方向：已结束组 expanded / 运行中组 full。
        private static func isExpandMode(_ mode: ProcessGroupMode?) -> Bool {
            mode == .expanded || mode == .full
        }

 // MARK: - 自撑高行重测（SwiftUI 内部展开/收起）

 /// 点击 cell 内的「思考 / 子代理卡片 / 过程组」等展开体后，单元格内容高度变化，
        #if DEBUG
 /// E2E 诊断：把锚点决策写到 App Documents/heighpin.log（模拟器数据目录在宿主磁盘上可直接读）。
        private func pinLog(_ message: String) {
            guard ProcessInfo.processInfo.environment["DSHM_E2E"] == "1" else { return }
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("heighpin.log")
            let line = String(format: "%.3f ", Date().timeIntervalSince1970) + message + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif

 // MARK: - 通用折叠/展开（被点行位置严格固定）

 /// 统一交互（用户 口径）：**被点击的那一行在屏幕上的位置严格不动**，
 /// 展开内容把下方 UI 向下挤开；收起时反向拉回。150ms ease-in-out。
 ///
 /// 实现要点：
 /// - UIHostingConfiguration 的 hosted 内容高度是**瞬间**变化的，而且过程组行改显示态
 /// 时不会触发 hosting 高度上报，所以不能依赖「等内容自己动画/等上报」；
 /// - 点击瞬间先用 tableView(_:heightForRowAt:) 把该行行高**显式钉在旧值**，
 /// 应用新内容态后主动做一次「释放高度 → 重测 → 重新钉住」拿到最终行高，
 /// 再用 60fps 定时器把行高按 150ms ease-in-out 插值到最终值；
 /// - 每一帧同时把被点行视觉顶边钉回 targetTop（contentOffset 同步补偿），
 /// 因此入口行不动、内容被逐帧挤出/收回。
        private struct HeightAnimationSession {
            let rowID: String
 /// 被点行视觉顶边在列表视口内的目标 Y。
            let targetTop: CGFloat
 /// 起始行高（点击时）。
            let startHeight: CGFloat
 /// 目标行高（主动测量得到）。
            var targetHeight: CGFloat
 /// 动画开始时间（CACurrentMediaTime）。
            let startTime: CFTimeInterval
        }
        private var heightAnimationSession: HeightAnimationSession?
 /// 等待测量/动画的挂起任务（点击后稍后再测量最终行高）。
        private struct PendingHeightChange {
            let rowID: String
            let targetTop: CGFloat
            let startHeight: CGFloat
        }
        private var pendingHeightChange: PendingHeightChange?
 /// 动画期间该行的显式高度（tableView(_:heightForRowAt:) 返回它）。
        private var animatedRowHeight: (rowID: String, height: CGFloat)?
 /// 主动画时长（用户口径：150ms，非线性 ease-in-out）。
        private static let heightAnimationDuration: TimeInterval = 0.15
 /// 点击后等 SwiftUI 应用新内容态再测最终行高的延迟。
        private static let heightMeasureDelay: TimeInterval = 0.05
 /// 非用户交互的行高变化（首屏/流式/历史补齐）的无锚点重测防抖任务。
        private var legacyHeightRefreshWork: DispatchWorkItem?
        private var heightMeasureWork: DispatchWorkItem?

 /// 行视觉顶边（反转列表里 cell 的视觉顶边 = rect.maxY 端）。
        private func visualTop(ofRow rowID: String, tableView: UITableView) -> CGFloat? {
            guard let dataSource, let indexPath = dataSource.indexPath(for: rowID) else { return nil }
            let rect = tableView.rectForRow(at: indexPath)
            return tableView.bounds.height - (rect.maxY - tableView.contentOffset.y)
        }

 /// 把某行的视觉顶边钉回目标屏幕位置（反算 contentOffset）。
        private func pinRowTop(_ rowID: String, targetTop: CGFloat, tableView: UITableView) {
            guard let dataSource, let indexPath = dataSource.indexPath(for: rowID) else { return }
            let rect = tableView.rectForRow(at: indexPath)
            let currentTop = tableView.bounds.height - (rect.maxY - tableView.contentOffset.y)
            let delta = targetTop - currentTop
            guard abs(delta) > 0.5 else { return }
            var offset = tableView.contentOffset
            offset.y += delta
            let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            offset.y = min(max(offset.y, 0), maxY)
            tableView.setContentOffset(offset, animated: false)
        }

 /// 动画期间返回被点行的显式高度，其余行保持自撑高。
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            if let animated = animatedRowHeight,
               let id = dataSource?.itemIdentifier(for: indexPath), id == animated.rowID {
                return max(1, animated.height)
            }
            return UITableView.automaticDimension
        }

 /// 用一次 begin/endUpdates 让显式行高生效。
        private func applyExplicitRowHeight(_ tableView: UITableView) {
            isAdjustingOffset = true
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            tableView.layoutIfNeeded()
            isAdjustingOffset = false
        }

 /// 登记一次「行高变化」动画：先钉住旧行高，稍后测量最终行高再逐帧动画。
        func beginPendingHeightAnimation(rowID: String, targetTop: CGFloat, startHeight: CGFloat) {
            guard pendingHeightChange == nil, heightAnimationSession == nil,
                  animatedRowHeight == nil, startHeight > 1 else { return }
            #if DEBUG
            pinLog("userTap row=\(rowID) top=\(String(format: "%.1f", targetTop)) h=\(String(format: "%.1f", startHeight))")
            #endif
            pendingHeightChange = PendingHeightChange(rowID: rowID, targetTop: targetTop, startHeight: startHeight)
            animatedRowHeight = (rowID, startHeight)
            if let tableView { applyExplicitRowHeight(tableView) }
            heightMeasureWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.measureAndAnimateHeight() }
            heightMeasureWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.heightMeasureDelay, execute: work)
        }

 /// 测量最终行高并从旧值动画到新值。
        private func measureAndAnimateHeight() {
            guard let tableView, let pending = pendingHeightChange else { return }
            pendingHeightChange = nil
 // 1) 释放显式高度，让表格按新内容重测，读出最终行高。
            animatedRowHeight = nil
            applyExplicitRowHeight(tableView)
            guard let indexPath = dataSource?.indexPath(for: pending.rowID) else { return }
            let finalHeight = tableView.rectForRow(at: indexPath).height
            let delta = finalHeight - pending.startHeight
            guard abs(delta) > 1 else {
 // 高度没变：无需动画，钉一次位置即可。
                if let top = visualTop(ofRow: pending.rowID, tableView: tableView) {
                    pinRowTop(pending.rowID, targetTop: pending.targetTop, tableView: tableView)
                    _ = top
                }
                return
            }
 // 2) 重新钉回旧行高，并把视觉顶边钉回点击时的位置。
            animatedRowHeight = (pending.rowID, pending.startHeight)
            applyExplicitRowHeight(tableView)
            pinRowTop(pending.rowID, targetTop: pending.targetTop, tableView: tableView)
            #if DEBUG
            pinLog("measure row=\(pending.rowID) from=\(String(format: "%.1f", pending.startHeight)) to=\(String(format: "%.1f", finalHeight))")
            #endif
 // 3) 逐帧插值动画。
            heightAnimationSession = HeightAnimationSession(
                rowID: pending.rowID,
                targetTop: pending.targetTop,
                startHeight: pending.startHeight,
                targetHeight: finalHeight,
                startTime: CACurrentMediaTime()
            )
            tickHeightAnimation()
        }

        private func tickHeightAnimation() {
            guard let tableView, let session = heightAnimationSession else { return }
            guard !tableView.isTracking, !tableView.isDecelerating else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in self?.tickHeightAnimation() }
                return
            }
            let elapsed = CACurrentMediaTime() - session.startTime
            let t = min(1, max(0, elapsed / Self.heightAnimationDuration))
            let eased: CGFloat = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let height = session.startHeight + (session.targetHeight - session.startHeight) * CGFloat(eased)
            animatedRowHeight = (session.rowID, max(1, height))
            applyExplicitRowHeight(tableView)
            pinRowTop(session.rowID, targetTop: session.targetTop, tableView: tableView)
            if t < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in self?.tickHeightAnimation() }
            } else {
                finishHeightAnimation()
            }
        }

        private func finishHeightAnimation() {
            guard let tableView, let session = heightAnimationSession else { return }
            heightAnimationSession = nil
            animatedRowHeight = nil
            applyExplicitRowHeight(tableView)
            pinRowTop(session.rowID, targetTop: session.targetTop, tableView: tableView)
            if let dataSource, let indexPath = dataSource.indexPath(for: session.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                desiredAnchor = (session.rowID, rect.minY - tableView.contentOffset.y)
            } else {
                freezeAnchorFromCurrentViewport(tableView)
            }
            updateNearBottom(tableView: tableView)
            #if DEBUG
            if let ip = dataSource?.indexPath(for: session.rowID) {
                pinLog("session done row=\(session.rowID) finalRowH=\(String(format: "%.1f", tableView.rectForRow(at: ip).height)) off=\(String(format: "%.1f", tableView.contentOffset.y))")
            }
            #endif
        }

 /// 行视图按钮上报「用户主动展开/收起」（toggle 之前调用）。
        func noteUserToggle(rowID: String) {
            let now = CACurrentMediaTime()
            pendingUserToggleRowIDs = pendingUserToggleRowIDs.filter { now - $0.value < 1.0 }
            pendingUserToggleRowIDs[rowID] = now
            guard heightAnimationSession == nil, pendingHeightChange == nil,
                  let tableView = self.tableView,
                  let indexPath = dataSource?.indexPath(for: rowID),
                  let top = visualTop(ofRow: rowID, tableView: tableView) else { return }
            let startHeight = tableView.rectForRow(at: indexPath).height
            beginPendingHeightAnimation(rowID: rowID, targetTop: top, startHeight: startHeight)
        }

        private func consumeUserToggle(rowID: String) -> Bool {
            let now = CACurrentMediaTime()
            pendingUserToggleRowIDs = pendingUserToggleRowIDs.filter { now - $0.value < 1.0 }
            return pendingUserToggleRowIDs.removeValue(forKey: rowID) != nil
        }

        func rowContentHeightChanged(rowID: String, contentHeight: CGFloat) {
            guard contentHeight > 1, let tableView, let dataSource else { return }
            guard let indexPath = dataSource.indexPath(for: rowID) else { return }
 // 用户点击动画进行中/测量中：行高由动画模块统一驱动，忽略上报。
            if pendingHeightChange != nil || heightAnimationSession != nil {
                #if DEBUG
                pinLog("report ignored(session) row=\(rowID) content=\(String(format: "%.1f", contentHeight))")
                #endif
                return
            }
            let rowHeight = tableView.rectForRow(at: indexPath).height
            guard rowHeight > 1, abs(contentHeight - rowHeight) > 1 else { return }
 // 非用户交互的高度变化（首屏/流式/历史补齐）：无锚点重测。
            if consumeUserToggle(rowID: rowID) {
 // 兜底：有点击标记但没走 noteUserToggle 启动路径（理论上不会）。
                guard let top = visualTop(ofRow: rowID, tableView: tableView) else { return }
                beginPendingHeightAnimation(rowID: rowID, targetTop: top, startHeight: rowHeight)
                return
            }
            scheduleLegacyHeightRefresh()
        }

 /// 非用户交互的行高变化：沿用旧行为（合并重测 + 底部可见行锚点），不做入口行固定。
        private func scheduleLegacyHeightRefresh() {
            legacyHeightRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshHeightsLegacy() }
            legacyHeightRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        private func refreshHeightsLegacy() {
            guard let tableView, let dataSource else { return }
            guard heightAnimationSession == nil, pendingHeightChange == nil else { return }
            guard !tableView.isTracking, !tableView.isDecelerating else { return }
            let anchor = captureAnchor(tableView: tableView)
            isAdjustingOffset = true
            UIView.performWithoutAnimation {
                tableView.performBatchUpdates(nil) { _ in }
            }
            tableView.layoutIfNeeded()
            if let anchor, let indexPath = dataSource.indexPath(for: anchor.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                let delta = (rect.minY - tableView.contentOffset.y) - anchor.screenY
                if abs(delta) > 0.5 {
                    var offset = tableView.contentOffset
                    offset.y += delta
                    let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    offset.y = min(max(offset.y, 0), maxY)
                    tableView.setContentOffset(offset, animated: false)
                }
            }
            isAdjustingOffset = false
            freezeAnchorFromCurrentViewport(tableView)
        }
 // MARK: - apply

        func apply(items: [SessionMessageItem], batchToken: Int) {
            guard let tableView, let dataSource else { return }
 // 反转数据源：视觉顺序「旧→新」→ 数据顺序「新→旧」。
            let reversed = Array(items.reversed())
            let ids = reversed.map(\.id)

            var previous: [String: SessionMessageItem] = [:]
            for item in lastItems { previous[item.id] = item }
            var changedIDs: [String] = []
            var newIDs: Set<String> = []
            var previousIDs: Set<String> = []
            var newGroupLookup: [String: FlowRowGroup] = [:]
            for item in items {
                newIDs.insert(item.id)
                if case .group(let group) = item { newGroupLookup[group.id] = group }
                if let old = previous[item.id], old != item { changedIDs.append(item.id) }
            }
            for item in lastItems { previousIDs.insert(item.id) }
 // v0.2.7：显示态（window/full/collapsed/expanded）不参与 FlowRowGroup 等价，
 // 单独比对后并入 changedIDs，走同一条「reconfigure + 重测行高」路径。
 // NOTE: bookkeeping 必须等「确定要 apply」之后再提交——否则被下面的
 // 「读历史时冻结尾部」门拦掉时，diff 已被吞掉，用户点击永远不生效。
            let pendingModeChange = parent.processGroupModes != lastGroupModes
            if pendingModeChange {
                for id in parent.processGroupModes.keys where newIDs.contains(id) {
                    if !changedIDs.contains(id) { changedIDs.append(id) }
                }
            }
 // 阶段切换（running true→false）：最新组要从「运行中窗口」自动切到「折叠一行」。
            let pendingPhaseChange = parent.isRunning != lastRunningFlag
            if pendingPhaseChange,
               let lastGroupID = items.last(where: { if case .group = $0 { return true }; return false })?.id,
               !changedIDs.contains(lastGroupID) {
                changedIDs.append(lastGroupID)
            }
            let insertedIDs = newIDs.subtracting(previousIDs)
 // 数据开头新增 = 视觉底部新内容；数据末尾新增 = 视觉顶部历史补齐。
            let tailAppend = !insertedIDs.isEmpty
                && ids.first.map { insertedIDs.contains($0) } == true
                && ids.last.map { insertedIDs.contains($0) } != true
            let historyAppend = !insertedIDs.isEmpty
                && ids.last.map { insertedIDs.contains($0) } == true
                && insertedIDs.contains(ids.first ?? "") == false

            #if DEBUG
            ScrollJitterProbe.shared?.startIfNeeded()
            if !insertedIDs.isEmpty {
                ScrollJitterProbe.shared?.event("rows", [
                    "old": lastItems.count, "new": items.count,
                    "inserted": insertedIDs.count, "token": batchToken,
                    "tail": tailAppend ? 1 : 0, "history": historyAppend ? 1 : 0,
                ])
            }
            #endif

 // 「强制回底」请求（发送消息 / 答完问答）：放弃冻结的尾部内容，直接回到底部。
            let wantsBottom = parent.scrollToBottomToken != lastScrollToBottomToken
            if wantsBottom {
                lastScrollToBottomToken = parent.scrollToBottomToken
                frozenItems = nil
            }
 // 贴底语义：用户停在近底部（offset ≤140；反转列表 0 = 视觉底部）时，
 // 尾部新增（自己发的消息 / 流式内容）必须直接出现在底部，不能做锚点补偿。
            let wasNearBottom = isNearBottom && tableView.contentOffset.y <= 140

 // 用户正在读历史（不在近底部）时，非历史补齐的变化（新流式行/文本增长）先冻结。
 // 例外：用户交互（点击展开/收起过程组、turn 结束自动折叠）必须立刻生效，
 // 不能被冻结门吞掉。
            if didInitialBottom, !isNearBottom, !historyAppend, !wantsBottom,
               !pendingModeChange, !pendingPhaseChange {
                frozenItems = items
                return
            }
            frozenItems = nil
 // 交互式展开/收起的「被点组」必须在提交 bookkeeping 之前算出：
 // 下面会把 lastGroupModes 更新为新态，更新后再比对就拿不到 diff 了。
            let toggledTargetID = pendingModeChange
                ? Self.toggledGroupTarget(
                    old: lastGroupModes,
                    new: parent.processGroupModes,
                    newIDs: newIDs
                )
                : nil
 // 只有确定要 apply 时才提交交互 bookkeeping（见上：避免 diff 被冻结门吞掉）。
            lastGroupModes = parent.processGroupModes
            lastRunningFlag = parent.isRunning

            let lastDataIDs = lastItems.reversed().map(\.id)
            if ids == lastDataIDs && changedIDs.isEmpty {
                if wantsBottom { forceBottom(tableView) }
                return
            }

 // v0.2.7：交互式展开/收起必须「被点行位置严格固定」——
 // 向下展开把下方 UI 向下挤开、收起反向拉回，150ms ease-in-out，不做任何自动滚动。
 //
 // 关键时序：UIHostingConfiguration 的行高要等 SwiftUI 重新布局后才给出最终值；
 // 在同一同步块里 reconfigure + 重测会读到「中间高度」，
 // 所以这里只应用新内容态，真正的「行高 + offset」动画交给
 // rowContentHeightChanged（SwiftUI 上报最终内容高度后按精确 delta 统一执行）。
            if pendingModeChange, let targetID = toggledTargetID {
 // 先记录被点行当前的视觉顶边与行高（展开/收起后必须严格回到这里）。
                let targetTopBefore = visualTop(ofRow: targetID, tableView: tableView)
                let beforeIndexPath = dataSource.indexPath(for: targetID)
                let startHeightBefore = beforeIndexPath.map { tableView.rectForRow(at: $0).height } ?? 1
                #if DEBUG
                pinLog("modeChange target=\(targetID) beforeH=\(String(format: "%.1f", startHeightBefore)) offset=\(String(format: "%.1f", tableView.contentOffset.y)) top=\(String(format: "%.1f", targetTopBefore ?? -1))")
                #endif
                groupLookup = newGroupLookup
                lastItems = items
                var modeSnapshot = NSDiffableDataSourceSnapshot<String, String>()
                modeSnapshot.appendSections(["main"])
                modeSnapshot.appendItems(ids, toSection: "main")
                if !changedIDs.isEmpty { modeSnapshot.reconfigureItems(changedIDs) }
 // 先钉住旧行高并登记「测量→150ms 逐帧动画」任务（测量在 apply 之后延迟触发；
 // 不能依赖 hosting 高度上报——过程组改显示态根本不会上报）。
                if let targetTopBefore {
                    beginPendingHeightAnimation(rowID: targetID, targetTop: targetTopBefore, startHeight: startHeightBefore)
                }
                isAdjustingOffset = true
                UIView.performWithoutAnimation {
                    dataSource.apply(modeSnapshot, animatingDifferences: false)
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
                tableView.layoutIfNeeded()
                isAdjustingOffset = false
                if let targetTopBefore {
                    pinRowTop(targetID, targetTop: targetTopBefore, tableView: tableView)
                }
                return
            }

            groupLookup = newGroupLookup
            lastItems = items
            let anchorBeforeSnapshot = captureAnchor(tableView: tableView)
            #if DEBUG
            let anchorBefore = anchorBeforeSnapshot
            let offsetBefore = tableView.contentOffset.y
            let contentSizeBefore = tableView.contentSize.height
            #endif
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(ids, toSection: "main")
            if !changedIDs.isEmpty { snapshot.reconfigureItems(changedIDs) }
            #if DEBUG
            let applyStart = CACurrentMediaTime()
            #endif
            dataSource.apply(snapshot, animatingDifferences: false)
            #if DEBUG
            let diffMs = (CACurrentMediaTime() - applyStart) * 1000
            #endif
            tableView.layoutIfNeeded()
 // v0.2.7：UIHostingConfiguration 自撑高行在 reconfigure 后不会自动重测高度，
 // 内容变高（展开/折叠、流式步骤增长）会沿用旧行高 → 内容溢出/裁剪/重叠。
 // 有变化行时做一次可见行重测（performBatchUpdates(nil) 会失效自撑高缓存）。
            if !changedIDs.isEmpty {
                UIView.performWithoutAnimation {
                    tableView.performBatchUpdates(nil) { _ in }
                }
                tableView.layoutIfNeeded()
                #if DEBUG
                logProcessRowHeights(tableView, reason: "changed=\(changedIDs.count)")
                #endif
            }
            #if DEBUG
            let applyMs = (CACurrentMediaTime() - applyStart) * 1000
            PerfProbe.shared.record("apply", ms: applyMs, [
                "diffMs": diffMs,
                "inserted": insertedIDs.count,
                "changed": changedIDs.count,
            ])
            if applyMs > 8 {
                ScrollJitterProbe.shared?.event("applyDur", [
                    "diffMs": diffMs,
                    "totalMs": applyMs,
                    "inserted": insertedIDs.count,
                    "changed": changedIDs.count,
                    "history": historyAppend ? 1 : 0,
                    "tail": tailAppend ? 1 : 0,
                ])
            }
            #endif
            var preCorrectionDelta: CGFloat = 0
            #if DEBUG
            if let before = anchorBefore,
               let indexPath = dataSource.indexPath(for: before.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                preCorrectionDelta = (rect.minY - tableView.contentOffset.y) - before.screenY
            }
            #endif
 // 布局期锚定兜底修正：锚点行是已实体化/可见行，位置是真实布局结果；
 // 若布局后它偏离了原屏幕位置（如 UIKit 因 contentSize/估算变化调整过 offset），
 // 在屏幕提交前按真实差值修正 contentOffset（不依赖任何高度估算）。
 // 例外：贴底/强制回底时新内容在视觉底部，锚点补偿会把 offset 推离底部（新消息落在屏外），
 // 此时直接钉住 offset 0。
            if wantsBottom || (tailAppend && wasNearBottom) {
                forceBottom(tableView)
            } else if let before = anchorBeforeSnapshot,
               !isAdjustingOffset,
               let indexPath = dataSource.indexPath(for: before.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                let delta = (rect.minY - tableView.contentOffset.y) - before.screenY
                if abs(delta) > 0.5 {
                    isAdjustingOffset = true
                    var offset = tableView.contentOffset
                    offset.y += delta
                    let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                    offset.y = min(max(offset.y, 0), maxY)
                    tableView.setContentOffset(offset, animated: false)
                    isAdjustingOffset = false
                }
            }
            #if DEBUG
            if !(wantsBottom || (tailAppend && wasNearBottom)),
               let before = anchorBeforeSnapshot,
               let indexPath = dataSource.indexPath(for: before.rowID) {
                let rect = tableView.rectForRow(at: indexPath)
                let delta = (rect.minY - tableView.contentOffset.y) - before.screenY
                ScrollJitterProbe.shared?.event("anchorShift", [
                    "delta": Double(delta),
                    "preDelta": Double(preCorrectionDelta),
                    "row": before.rowID,
                    "inserted": insertedIDs.count,
                    "history": historyAppend ? 1 : 0,
                    "tail": tailAppend ? 1 : 0,
                    "motion": userIsScrolling ? 1 : 0,
                    "offsetDelta": Double(tableView.contentOffset.y - offsetBefore),
                    "contentDelta": Double(tableView.contentSize.height - contentSizeBefore),
                ])
            }
            #endif

            if !didInitialBottom, !items.isEmpty {
                didInitialBottom = true
                tableView.setContentOffset(.zero, animated: false)   // 反转：0 = 视觉底部
                parent.onFirstContent()
            }
            freezeAnchorFromCurrentViewport(tableView)
            updateNearBottom(tableView: tableView)
        }

 /// 强制回到底部（反转列表：offset 0 = 视觉底部）。
        private func forceBottom(_ tableView: UITableView) {
            frozenItems = nil
            isAdjustingOffset = true
            tableView.setContentOffset(.zero, animated: false)
            isAdjustingOffset = false
            if !isNearBottom {
                isNearBottom = true
                parent.onNearBottomChange(true)
            }
            freezeAnchorFromCurrentViewport(tableView)
        }

        private struct Anchor {
            let rowID: String
            let screenY: CGFloat
        }

        private func captureAnchor(tableView: UITableView) -> Anchor? {
            guard let visible = tableView.indexPathsForVisibleRows?.min(),
                  let id = dataSource?.itemIdentifier(for: visible) else { return nil }
            let rect = tableView.rectForRow(at: visible)
            return Anchor(rowID: id, screenY: rect.minY - tableView.contentOffset.y)
        }

 /// 每次布局后把冻结锚点行放回原屏幕位置（真实 frame，不依赖估算）。
        func stabilizeAfterLayout() {
            guard let tableView, didInitialBottom else { return }
 // 展开/收起动画期间：每次布局提交前把被点行视觉顶边钉回目标位置，
 // 行高逐帧变化与 offset 补偿同帧生效，不会先渲染出一帧位移再纠正。
            if let session = heightAnimationSession {
                isAdjustingOffset = true
                pinRowTop(session.rowID, targetTop: session.targetTop, tableView: tableView)
                isAdjustingOffset = false
                return
            }
 // 视口高度变化（键盘弹出/收起、内联提示行、输入框多行增高）：
 // 读历史时保持可见内容不动；贴底时不动 offset（底部本就随视口移动）。
            let height = tableView.bounds.height
            if height > 1 {
                let previous = lastViewportHeight
                lastViewportHeight = height
                if previous > 1, abs(height - previous) > 0.5,
                   !isNearBottom, !userIsScrolling, !isAdjustingOffset,
                   let anchor = desiredAnchor {
                    desiredAnchor = (anchor.rowID, anchor.screenY - (previous - height))
                }
            }
            guard !userIsScrolling, !isAdjustingOffset,
                  let desired = desiredAnchor,
                  let indexPath = dataSource?.indexPath(for: desired.rowID) else { return }
            let rect = tableView.rectForRow(at: indexPath)
            let delta = (rect.minY - tableView.contentOffset.y) - desired.screenY
            guard abs(delta) > 0.5 else { return }
            #if DEBUG
            pinLog("stabilize row=\(desired.rowID) delta=\(String(format: "%.1f", delta)) offset=\(String(format: "%.1f", tableView.contentOffset.y))")
            #endif
            isAdjustingOffset = true
            var offset = tableView.contentOffset
            offset.y += delta
            let maxY = max(0, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            offset.y = min(max(offset.y, 0), maxY)
            tableView.setContentOffset(offset, animated: false)
            isAdjustingOffset = false
        }

        private func freezeAnchorFromCurrentViewport(_ tableView: UITableView) {
            if let anchor = captureAnchor(tableView: tableView) {
                desiredAnchor = (anchor.rowID, anchor.screenY)
            }
        }

        private func updateNearBottom(tableView: UITableView) {
 // 反转：offset 0 是视觉底部。
            let near = tableView.contentOffset.y <= 140
            if near != isNearBottom {
                isNearBottom = near
                parent.onNearBottomChange(near)
            }
            #if DEBUG
            ScrollJitterProbe.shared?.updateGeometry(
                offsetY: tableView.contentOffset.y,
                contentHeight: tableView.contentSize.height,
                viewportHeight: tableView.bounds.height
            )
            #endif
        }

 // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userIsScrolling = true
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase("interacting")
            #endif
            if !userHasScrolled {
                userHasScrolled = true
                parent.onUserScrolled()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase(decelerate ? "decelerating" : "idle")
            #endif
            if !decelerate, let tableView = scrollView as? AnchoredTableView {
                userIsScrolling = false
                freezeAnchorFromCurrentViewport(tableView)
                stabilizeAfterLayout()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            userIsScrolling = false
            #if DEBUG
            ScrollJitterProbe.shared?.setPhase("idle")
            #endif
            if let tableView = scrollView as? AnchoredTableView {
                freezeAnchorFromCurrentViewport(tableView)
                stabilizeAfterLayout()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            updateNearBottom(tableView: tableView)
 // 回到底部附近 → 应用冻结的尾部内容。
            if let frozen = frozenItems, tableView.contentOffset.y <= 140 {
                frozenItems = nil
                apply(items: frozen, batchToken: parent.historyBatchToken)
            }
        }

 // MARK: - UITableViewDelegate

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            #if DEBUG
            if let id = dataSource?.itemIdentifier(for: indexPath), let cell = cell as? MessageCell {
                ScrollJitterProbe.shared?.register(rowID: id, view: cell)
            }
            #endif
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            #if DEBUG
            if let id = dataSource?.itemIdentifier(for: indexPath) {
                ScrollJitterProbe.shared?.unregister(rowID: id)
            }
            #endif
        }
    }
}

#if DEBUG
/// 帧级探针的行标识（协议只在 DEBUG 存在，Release 构建不得引用）。
extension SessionMessageListView.MessageCell: JitterProbeIdentifiable {
    var jitterRowID: String { rowID }
}
#endif
