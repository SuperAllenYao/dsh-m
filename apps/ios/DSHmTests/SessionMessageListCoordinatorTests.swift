import XCTest
import UIKit
@testable import DSHm

/// v0.2.6 滚动底座（UIKit 反转列表）的产品语义门禁（模拟器单测，不替代真机 E2E）：
/// - 贴底时尾部新增（自己的消息/流式内容）→ offset 保持 0，新内容直接出现；
/// - 读历史时尾部新增 → 冻结，回到底部才一次性出现；
/// - 发送消息（scrollToBottomToken +1）→ 无论在哪都强制回底；
/// - 历史上补（prepend）→ 可见行屏幕位置不动（A1 的结构性保证）；
/// - 视口高度变化（键盘/内联行）→ 读历史时保持阅读位置。
@MainActor
final class SessionMessageListCoordinatorTests: XCTestCase {
    private var window: UIWindow!
    private var tableView: AnchoredTableView!
    private var coordinator: SessionMessageListView.Coordinator!

    override func setUp() {
        super.setUp()
        // 只构造窗口层级用于布局/坐标换算，**不 makeKeyAndVisible**：
        // 单测不应抢 key window（历史上曾干扰模拟器环境）。
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 760))
        let controller = UIViewController()
        window.rootViewController = controller

        tableView = AnchoredTableView(frame: CGRect(x: 0, y: 0, width: 402, height: 700), style: .plain)
        tableView.estimatedRowHeight = 160
        tableView.rowHeight = UITableView.automaticDimension
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.separatorStyle = .none
        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
        controller.view.addSubview(tableView)
        tableView.layoutIfNeeded()

        coordinator = SessionMessageListView.Coordinator(makeParent(items: []))
        coordinator.attach(tableView: tableView)
        tableView.layoutIfNeeded()
    }

    override func tearDown() {
        coordinator?.detach()
        coordinator = nil
        tableView = nil
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - fixtures

    /// 用 .process 组造行：组 id = "process-<尾 step id>"，插入/删除都能被 diffable 正确识别。
    private func items(count: Int, prefix: Int = 0) -> [SessionMessageItem] {
        (0..<count).map { index in
            let stepID = "step-\(prefix + index)"
            return .group(.process([ProcessStep(id: stepID, kind: .reasoning("reasoning \(prefix + index)"))]))
        }
    }

    private func makeParent(items: [SessionMessageItem],
                            token: Int = 0,
                            batchToken: Int = 0,
                            nearBottom: @escaping (Bool) -> Void = { _ in }) -> SessionMessageListView {
        SessionMessageListView(
            items: items,
            sessionId: "session-test",
            attachments: AttachmentStore(sessionId: "session-test"),
            pendingApprovalCallIds: [],
            subagentLabels: [:],
            isRunning: false,
            historyBatchToken: batchToken,
            scrollToBottomToken: token,
            onOpenTool: { _ in },
            onOpenFileChanges: { _ in },
            onNearBottomChange: nearBottom,
            onUserScrolled: {},
            onFirstContent: {},
            onRetry: {}
        )
    }

    private func apply(_ parent: SessionMessageListView) {
        coordinator.parent = parent
        coordinator.apply(items: parent.items, batchToken: parent.historyBatchToken)
        tableView.layoutIfNeeded()
    }

    /// 模拟真实用户滚动：走 scrollView 代理的拖拽开始/结束，让列表进入「用户滚动」状态
    /// （程序化 setContentOffset 会被冻结锚点纠回底部，不能用来模拟用户读历史）。
    private func scroll(to offset: CGFloat) {
        coordinator.scrollViewWillBeginDragging(tableView)
        tableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        coordinator.scrollViewDidScroll(tableView)
        tableView.layoutIfNeeded()
        coordinator.scrollViewDidEndDecelerating(tableView)
        tableView.layoutIfNeeded()
    }

    private func rowID(of cell: UITableViewCell) -> String? {
        (cell as? SessionMessageListView.MessageCell)?.rowID
    }

    private func windowY(of cell: UITableViewCell) -> CGFloat {
        cell.convert(cell.bounds, to: nil).minY
    }

    // MARK: - tests

    /// 首帧内容 → 钉在视觉底部（反转列表 offset 0）。
    func testInitialContentPinsToVisualBottom() {
        apply(makeParent(items: items(count: 30)))
        XCTAssertEqual(tableView.numberOfRows(inSection: 0), 30)
        XCTAssertEqual(tableView.contentOffset.y, 0, accuracy: 0.5)
    }

    /// 历史上补（视觉顶部插入）→ 可见行屏幕位置不动。
    func testHistoryPrependKeepsVisibleRowPosition() {
        let base = items(count: 40)
        apply(makeParent(items: base))
        scroll(to: 800)
        guard let anchorCell = tableView.visibleCells.first else {
            return XCTFail("滚动后必须有可见行")
        }
        guard let anchorID = rowID(of: anchorCell) else {
            return XCTFail("可见行必须带 rowID")
        }
        let anchorY = windowY(of: anchorCell)

        let older = items(count: 20, prefix: 1000)
        apply(makeParent(items: older + base, batchToken: 1))

        guard let after = tableView.visibleCells.first(where: { rowID(of: $0) == anchorID }) else {
            return XCTFail("锚点行在上补后必须仍然可见")
        }
        XCTAssertEqual(windowY(of: after), anchorY, accuracy: 0.5,
                       "历史补齐插入后锚点行屏幕位置不得移动")
    }

    /// 贴底时尾部新增（自己的消息）→ offset 保持 0，行数增长。
    func testTailInsertWhilePinnedToBottomKeepsOffsetZero() {
        apply(makeParent(items: items(count: 20)))
        XCTAssertEqual(tableView.contentOffset.y, 0, accuracy: 0.5)

        apply(makeParent(items: items(count: 21)))
        XCTAssertEqual(tableView.numberOfRows(inSection: 0), 21)
        XCTAssertEqual(tableView.contentOffset.y, 0, accuracy: 0.5,
                       "贴底时新消息必须直接出现在底部（offset 不能漂移）")
    }

    /// 读历史时尾部新增 → 冻结；回到底部 → 一次性应用。
    func testTailInsertFreezesWhileReadingHistoryAndAppliesAtBottom() {
        apply(makeParent(items: items(count: 24)))
        scroll(to: 900)
        XCTAssertGreaterThan(tableView.contentOffset.y, 140, "必须处于读历史状态")

        let before = tableView.numberOfRows(inSection: 0)
        apply(makeParent(items: items(count: 25)))
        XCTAssertEqual(tableView.numberOfRows(inSection: 0), before,
                       "读历史时新尾部内容必须冻结（不得插入）")

        scroll(to: 0)
        XCTAssertEqual(tableView.numberOfRows(inSection: 0), 25,
                       "回到底部后冻结内容必须一次性出现")
    }

    /// 发送消息（token +1）→ 无论读到哪里都强制回底，并立刻看到新消息。
    func testSendTokenForcesBottomEvenWhileReadingHistory() {
        apply(makeParent(items: items(count: 24)))
        scroll(to: 900)
        XCTAssertGreaterThan(tableView.contentOffset.y, 140)

        apply(makeParent(items: items(count: 25), token: 1))
        XCTAssertEqual(tableView.numberOfRows(inSection: 0), 25)
        XCTAssertEqual(tableView.contentOffset.y, 0, accuracy: 0.5,
                       "发送后必须强制回到底部")
    }

    /// 视口高度缩短（键盘/内联行出现）→ 读历史时阅读位置不跳。
    func testViewportHeightChangeKeepsReadingPosition() {
        apply(makeParent(items: items(count: 40)))
        scroll(to: 800)
        // 视口中部的行：视口变矮时不会被裁掉，用 indexPath 定位最稳（不依赖 rowID/AX 状态）。
        let visibleSorted = tableView.visibleCells.sorted { windowY(of: $0) < windowY(of: $1) }
        guard visibleSorted.count >= 3 else {
            return XCTFail("视口内至少要有 3 行，实际 \(visibleSorted.count)")
        }
        let anchorCell = visibleSorted[visibleSorted.count / 2]
        guard let anchorIndex = tableView.indexPath(for: anchorCell) else {
            return XCTFail("锚点行必须有 indexPath")
        }
        let anchorY = windowY(of: anchorCell)

        let offsetBefore = tableView.contentOffset.y
        tableView.frame.size.height -= 300   // 键盘弹出：视口变矮
        tableView.layoutIfNeeded()
        let offsetAfter = tableView.contentOffset.y

        // 视口变矮后，原本靠近视口底部的行会被键盘区域遮挡（任何列表都如此），
        // 这里断言的是「未被裁掉的行位置不跳」，因此锚点必须是顶部可见行。
        guard let after = tableView.cellForRow(at: anchorIndex) else {
            return XCTFail("视口变化后锚点行必须仍然可见"
                           + " indexPath=\(anchorIndex) anchorY=\(anchorY)"
                           + " offsetBefore=\(offsetBefore) offsetAfter=\(offsetAfter)"
                           + " frame=\(tableView.frame)")
        }
        XCTAssertEqual(offsetAfter - offsetBefore, 300, accuracy: 2.0,
                       "视口变矮 300 时 offset 必须补偿 300（内容不随键盘上移）")
        XCTAssertEqual(windowY(of: after), anchorY, accuracy: 1.0,
                       "视口高度变化时读历史位置不得跳动")
    }
}
