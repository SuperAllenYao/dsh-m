import XCTest
import SwiftUI
@testable import DSHm

/// v5.4 session-detail interaction state: composer button machine, client-side
/// prompt queue, turn/end flush policy, connection dot mapping and subagent
/// catalog labels.
final class ComposerQueueTests: XCTestCase {

    // MARK: - Composer button state machine (§2)

    func testComposerButtonStateWithTextIsEnabledSend() {
        let idle = ComposerButtonState.resolve(draft: "hello", isRunning: false, sending: false)
        XCTAssertEqual(idle, ComposerButtonState(action: .send, isEnabled: true))

        // Sending while a turn runs is allowed: the message queues client-side.
        let running = ComposerButtonState.resolve(draft: " hello ", isRunning: true, sending: false)
        XCTAssertEqual(running, ComposerButtonState(action: .send, isEnabled: true))
    }

    func testComposerButtonStateEmptyRunningIsAbort() {
        let state = ComposerButtonState.resolve(draft: "   \n", isRunning: true, sending: false)
        XCTAssertEqual(state, ComposerButtonState(action: .abort, isEnabled: true))
    }

    func testComposerButtonStateEmptyIdleIsDisabledSend() {
        let state = ComposerButtonState.resolve(draft: "", isRunning: false, sending: false)
        XCTAssertEqual(state, ComposerButtonState(action: .send, isEnabled: false))
    }

    func testComposerButtonStateSendingShowsSpinnerAndDisables() {
        let withText = ComposerButtonState.resolve(draft: "next", isRunning: true, sending: true)
        XCTAssertFalse(withText.isEnabled)
        XCTAssertTrue(withText.showsSpinner)
        XCTAssertEqual(withText.action, .send)

        let emptyRunning = ComposerButtonState.resolve(draft: "", isRunning: true, sending: true)
        XCTAssertFalse(emptyRunning.isEnabled)
        XCTAssertTrue(emptyRunning.showsSpinner, "in-flight prompt takes precedence over abort")
    }

    // MARK: - Client-side queue (§3)

    func testPromptQueueIsFIFO() {
        var queue = PromptQueue()
        XCTAssertTrue(queue.isEmpty)
        queue.enqueue(text: "first")
        queue.enqueue(text: "second")
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.first?.text, "first")
        XCTAssertEqual(queue.takeFirst()?.text, "first")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.takeFirst()?.text, "second")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.takeFirst())
    }

    func testPromptQueueRestorePutsFailedPromptBackAtFront() {
        var queue = PromptQueue()
        queue.enqueue(text: "keep me")
        let failed = queue.takeFirst()
        XCTAssertNotNil(failed)
        queue.restore(failed!)
        XCTAssertEqual(queue.first?.text, "keep me")
        XCTAssertEqual(queue.count, 1)
    }

    func testQueueBannerTextFormatAndPreview() {
        var queue = PromptQueue()
        XCTAssertNil(queue.bannerText)

        queue.enqueue(text: "短消息")
        XCTAssertEqual(queue.bannerText, "排队中 1 条 · 短消息 · 点击立即介入")

        queue.enqueue(text: "第一行\n第二行不应出现在细条")
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.bannerText, "排队中 2 条 · 短消息 · 点击立即介入")
    }

    func testPreviewLineUsesFirstLineAndTruncates() {
        XCTAssertEqual(PromptQueue.previewLine("第一行\n第二行"), "第一行")
        XCTAssertEqual(PromptQueue.previewLine("  padded  "), "padded")
        XCTAssertEqual(PromptQueue.previewLine("   \n第二行"), "…")
        let long = String(repeating: "x", count: 40)
        XCTAssertEqual(PromptQueue.previewLine(long), String(repeating: "x", count: 24) + "…")
    }

    // MARK: - turn/end flush policy (§3)

    func testQueueFlushesOnlyOnRunningToIdleTransition() {
        XCTAssertTrue(SessionQueuePolicy.shouldFlush(wasRunning: true, isRunning: false, queuedCount: 1))
        XCTAssertFalse(SessionQueuePolicy.shouldFlush(wasRunning: true, isRunning: false, queuedCount: 0))
        XCTAssertFalse(SessionQueuePolicy.shouldFlush(wasRunning: true, isRunning: true, queuedCount: 2))
        XCTAssertFalse(SessionQueuePolicy.shouldFlush(wasRunning: false, isRunning: false, queuedCount: 2))
        XCTAssertFalse(SessionQueuePolicy.shouldFlush(wasRunning: false, isRunning: true, queuedCount: 2))
    }

    // MARK: - Connection dot (§4)

    func testConnectionStatusKindMapping() {
        XCTAssertEqual(ConnectionStatusKind.kind(for: .connected), .connected)
        XCTAssertEqual(ConnectionStatusKind.kind(for: .connecting), .connecting)
        XCTAssertEqual(ConnectionStatusKind.kind(for: .reconnecting(attempt: 2)), .connecting)
        XCTAssertEqual(ConnectionStatusKind.kind(for: .disconnected), .disconnected)
        XCTAssertEqual(ConnectionStatusKind.kind(for: .needsRepair("bad cert")), .disconnected)
        XCTAssertEqual(ConnectionStatusKind.kind(for: .unpaired), .unpaired)
    }

    func testConnectionIndicatorColorsAndPulse() {
        XCTAssertEqual(ConnectionIndicator.color(for: ConnectionStatusKind.connected), Theme.Palette.accent)
        XCTAssertEqual(ConnectionIndicator.color(for: ConnectionStatusKind.connecting), Theme.Palette.warning)
        XCTAssertEqual(ConnectionIndicator.color(for: ConnectionStatusKind.disconnected), Theme.Palette.danger)
        XCTAssertEqual(ConnectionIndicator.color(for: ConnectionStatusKind.unpaired), Theme.Palette.textTertiary)
        XCTAssertTrue(ConnectionIndicator.isPulsing(ConnectionStatusKind.connecting))
        XCTAssertFalse(ConnectionIndicator.isPulsing(ConnectionStatusKind.connected))
        XCTAssertFalse(ConnectionIndicator.isPulsing(ConnectionStatusKind.disconnected))
        XCTAssertFalse(ConnectionIndicator.isPulsing(ConnectionStatusKind.unpaired))
    }

    // MARK: - subagent catalog labels (§1 relay cards)

    func testSubagentCatalogEntryParsesLabelAndFallsBackToPrefix() {
        let withLabel = SubagentCatalogEntry(json: TestJSON.value("""
        {"id":"session-1234abcd-5678","createdAt":1792510024908,"mode":"continuable","label":"build-agent"}
        """))
        XCTAssertEqual(withLabel?.id, "session-1234abcd-5678")
        XCTAssertEqual(withLabel?.mode, "continuable")
        XCTAssertEqual(withLabel?.displayLabel, "build-agent")
        XCTAssertEqual(withLabel?.createdAt, 1_792_510_024_908)
        XCTAssertEqual(withLabel?.isContinuable, true)

        let withoutLabel = SubagentCatalogEntry(json: TestJSON.value("""
        {"id":"session-1234abcd-5678","mode":"one-shot"}
        """))
        XCTAssertEqual(withoutLabel?.displayLabel, "session-")
        XCTAssertEqual(withoutLabel?.isContinuable, false)

        XCTAssertNil(SubagentCatalogEntry(json: TestJSON.value("{}")))
    }
}
