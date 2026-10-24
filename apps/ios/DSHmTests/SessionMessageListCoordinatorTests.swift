import XCTest
@testable import DSHm

/// v0.2.7 方案 B：原生 SwiftUI 消息列表的更新策略门禁（纯逻辑，不依赖 UIKit 布局）。
///
/// 覆盖用户可感知的三类行为：
/// - 贴底判定：距底 <= 140pt 或内容不足一屏 → 视为贴底（尾部新内容直接出现）；
/// - 读历史冻结：不贴底时只接收前置的历史补齐行，尾部新内容不插入；
/// - 历史补齐识别：前置新增行列表正确、尾部追加/内容替换不会被误判为补齐。
@MainActor
final class SessionMessageListCoordinatorTests: XCTestCase {
    private func processItem(id: String) -> SessionMessageItem {
        .group(.process([ProcessStep(id: id, kind: .reasoning("reasoning \(id)"))]))
    }

    func testNearBottomWhenContentShorterThanViewport() {
        XCTAssertTrue(MessageListUpdatePolicy.isNearBottom(
            distanceFromBottom: -300,
            contentHeight: 400,
            viewportHeight: 700
        ))
    }

    func testNearBottomWithinThreshold() {
        XCTAssertTrue(MessageListUpdatePolicy.isNearBottom(
            distanceFromBottom: 100,
            contentHeight: 4000,
            viewportHeight: 700
        ))
    }

    func testNotNearBottomBeyondThreshold() {
        XCTAssertFalse(MessageListUpdatePolicy.isNearBottom(
            distanceFromBottom: 200,
            contentHeight: 4000,
            viewportHeight: 700
        ))
    }

    func testLeadingPrependedItemsDetectsHistoryBatch() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = [processItem(id: "old-2"), processItem(id: "old-1")] + displayed
        let prepended = MessageListUpdatePolicy.leadingPrependedItems(displayed: displayed, incoming: incoming)
        XCTAssertEqual(prepended.map(\.id), ["process-old-2", "process-old-1"])
    }

    func testLeadingPrependedItemsIgnoresTailAppend() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = displayed + [processItem(id: "c")]
        XCTAssertTrue(MessageListUpdatePolicy.leadingPrependedItems(displayed: displayed, incoming: incoming).isEmpty)
    }

    func testLeadingPrependedItemsIgnoresContentOnlyChange() {
        let displayed = [processItem(id: "a")]
        let changed: [SessionMessageItem] = [.liveText("streaming...")]
        XCTAssertTrue(MessageListUpdatePolicy.leadingPrependedItems(displayed: displayed, incoming: changed).isEmpty)
    }

    func testLeadingPrependedItemsIgnoresMixedPrependAndTailAppend() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = [processItem(id: "old-1")] + displayed + [processItem(id: "c")]
        XCTAssertTrue(MessageListUpdatePolicy.leadingPrependedItems(displayed: displayed, incoming: incoming).isEmpty,
                      "同时有前置补齐和尾部追加时按冻结处理（避免读历史时位置跳动）")
    }

    // MARK: - 贴底 pinned 状态机（2026-10-24 真机验收 bug1/bug2）
    //
    // 根因：旧实现把 isNearBottom 当状态，程序化内容增长（历史补齐/尾部追加/流式
    // 文本）会把贴底判成 false，尾部结构性更新从此被永久冻结——真机表现为
    // 「停在会话窗口时新消息/思考步骤不再出现」「上滑也看不到历史」。

    /// 程序化内容增长绝不能 unpin（pinned 唯一的解锁者是用户自己的滚动）。
    func testContentGrowthNeverUnpins() {
        XCTAssertTrue(MessageListUpdatePolicy.nextPinnedToBottom(
            current: true, isNearBottom: false, userInteractionActive: false
        ), "内容变长导致的离底不是用户行为，不得 unpin")
    }

    /// 用户上拖离底（交互窗口内）→ unpin，进入读历史冻结态。
    func testUserDragAwayUnpins() {
        XCTAssertFalse(MessageListUpdatePolicy.nextPinnedToBottom(
            current: true, isNearBottom: false, userInteractionActive: true
        ))
    }

    /// 用户拖回底部（交互窗口内）→ repin。
    func testUserDragBackRepins() {
        XCTAssertTrue(MessageListUpdatePolicy.nextPinnedToBottom(
            current: false, isNearBottom: true, userInteractionActive: true
        ))
    }

    /// 没有用户交互时，即使几何上已经贴底也不 repin（pinned 只由用户滚动决定）。
    func testNoInteractionNeverChangesPin() {
        XCTAssertFalse(MessageListUpdatePolicy.nextPinnedToBottom(
            current: false, isNearBottom: true, userInteractionActive: false
        ))
    }

    /// 松手后的惯性/回弹把视口带回底部（超出 unpin 窗口但仍在 repin 窗口）→ repin。
    /// 真机回归：swipeUp 回底时 fling 可能超过 0.6s 才 settle，旧逻辑永远 repin 不回来。
    func testInertiaSettleRepinsInsideLongerRepinWindow() {
        XCTAssertTrue(MessageListUpdatePolicy.nextPinnedToBottom(
            current: false, isNearBottom: true, userInteractionActive: false, userCanRepin: true
        ), "惯性回底也必须恢复贴底，否则 App 停在旧内容")
    }

    /// repin 窗口内若还没到底（near=false），不得 repin（不能把读历史的人拽回底部）。
    func testRepinWindowRequiresActuallyNearBottom() {
        XCTAssertFalse(MessageListUpdatePolicy.nextPinnedToBottom(
            current: false, isNearBottom: false, userInteractionActive: false, userCanRepin: true
        ))
    }

    /// pinned 下历史页 prepend：整批应用 + 要求「可验证贴底」，不进入锚点恢复。
    func testPinnedPrependKeepsBottom() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = [processItem(id: "old-2"), processItem(id: "old-1")] + displayed
        let plan = MessageListUpdatePolicy.plan(pinned: true, displayed: displayed, incoming: incoming)
        XCTAssertEqual(plan.items.map(\.id), incoming.map(\.id), "pinned 时历史补齐必须整批应用")
        XCTAssertTrue(plan.stickToBottom, "pinned 下内容增长后必须贴回底部，不能原地漂移")
        XCTAssertFalse(plan.restoreAnchor)
    }

    /// unpinned 下历史页 prepend：整批应用（App = 桌面会话实时镜像，尾部不再冻结），
    /// 并按可见锚点还原阅读位置。
    func testUnpinnedPrependKeepsAnchorAndAppliesTail() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = [processItem(id: "old-2"), processItem(id: "old-1")]
            + displayed + [processItem(id: "c")]
        let plan = MessageListUpdatePolicy.plan(pinned: false, displayed: displayed, incoming: incoming)
        XCTAssertEqual(plan.items.map(\.id), incoming.map(\.id),
                       "读历史时尾部新内容也必须实时应用（视口下方新增不会移动阅读位置）")
        XCTAssertFalse(plan.stickToBottom)
        XCTAssertTrue(plan.restoreAnchor, "历史页插入必须按可见锚点还原，否则可见内容向后漂移")
    }

    /// 读历史时尾部 append / live text：必须应用到 displayedItems，且不滚动。
    func testUnpinnedTailAppendAlwaysApplied() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming: [SessionMessageItem] = displayed + [processItem(id: "c"), .liveText("streaming")]
        let plan = MessageListUpdatePolicy.plan(pinned: false, displayed: displayed, incoming: incoming)
        XCTAssertEqual(plan.items.map(\.id), incoming.map(\.id),
                       "App 是桌面会话实时镜像：读历史时尾部新行/live text 也必须立刻出现")
        XCTAssertFalse(plan.stickToBottom)
        XCTAssertFalse(plan.restoreAnchor, "尾部 append 不会移动阅读位置，不需要锚点还原")
    }

    /// 读历史时尾部过程组步骤数变化（同一 id 内容变长）：必须实时应用。
    func testUnpinnedTailGroupGrowthAlwaysApplied() {
        let displayed = [processItem(id: "a")]
        let grown: [SessionMessageItem] = [.group(.process([
            ProcessStep(id: "a", kind: .reasoning("r1")),
            ProcessStep(id: "s2", kind: .reasoning("r2")),
        ]))]
        let plan = MessageListUpdatePolicy.plan(pinned: false, displayed: displayed, incoming: grown)
        XCTAssertEqual(plan.items, grown, "读历史时最新过程组的步骤数变化必须实时应用")
        XCTAssertFalse(plan.restoreAnchor)
        XCTAssertFalse(plan.stickToBottom)
    }

    /// 历史补齐与 live 事件同帧到达：补齐照常识别（尾部追加允许）。
    func testHistoryPrefixAppliesWhenTailAppendedSameFrame() {
        let displayed = [processItem(id: "a"), processItem(id: "b")]
        let incoming = [processItem(id: "old-1")] + displayed + [processItem(id: "c")]
        let prefix = MessageListUpdatePolicy.historyPrefix(displayed: displayed, incoming: incoming)
        XCTAssertEqual(prefix.map(\.id), ["process-old-1"])
    }

    /// 读历史时只有尾部内容更新（文件变更卡数字）：整批应用，不滚动。
    func testUnpinnedTailOnlyUpdateAppliesInPlace() {
        let group = processItem(id: "a")
        let fallback = TurnFileChanges(source: .metaDiffsFallback, files: [], added: 0, deleted: 0, seq: 4)
        let exact = TurnFileChanges(source: .exactFetch, files: [], added: 12, deleted: 3, seq: 4, total: 7)
        let displayed: [SessionMessageItem] = [group, .fileChanges(fallback)]
        let incoming: [SessionMessageItem] = [group, .fileChanges(exact)]
        let plan = MessageListUpdatePolicy.plan(pinned: false, displayed: displayed, incoming: incoming)
        XCTAssertEqual(plan.items.count, 2)
        guard case .fileChanges(let applied)? = plan.items.last else { return XCTFail("尾部仍是文件变更行") }
        XCTAssertEqual(applied.titleFileCount, 7, "读历史时卡片数字也必须刷新")
        XCTAssertFalse(plan.restoreAnchor, "尾部原地更新不移动阅读位置")
        XCTAssertFalse(plan.stickToBottom)
    }

    // MARK: - 贴底自证/重试（真机大 prepend 后 scrollTo 静默失败 → 不再漂移）

    /// 已真实贴底（底部哨兵行进视口）→ 不再重试。
    func testStickRetryStopsWhenSettled() {
        XCTAssertNil(MessageListUpdatePolicy.stickRetryDelay(attempt: 0, isAtBottom: true, elapsed: 0))
    }

    /// 未贴底 → 按 20/50/100/200/400ms 退避，耗尽后停止（有限重试）。
    func testStickRetryBackoffSequenceIsFinite() {
        var delays: [TimeInterval] = []
        var attempt = 0
        var elapsed: TimeInterval = 0
        while let delay = MessageListUpdatePolicy.stickRetryDelay(
            attempt: attempt, isAtBottom: false, elapsed: elapsed
        ) {
            delays.append(delay)
            elapsed += delay
            attempt += 1
        }
        XCTAssertEqual(delays, [0.02, 0.05, 0.1, 0.2, 0.4], "重试必须有限且逐步退避")
    }

    /// 重试不再改善（连续两次相同距离且仍不在容差内）→ 判定停滞，停止无意义重试。
    /// 真机日志：scrollTo 已到物理极限时 distance 恒 147.7，旧逻辑会空转 5 次。
    func testStickStalledWhenDistanceStopsImproving() {
        XCTAssertTrue(MessageListUpdatePolicy.stickStalled(previousDistance: 147.7, currentDistance: 147.7))
        XCTAssertFalse(MessageListUpdatePolicy.stickStalled(previousDistance: 396.3, currentDistance: 59.0),
                       "还在改善就不能停")
        XCTAssertFalse(MessageListUpdatePolicy.stickStalled(previousDistance: 147.7, currentDistance: 1.0),
                       "已进入容差内应判 settled（不是停滞）")
        XCTAssertFalse(MessageListUpdatePolicy.stickStalled(
            previousDistance: .greatestFiniteMagnitude, currentDistance: 147.7
        ), "首拍没有历史测量值，不能误判停滞")
    }

    /// 时间预算耗尽 → 即使还有重试次数也停止（流式内容持续增长时不无限滚）。
    func testStickRetryStopsWhenElapsedBudgetExceeded() {
        XCTAssertNil(MessageListUpdatePolicy.stickRetryDelay(
            attempt: 0, isAtBottom: false, elapsed: MessageListUpdatePolicy.stickMaxDuration
        ))
    }

    /// pinned 下连续 3 批 prepend：每批都不得 unpin；模拟首拍 scrollTo 静默失败
    /// （布局未提交 → 验证未到底），退避重试后自证到底，最终仍在底部。
    func testPinnedPrependThreeBatchesRetriesUntilSettled() {
        var pinned = true
        for batch in 0..<3 {
            pinned = MessageListUpdatePolicy.nextPinnedToBottom(
                current: pinned, isNearBottom: false, userInteractionActive: false
            )
            XCTAssertTrue(pinned, "batch \(batch): 程序化 prepend 绝不能 unpin")

            var attempts = 0
            var settled = false
            var delays: [TimeInterval] = []
            var elapsed: TimeInterval = 0
            while let delay = MessageListUpdatePolicy.stickRetryDelay(
                attempt: attempts, isAtBottom: settled, elapsed: elapsed
            ) {
                delays.append(delay)
                attempts += 1
                elapsed += delay
                // 模拟：第一拍 scrollTo 因布局未提交而静默失败，重试一次后到底。
                if attempts >= 2 { settled = true }
            }
            XCTAssertEqual(delays, [0.02, 0.05], "batch \(batch): 首拍失败后应退避重试并自证到底")
            XCTAssertTrue(settled, "batch \(batch): 重试后必须 settle 在底部")
        }
    }

    /// 最新过程组指纹：步骤数不变、内容原地更新（tool 结果/推理文本/运行态）也必须触发重绘。
    func testProcessFingerprintDetectsInPlaceStepUpdates() {
        let before = [
            ProcessStep(id: "s1", kind: .reasoning("思考中")),
            ProcessStep(id: "s2", kind: .reasoning("")),
        ]
        let after = [
            ProcessStep(id: "s1", kind: .reasoning("思考完成：结论 A")),
            ProcessStep(id: "s2", kind: .reasoning("")),
        ]
        XCTAssertNotEqual(
            MessageListUpdatePolicy.processFingerprint(before),
            MessageListUpdatePolicy.processFingerprint(after),
            "步骤内容原地更新（行数不变）必须反映到渲染签名，否则 App 不实时"
        )
        XCTAssertEqual(
            MessageListUpdatePolicy.processFingerprint(before),
            MessageListUpdatePolicy.processFingerprint(before),
            "内容没变时指纹稳定，不做多余状态更新"
        )
    }

    /// 锚点相对偏移的 UnitPoint 换算：整行可见时能精确还原，越界/退化时返回 nil。
    func testAnchorFractionRestoresRelativeOffset() throws {
        let fraction = try XCTUnwrap(MessageListUpdatePolicy.anchorFraction(
            relativeY: 150, rowHeight: 100, viewportHeight: 700
        ))
        XCTAssertEqual(fraction, 0.25, accuracy: 0.0001)
        XCTAssertNil(MessageListUpdatePolicy.anchorFraction(
            relativeY: -40, rowHeight: 100, viewportHeight: 700
        ), "行顶在视口外的偏移无法用 UnitPoint 表达，退化为 .top")
        XCTAssertNil(MessageListUpdatePolicy.anchorFraction(
            relativeY: 10, rowHeight: 700, viewportHeight: 700
        ), "行高占满视口时比例退化")
    }
}
