import XCTest
import SwiftUI
@testable import DSHm

/// v5.4 task-13: subagent catalog / routing / protocol args / capsule state.
final class SubagentLoopTests: XCTestCase {

    // MARK: - Catalog modes

    func testSubagentModeParsingAndLabels() {
        XCTAssertEqual(SubagentMode(raw: "one-shot"), .oneShot)
        XCTAssertEqual(SubagentMode(raw: "continuable"), .continuable)
        XCTAssertEqual(SubagentMode(raw: "external"), .external)
        XCTAssertEqual(SubagentMode(raw: nil), .unknown)
        XCTAssertEqual(SubagentMode(raw: "weird"), .unknown)

        XCTAssertEqual(SubagentMode.oneShot.displayLabel, "一次性")
        XCTAssertEqual(SubagentMode.external.displayLabel, "外部")
        XCTAssertEqual(SubagentMode.continuable.displayLabel, "连续")
        XCTAssertEqual(SubagentMode.unknown.displayLabel, "未知")

        XCTAssertTrue(SubagentMode.continuable.isContinuable)
        XCTAssertFalse(SubagentMode.oneShot.isContinuable)
        XCTAssertFalse(SubagentMode.external.isContinuable)
    }

    func testSubagentModeAddressTokens() {
        XCTAssertEqual(SubagentMode.oneShot.addressMode, "one-shot")
        XCTAssertEqual(SubagentMode.external.addressMode, "external")
        XCTAssertEqual(SubagentMode.continuable.addressMode, "continuable")
        XCTAssertEqual(SubagentMode.unknown.addressMode, "unknown")
    }

    // MARK: - Context / read-only (one-shot & external)

    func testOnlyContinuableSubagentAcceptsPrompts() {
        let continuable = SubagentSessionContext(parentSessionId: "p", childSessionId: "c", modeRaw: "continuable")
        XCTAssertFalse(continuable.isReadOnly)
        XCTAssertNil(continuable.readOnlyReason)

        for mode in ["one-shot", "external"] {
            let context = SubagentSessionContext(parentSessionId: "p", childSessionId: "c", modeRaw: mode)
            XCTAssertTrue(context.isReadOnly, "\(mode) must be read-only")
            XCTAssertNotNil(context.readOnlyReason)
            XCTAssertTrue(context.readOnlyReason?.contains("只读") == true)
        }
    }

    func testSubagentFollowAddressUsesCatalogMode() {
        let context = SubagentSessionContext(parentSessionId: "parent-1", childSessionId: "child-1", modeRaw: "continuable")
        XCTAssertEqual(
            context.followAddress,
            .subagent(parentSessionId: "parent-1", childSessionId: "child-1", mode: "continuable")
        )
        let unknown = SubagentSessionContext(parentSessionId: "parent-1", childSessionId: "child-1", modeRaw: nil)
        XCTAssertEqual(
            unknown.followAddress,
            .subagent(parentSessionId: "parent-1", childSessionId: "child-1", mode: "unknown")
        )
    }

    // MARK: - Parent/child routing

    func testBackFromSubagentReturnsToParentSession() {
        let parent: SessionFollowAddress = .session(sessionId: "session-parent")
        XCTAssertEqual(
            SessionBackNavigation.destination(subagentParent: parent),
            .parentSession(parent)
        )
        XCTAssertEqual(SessionBackNavigation.destination(subagentParent: nil), .workspaces)
    }

    // MARK: - subagents/prompt args

    func testSubagentsPromptArgsForQueueDelivery() {
        let payload = SubagentsPromptArgs.make(
            requestId: "req-1",
            parentSessionId: "parent-1",
            childSessionId: "child-1",
            delivery: "queue",
            text: "hello child",
            clientTimeZone: "Asia/Shanghai"
        )
        XCTAssertEqual(payload["requestId"]?.stringValue, "req-1")
        XCTAssertEqual(payload["parentSessionId"]?.stringValue, "parent-1")
        XCTAssertEqual(payload["childSessionId"]?.stringValue, "child-1")
        XCTAssertEqual(payload["mode"]?.stringValue, "continuable")
        XCTAssertEqual(payload["delivery"]?.stringValue, "queue")
        XCTAssertEqual(payload["clientTimeZone"]?.stringValue, "Asia/Shanghai")
        let content = payload["content"]?.arrayValue
        XCTAssertEqual(content?.count, 1)
        XCTAssertEqual(content?.first?["type"]?.stringValue, "text")
        XCTAssertEqual(content?.first?["text"]?.stringValue, "hello child")
    }

    func testSubagentsPromptArgsForSteerDeliveryAndOptionalTimezone() {
        let payload = SubagentsPromptArgs.make(
            parentSessionId: "parent-2",
            childSessionId: "child-2",
            delivery: "steer",
            text: "interject",
            clientTimeZone: nil
        )
        XCTAssertEqual(payload["delivery"]?.stringValue, "steer")
        XCTAssertNil(payload["clientTimeZone"])
        XCTAssertEqual(payload["mode"]?.stringValue, "continuable")
    }

    func testSubagentsInterruptArgs() {
        let payload = SubagentsInterruptArgs.make(parentSessionId: "parent-3", childSessionId: "child-3")
        XCTAssertEqual(payload["parentSessionId"]?.stringValue, "parent-3")
        XCTAssertEqual(payload["childSessionId"]?.stringValue, "child-3")
        XCTAssertEqual(payload.count, 2)
    }

    // MARK: - Runtime status + capsule

    func testStatusResolverPriorityWaitingOverRunning() {
        XCTAssertEqual(SubagentStatusResolver.resolve(isRunning: true, isWaitingAnswer: true), .waiting)
        XCTAssertEqual(SubagentStatusResolver.resolve(isRunning: true, isWaitingAnswer: false), .running)
        XCTAssertEqual(SubagentStatusResolver.resolve(isRunning: false, isWaitingAnswer: false), .idle)
    }

    func testRowStatusColorsAndLabels() {
        XCTAssertEqual(SubagentRowStatus.running.label, "运行中")
        XCTAssertEqual(SubagentRowStatus.running.color, Theme.Palette.running)
        XCTAssertEqual(SubagentRowStatus.waiting.label, "等待作答")
        XCTAssertEqual(SubagentRowStatus.waiting.color, Theme.Palette.waiting)
        XCTAssertEqual(SubagentRowStatus.idle.label, "空闲")
        XCTAssertEqual(SubagentRowStatus.idle.color, Theme.Palette.textSecondary)
    }

    func testCapsuleStateRunningAnimationAndPriority() {
        let running = SubagentRuntime(sessionId: "a", isRunning: true, isWaitingAnswer: false, lastActivityAt: nil, agentAvailable: true)
        let waiting = SubagentRuntime(sessionId: "b", isRunning: true, isWaitingAnswer: true, lastActivityAt: nil, agentAvailable: true)
        let idle = SubagentRuntime(sessionId: "c", isRunning: false, isWaitingAnswer: false, lastActivityAt: nil, agentAvailable: nil)

        let active = SubagentCapsuleState.resolve(catalogCount: 3, runtimes: [running, waiting, idle])
        XCTAssertEqual(active.count, 3)
        XCTAssertEqual(active.runningCount, 2)
        XCTAssertEqual(active.waitingCount, 1)
        XCTAssertTrue(active.isVisible)
        XCTAssertTrue(active.isPulsing)
        XCTAssertEqual(active.dotColor, Theme.Palette.accent)
        XCTAssertEqual(active.accessibilityValue, "running:2")

        let allIdle = SubagentCapsuleState.resolve(catalogCount: 2, runtimes: [idle])
        XCTAssertTrue(allIdle.isVisible)
        XCTAssertFalse(allIdle.isPulsing, "no running child -> static grey dot")
        XCTAssertEqual(allIdle.dotColor, Theme.Palette.textTertiary)
        XCTAssertEqual(allIdle.accessibilityValue, "idle")

        XCTAssertFalse(SubagentCapsuleState.resolve(catalogCount: 0, runtimes: []).isVisible)
    }

    // MARK: - Runtime join

    func testRuntimeBuilderJoinsSessionListRows() {
        let catalog = [
            SubagentCatalogEntry(json: TestJSON.value(#"{"id":"child-1","mode":"continuable","label":"alpha"}"#))!,
            SubagentCatalogEntry(json: TestJSON.value(#"{"id":"child-2","mode":"one-shot","label":"beta"}"#))!,
        ]
        let sessions = [
            TestJSON.sessionItem(
                sessionId: "child-1",
                running: true,
                userQuestionsActive: 0,
                lastPromptAt: 1_792_510_000_000,
                updatedAt: 1_792_510_100_000
            ),
            TestJSON.sessionItem(
                sessionId: "child-2",
                running: false,
                userQuestionsActive: 1,
                lastPromptAt: nil,
                updatedAt: 1_792_510_200_000
            ),
        ]
        let runtimes = SubagentRuntimeBuilder.make(
            catalog: catalog,
            sessions: sessions,
            pendingApprovalAgentIds: []
        )
        XCTAssertEqual(runtimes["child-1"]?.status, .running)
        XCTAssertEqual(runtimes["child-1"]?.lastActivityAt, 1_792_510_000_000)
        XCTAssertEqual(runtimes["child-2"]?.status, .waiting)
        XCTAssertEqual(runtimes["child-2"]?.lastActivityAt, 1_792_510_200_000)
    }

    func testRuntimeBuilderPendingApprovalMarksWaitingAndUnknownStaysIdle() {
        let catalog = [
            SubagentCatalogEntry(json: TestJSON.value(#"{"id":"child-1","mode":"continuable"}"#))!,
            SubagentCatalogEntry(json: TestJSON.value(#"{"id":"child-missing","mode":"external"}"#))!,
        ]
        let runtimes = SubagentRuntimeBuilder.make(
            catalog: catalog,
            sessions: [],
            pendingApprovalAgentIds: ["child-1"]
        )
        XCTAssertEqual(runtimes["child-1"]?.status, .waiting)
        XCTAssertEqual(runtimes["child-1"]?.isRunning, false)
        XCTAssertEqual(runtimes["child-missing"]?.status, .idle)
    }

    // MARK: - Live discovery (v0.2.0)

    func testCatalogDiscoveryFindsChildrenReportedBySessionList() {
        let sessions = [
            TestJSON.sessionItem(sessionId: "parent-1", running: true, origin: nil),
            TestJSON.sessionItem(
                sessionId: "child-1",
                running: true,
                updatedAt: 1_792_510_100_000,
                parentSessionId: "parent-1",
                title: "beam probe"
            ),
            TestJSON.sessionItem(
                sessionId: "child-2",
                running: false,
                parentSessionId: "parent-1"
            ),
            TestJSON.sessionItem(sessionId: "child-other", running: true, parentSessionId: "other-parent"),
        ]
        let discovered = SubagentCatalogMerge.discovered(
            sessions: sessions,
            parentSessionId: "parent-1"
        )
        XCTAssertEqual(discovered.map(\.id), ["child-1", "child-2"])
        XCTAssertEqual(discovered.first?.createdAt, 1_792_510_100_000)
        XCTAssertEqual(discovered.first?.label, "beam probe")
        XCTAssertEqual(discovered.first?.displayLabel, "beam probe")
        XCTAssertEqual(discovered.last?.label, nil)
        XCTAssertEqual(discovered.last?.displayLabel, "child-2")
    }

    func testCatalogDiscoveryIgnoresNormalSessions() {
        let sessions = [
            TestJSON.sessionItem(sessionId: "sibling", running: true, origin: nil),
            TestJSON.sessionItem(sessionId: "child-orphan", running: true, origin: nil),
        ]
        XCTAssertTrue(SubagentCatalogMerge.discovered(sessions: sessions, parentSessionId: "parent-1").isEmpty)
    }

    func testCatalogMergeKeepsProjectionEntriesAndAppendsDiscovered() {
        let projection = [
            SubagentCatalogEntry(id: "child-1", mode: "continuable", label: "alpha")
        ]
        let discovered = [
            SubagentCatalogEntry(id: "child-1", label: "duplicate"),
            SubagentCatalogEntry(id: "child-2", createdAt: 1_792_510_100_000, label: "beta"),
        ]
        let merged = SubagentCatalogMerge.merge(projection: projection, discovered: discovered)
        XCTAssertEqual(merged.map(\.id), ["child-1", "child-2"])
        XCTAssertEqual(merged.first?.mode, "continuable", "projection entry wins")
        XCTAssertEqual(merged.first?.label, "alpha")
        XCTAssertEqual(merged.last?.label, "beta")
    }

    func testCatalogMergeEmptyProjectionFallsBackToDiscovered() {
        let merged = SubagentCatalogMerge.merge(
            projection: [],
            discovered: [SubagentCatalogEntry(id: "child-1")]
        )
        XCTAssertEqual(merged.map(\.id), ["child-1"])
        XCTAssertTrue(SubagentCatalogMerge.merge(projection: [], discovered: []).isEmpty)
    }

    // MARK: - Activity text

    func testSubagentActivityText() {
        let now = Date(timeIntervalSince1970: 1_792_520_000)
        XCTAssertNil(SubagentActivityText.relative(fromMillis: nil, now: now))
        XCTAssertEqual(SubagentActivityText.relative(fromMillis: 1_792_519_970_000, now: now), "刚刚")
        XCTAssertEqual(SubagentActivityText.relative(fromMillis: 1_792_519_700_000, now: now), "5 分钟前")
        XCTAssertEqual(SubagentActivityText.relative(fromMillis: 1_792_509_200_000, now: now), "3 小时前")
        XCTAssertEqual(SubagentActivityText.relative(fromMillis: 1_792_347_200_000, now: now), "2 天前")
    }
}
