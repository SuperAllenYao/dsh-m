import SwiftUI
import UIKit

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

/// 布局回调型 UITableView：每次布局完成（屏幕提交前）通知协调器做「锚点行位置保持」。
final class AnchoredTableView: UITableView {
    var onLayoutPass: (() -> Void)?
    private var isReentrant = false
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isReentrant else { return }
        isReentrant = true
        onLayoutPass?()
        isReentrant = false
    }
}

/// **UIKit 消息列表底座（反转布局 + 布局期锚定）** —— v0.2.6 滚动稳定性重构，2026-10-23。
///
/// 架构（业界聊天列表的标准做法）：
/// - `UITableView` 整体上下翻转（`scaleY(-1)`），cell 再翻转回来；数据源**新→旧**排列。
///   于是「向历史方向补数据」= 向数据源**尾部追加**：已有内容的 content 坐标不变，
///   可见内容与滚动位置**结构性不受影响**（不依赖行高估算、不需要任何 offset 补偿）。
/// - 行视图仍复用 SwiftUI（`UIHostingConfiguration`，iOS 16+），渲染逻辑零改动。
/// - 「用户正在读历史、尚未回到底部」时，新的流式行先不插入（标准聊天语义：新消息在回到底部时出现）：
///   避免反转布局里向数据头插入造成可见位移；回到近底部时一次性应用。
/// - 用户贴底时新消息直接出现在底部（offset 0 = 视觉底部，无需滚动）。
struct SessionMessageListView: UIViewRepresentable {
    let items: [SessionMessageItem]
    let sessionId: String
    let attachments: AttachmentStore
    let pendingApprovalCallIds: Set<String>
    let subagentLabels: [String: String]
    let isRunning: Bool
    let historyBatchToken: Int
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

    final class MessageCell: UITableViewCell, JitterProbeIdentifiable {
        static let reuseID = "SessionMessageCell"
        var rowID: String = ""
        var jitterRowID: String { rowID }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            selectionStyle = .none
            // 反转回来，让 SwiftUI 内容正立。
            transform = CGAffineTransform(scaleX: 1, y: -1)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ parent: SessionMessageListView, item: SessionMessageItem, isNewest: Bool) {
            rowID = item.id
            contentConfiguration = UIHostingConfiguration {
                Group {
                    switch item {
                    case .group(let group):
                        FlowRowGroupView(
                            group: group,
                            sessionId: parent.sessionId,
                            attachments: parent.attachments,
                            pendingApprovalCallIds: parent.pendingApprovalCallIds,
                            subagentLabels: parent.subagentLabels,
                            isNewestGroupRunning: isNewest,
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
            }
            .margins(.all, 0)
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
        private var userIsScrolling = false
        private var isAdjustingOffset = false
        /// 静止阅读时的冻结锚点（最上方可见行 + 屏幕位置）；每次布局后保持它不动。
        private var desiredAnchor: (rowID: String, screenY: CGFloat)?

        init(_ parent: SessionMessageListView) {
            self.parent = parent
        }

        func attach(tableView: AnchoredTableView) {
            self.tableView = tableView
            tableView.onLayoutPass = { [weak self] in self?.stabilizeAfterLayout() }
            tableView.delegate = self
            tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
            let dataSource = UITableViewDiffableDataSource<String, String>(tableView: tableView) { [weak self] tableView, indexPath, itemID in
                guard let self,
                      let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as? MessageCell,
                      let item = self.item(for: itemID) else {
                    return UITableViewCell()
                }
                cell.configure(self.parent, item: item, isNewest: self.isNewest(item))
                #if DEBUG
                ScrollJitterProbe.shared?.register(rowID: itemID, view: cell)
                #endif
                return cell
            }
            self.dataSource = dataSource
        }

        func detach() {
            #if DEBUG
            ScrollJitterProbe.shared?.stop()
            #endif
        }

        private func item(for id: String) -> SessionMessageItem? {
            if let group = groupLookup[id] { return .group(group) }
            return lastItems.first { $0.id == id }
        }

        private func isNewest(_ item: SessionMessageItem) -> Bool {
            guard parent.isRunning else { return false }
            if case .group(let group) = item {
                return group.id == parent.items.last(where: { if case .group = $0 { return true }; return false })?.id
            }
            return false
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

            // 用户正在读历史（不在近底部）时，非历史补齐的变化（新流式行/文本增长）先冻结。
            if didInitialBottom, !isNearBottom, !historyAppend {
                frozenItems = items
                return
            }
            frozenItems = nil

            let lastDataIDs = lastItems.reversed().map(\.id)
            if ids == lastDataIDs && changedIDs.isEmpty { return }

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
            dataSource.apply(snapshot, animatingDifferences: false)
            tableView.layoutIfNeeded()
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
            if let before = anchorBeforeSnapshot,
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
            if let before = anchorBeforeSnapshot,
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
            guard let tableView, didInitialBottom,
                  !userIsScrolling, !isAdjustingOffset,
                  let desired = desiredAnchor,
                  let indexPath = dataSource?.indexPath(for: desired.rowID) else { return }
            let rect = tableView.rectForRow(at: indexPath)
            let delta = (rect.minY - tableView.contentOffset.y) - desired.screenY
            guard abs(delta) > 0.5 else { return }
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
