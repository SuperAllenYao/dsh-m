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
}
