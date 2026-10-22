import UIKit
import UserNotifications
import XCTest
@testable import DSHm

final class PushNotificationTests: XCTestCase {

    func testApprovalPayloadParsing() {
        let payload = PushNotificationPayload(userInfo: [
            "type": "approval",
            "toolName": "bash",
            "eventId": "evt-1",
            "sessionId": "session-1",
        ])
        XCTAssertEqual(payload.kind, .approval)
        XCTAssertEqual(payload.sessionId, "session-1")
        XCTAssertEqual(payload.toolName, "bash")
        XCTAssertEqual(payload.eventId, "evt-1")
        XCTAssertEqual(payload.shortDescription, "approval · bash")
    }

    func testTurnEndAndUnknownPayload() {
        XCTAssertEqual(PushNotificationPayload(userInfo: ["type": "turn-end"]).kind, .turnEnd)
        let unknown = PushNotificationPayload(userInfo: ["type": "something-else"])
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertNil(unknown.sessionId)
    }

    /// Legacy compatibility: dsh-m-link builds before the 2026-10-21 release
    /// hardening nested the custom keys under `aps["dsh-m"]`; pushes in flight
    /// during an app/plugin upgrade window still arrive in that shape. The
    /// current sender (`packages/dsh-m-link/lib/apns.js` `buildApnsPayload`)
    /// puts the keys at the payload root instead (covered by the simctl fixture
    /// test below).
    func testRealDeviceNestedPayloadParsing() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": [
                "alert": ["title": "DSH 测试通知", "body": "点开进会话"],
                "sound": "default",
                "dsh-m": ["type": "test", "sessionId": "session-nested"],
            ],
        ])
        XCTAssertEqual(payload.kind, .test)
        XCTAssertEqual(payload.sessionId, "session-nested")
        XCTAssertEqual(payload.shortDescription, "test")
    }

    func testNestedPayloadWithApprovalShape() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": [
                "alert": ["title": "DSH 需要审批", "body": "工具调用 bash 等待确认"],
                "dsh-m": ["type": "approval", "toolName": "bash", "eventId": "evt-1", "sessionId": "session-2"],
            ],
        ])
        XCTAssertEqual(payload.kind, .approval)
        XCTAssertEqual(payload.sessionId, "session-2")
        XCTAssertEqual(payload.toolName, "bash")
        XCTAssertEqual(payload.eventId, "evt-1")
    }

    /// simctl fixtures keep the flat root contract; it must keep working.
    func testSimctlPushFixtureStillParses() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": ["alert": ["title": "DSH 测试通知", "body": "点击打开会话"], "sound": "default"],
            "type": "turn-end",
            "sessionId": "session-flat",
        ])
        XCTAssertEqual(payload.kind, .turnEnd)
        XCTAssertEqual(payload.sessionId, "session-flat")
    }

    func testDeviceTokenHexFormat() {
        let data = Data([0x00, 0x0f, 0xa1, 0xff])
        XCTAssertEqual(PushTokenFormatter.hex(data), "000fa1ff")
    }

    func testAPNsTokenValidation() {
        XCTAssertTrue(APNsTokenValidator.isValidHex(String(repeating: "ab", count: 32)))
        XCTAssertTrue(APNsTokenValidator.isValidHex(String(repeating: "AB", count: 32)))
        XCTAssertFalse(APNsTokenValidator.isValidHex("abc"))
        XCTAssertFalse(APNsTokenValidator.isValidHex(String(repeating: "zz", count: 32)))
    }

    func testRegistrationResponseFields() {
        let registration = LinkService.PushTokenRegistration(
            deviceId: "device-1",
            mode: "ready",
            environment: "sandbox",
            topic: "com.dshm.app",
            tokenFingerprint: "0123456789",
            renamed: false
        )
        XCTAssertEqual(registration.mode, "ready")
        XCTAssertEqual(registration.topic, "com.dshm.app")
        XCTAssertEqual(registration.tokenFingerprint?.count, 10)
    }

    // MARK: - M4 §3: approval notification actions

    /// Contract §3: category `dshm-approval` with the allow/deny actions, and
    /// **both** actions must be `.authenticationRequired` (user decision: execute
    /// only after unlock); deny additionally `.destructive`, category options empty.
    func testApprovalCategoryRegistersUnlockGatedActions() throws {
        let category = PushActionRouter.makeApprovalCategory()
        XCTAssertEqual(category.identifier, "dshm-approval")
        XCTAssertEqual(category.actions.count, 2)
        XCTAssertTrue(category.options.isEmpty)

        let byIdentifier = Dictionary(uniqueKeysWithValues: category.actions.map { ($0.identifier, $0) })
        let allow = try XCTUnwrap(byIdentifier["dshm.approval.allow"])
        let deny = try XCTUnwrap(byIdentifier["dshm.approval.deny"])

        XCTAssertEqual(allow.title, "允许")
        XCTAssertTrue(allow.options.contains(.authenticationRequired))
        XCTAssertFalse(allow.options.contains(.destructive))

        XCTAssertEqual(deny.title, "拒绝")
        XCTAssertTrue(deny.options.contains(.authenticationRequired))
        XCTAssertTrue(deny.options.contains(.destructive))
    }

    /// actionIdentifier -> outcome mapping; every non-approval identifier is nil
    /// so a stray response is never turned into a decision.
    func testActionIdentifierMapsToApprovalOutcome() {
        XCTAssertEqual(
            PushActionRouter.approvalOutcome(forActionIdentifier: "dshm.approval.allow"),
            .allowedOnce
        )
        XCTAssertEqual(
            PushActionRouter.approvalOutcome(forActionIdentifier: "dshm.approval.deny"),
            .rejected
        )
        XCTAssertNil(PushActionRouter.approvalOutcome(forActionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(PushActionRouter.approvalOutcome(forActionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertNil(PushActionRouter.approvalOutcome(forActionIdentifier: "dshm.approval.other"))
    }

    func testAllowActionRoutesDecisionFromApprovalPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": "dshm-approval"],
            "type": "approval",
            "eventId": "evt-9",
            "sessionId": "session-9",
            "toolName": "bash",
        ]
        XCTAssertEqual(
            PushActionRouter.route(userInfo: userInfo, actionIdentifier: "dshm.approval.allow"),
            .approval(PushApprovalDecision(
                eventId: "evt-9",
                sessionId: "session-9",
                toolName: "bash",
                outcome: .allowedOnce
            ))
        )
    }

    func testDenyActionRoutesRejectedDecision() {
        let userInfo: [AnyHashable: Any] = [
            "type": "approval",
            "eventId": "evt-9",
            "sessionId": "session-9",
        ]
        XCTAssertEqual(
            PushActionRouter.route(userInfo: userInfo, actionIdentifier: "dshm.approval.deny"),
            .approval(PushApprovalDecision(
                eventId: "evt-9",
                sessionId: "session-9",
                toolName: nil,
                outcome: .rejected
            ))
        )
    }

    /// Contract §3.2: a missing/empty eventId cannot address `$events/result` —
    /// fall back to opening the session instead of guessing an approval.
    func testActionWithMissingEventIdFallsBackToSession() {
        XCTAssertEqual(
            PushActionRouter.route(
                userInfo: ["type": "approval", "sessionId": "session-7"],
                actionIdentifier: "dshm.approval.allow"
            ),
            .fallback(sessionId: "session-7")
        )
        XCTAssertEqual(
            PushActionRouter.route(
                userInfo: ["type": "approval", "eventId": "", "sessionId": "session-7"],
                actionIdentifier: "dshm.approval.allow"
            ),
            .fallback(sessionId: "session-7")
        )
    }

    /// A category action on a non-approval payload is a stale/malformed
    /// notification: never answer it, fall back to the app.
    func testActionOnNonApprovalPayloadFallsBack() {
        XCTAssertEqual(
            PushActionRouter.route(
                userInfo: ["type": "question", "eventId": "q-1", "sessionId": "session-q"],
                actionIdentifier: "dshm.approval.deny"
            ),
            .fallback(sessionId: "session-q")
        )
    }

    /// Default tap behaviour is unchanged: deep-link to the payload's session.
    func testDefaultTapStillDeepLinks() {
        XCTAssertEqual(
            PushActionRouter.route(
                userInfo: ["type": "question", "sessionId": "session-tap"],
                actionIdentifier: UNNotificationDefaultActionIdentifier
            ),
            .deepLink(sessionId: "session-tap")
        )
        XCTAssertEqual(
            PushActionRouter.route(userInfo: [:], actionIdentifier: UNNotificationDefaultActionIdentifier),
            .deepLink(sessionId: nil)
        )
    }

    func testDismissActionIsIgnored() {
        XCTAssertEqual(
            PushActionRouter.route(
                userInfo: ["type": "approval", "eventId": "evt-1", "sessionId": "session-1"],
                actionIdentifier: UNNotificationDismissActionIdentifier
            ),
            .ignored
        )
    }

    /// The live pending waterfall wins (callId/reason/displayReason); a cold-launch
    /// decision falls back to the notification fields.
    func testDecisionBuildsWaterfallFromPendingCopy() {
        let pending = ApprovalWaterfall(
            eventId: "evt-1",
            agentId: "session-live",
            toolName: "bash",
            callId: "call-1",
            reason: "why",
            displayReason: "显示原因"
        )
        let decision = PushApprovalDecision(
            eventId: "evt-1",
            sessionId: "session-push",
            toolName: "tool",
            outcome: .allowedOnce
        )
        XCTAssertEqual(decision.waterfall(pending: [pending]), pending)

        let cold = decision.waterfall(pending: [])
        XCTAssertEqual(cold.eventId, "evt-1")
        XCTAssertEqual(cold.agentId, "session-push")
        XCTAssertEqual(cold.toolName, "tool")
        XCTAssertNil(cold.callId)
        XCTAssertNil(cold.reason)
    }

    /// Lead request (2026-10-21): E2E marker strings for the approval result.
    func testApprovalResultMarkerValues() {
        XCTAssertEqual(PushApprovalResult.sent(.allowedOnce).markerValue, "sent:allowed-once")
        XCTAssertEqual(PushApprovalResult.sent(.rejected).markerValue, "sent:rejected")
        XCTAssertEqual(PushApprovalResult.failed.markerValue, "failed")
    }

    func testPushActionInboxStoresAndDrainsRoutes() {
        let inbox = PushActionInbox()
        XCTAssertTrue(inbox.drain().isEmpty)

        let decision = PushApprovalDecision(
            eventId: "evt-1",
            sessionId: "session-1",
            toolName: "bash",
            outcome: .rejected
        )
        inbox.store(.approval(decision))
        inbox.store(.fallback(sessionId: "session-2"))

        XCTAssertEqual(inbox.drain(), [.approval(decision), .fallback(sessionId: "session-2")])
        XCTAssertTrue(inbox.drain().isEmpty)
    }

    /// Contract §3.5/§9: retry every 500ms for at most 8s.
    func testApprovalRetryPolicyDeadlineBoundary() {
        let policy = PushApprovalRetryPolicy()
        XCTAssertEqual(policy.retryInterval, 0.5)
        XCTAssertEqual(policy.deadline, 8)
        XCTAssertEqual(policy.retryDelayNanoseconds, 500_000_000)
        XCTAssertTrue(policy.shouldRetry(elapsed: 0))
        XCTAssertTrue(policy.shouldRetry(elapsed: 7.999))
        XCTAssertFalse(policy.shouldRetry(elapsed: 8))
        XCTAssertFalse(policy.shouldRetry(elapsed: 8.5))
    }

    /// Only readiness/transport failures are retried; Host business rejections
    /// (event already settled/expired) are final.
    func testApprovalRetryPolicyErrorEligibility() {
        XCTAssertTrue(PushApprovalRetryPolicy.canRetry(after: .notConnected))
        XCTAssertTrue(PushApprovalRetryPolicy.canRetry(after: .transport("stream closed")))
        XCTAssertTrue(PushApprovalRetryPolicy.canRetry(after: .timeout("$events")))
        XCTAssertFalse(PushApprovalRetryPolicy.canRetry(
            after: .remote(RemoteError(code: "events/result-unknown", message: "no such event"))
        ))
        XCTAssertFalse(PushApprovalRetryPolicy.canRetry(after: .httpStatus(400, "bad-request")))
        XCTAssertFalse(PushApprovalRetryPolicy.canRetry(after: .notPaired))
    }

    // MARK: - M4 §4: silent (content-available) push

    func testSilentPushEnvelopeParsesContentAvailable() {
        let envelope = SilentPushEnvelope(userInfo: [
            "aps": ["content-available": 1],
            "type": "sync",
            "reason": "approval",
            "sessionId": "session-silent",
            "eventId": "evt-silent",
        ])
        XCTAssertTrue(envelope.isSilent)
        XCTAssertEqual(envelope.reason, "approval")
        XCTAssertEqual(envelope.sessionId, "session-silent")
        XCTAssertEqual(envelope.eventId, "evt-silent")
        XCTAssertEqual(envelope.reasonKind, .approval)
        XCTAssertEqual(envelope.notificationUserInfo["reason"] as? String, "approval")
        XCTAssertEqual(envelope.notificationUserInfo["sessionId"] as? String, "session-silent")
    }

    /// Alert pushes must never be treated as silent refreshes (they only deep-link).
    func testAlertPushIsNotSilent() {
        let envelope = SilentPushEnvelope(userInfo: [
            "aps": ["alert": ["title": "DSH 回合完成", "body": "任务已在 Mac 上完成"], "sound": "default"],
            "type": "turn-end",
            "sessionId": "session-alert",
        ])
        XCTAssertFalse(envelope.isSilent)
    }

    /// Contract §4 also accepts a root-level `content-available: 1` (simctl
    /// fixtures / older senders); JSON `true` coerces to 1.
    func testSilentPushEnvelopeAcceptsRootContentAvailable() {
        XCTAssertTrue(SilentPushEnvelope(userInfo: ["content-available": true]).isSilent)
        XCTAssertTrue(SilentPushEnvelope(userInfo: ["content-available": 1]).isSilent)
        XCTAssertFalse(SilentPushEnvelope(userInfo: ["content-available": 2]).isSilent)
    }

    func testSilentPushReasonKindMapping() {
        func reasonKind(_ reason: String) -> PushNotificationPayload.Kind? {
            SilentPushEnvelope(userInfo: [
                "aps": ["content-available": 1],
                "reason": reason,
            ]).reasonKind
        }
        XCTAssertEqual(reasonKind("approval"), .approval)
        XCTAssertEqual(reasonKind("question"), .question)
        XCTAssertEqual(reasonKind("turn-end"), .turnEnd)
        XCTAssertEqual(reasonKind("failure"), .failure)
        XCTAssertNil(reasonKind("something-else"))
    }

    /// Contract §4: refreshes are throttled to ≥2s.
    func testSilentPushThrottleRejectsWithinTwoSeconds() {
        var throttle = SilentPushThrottle(minInterval: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.shouldAccept(now: start))
        XCTAssertFalse(throttle.shouldAccept(now: start.addingTimeInterval(1.999)))
        XCTAssertTrue(throttle.shouldAccept(now: start.addingTimeInterval(2)))
        XCTAssertFalse(throttle.shouldAccept(now: start.addingTimeInterval(3)))
        XCTAssertTrue(throttle.shouldAccept(now: start.addingTimeInterval(4.5)))
    }

    // MARK: - M4 §5: question notifications

    func testQuestionPayloadParsing() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": ["alert": ["title": "DSH 需要你的回答", "body": "有 2 个问题等待你回答"], "sound": "default"],
            "type": "question",
            "eventId": "evt-q",
            "sessionId": "session-q",
            "questionCount": 2,
        ])
        XCTAssertEqual(payload.kind, .question)
        XCTAssertEqual(payload.eventId, "evt-q")
        XCTAssertEqual(payload.sessionId, "session-q")
        XCTAssertEqual(payload.questionCount, 2)
        XCTAssertEqual(payload.shortDescription, "question")
        XCTAssertNil(payload.category)
    }

    /// Contract §2.1: only approval pushes carry `aps.category`; it must decode
    /// for the action routing / diagnostics.
    func testApprovalCategoryPassThrough() {
        let payload = PushNotificationPayload(userInfo: [
            "aps": [
                "alert": ["title": "DSH 需要审批", "body": "工具调用 bash 等待你的确认"],
                "category": "dshm-approval",
            ],
            "type": "approval",
            "eventId": "evt-1",
            "sessionId": "session-1",
        ])
        XCTAssertEqual(payload.kind, .approval)
        XCTAssertEqual(payload.category, "dshm-approval")
    }

    // MARK: - M4 §4: AppDelegate silent-push callback wiring

    /// `didReceiveRemoteNotification:fetchCompletionHandler:` must report
    /// `.newData` and post the internal notification for content-available pushes;
    /// alert pushes report `.noData` and post nothing.
    func testAppDelegateSilentPushCompletionAndInternalNotification() {
        let delegate = AppDelegate()
        var posted: [SilentPushEnvelope] = []
        let token = NotificationCenter.default.addObserver(
            forName: .dshmSilentPushReceived,
            object: nil,
            queue: nil
        ) { notification in
            if let envelope = notification.object as? SilentPushEnvelope {
                posted.append(envelope)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var silentResult: UIBackgroundFetchResult?
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "aps": ["content-available": 1],
                "type": "sync",
                "reason": "turn-end",
                "sessionId": "session-silent",
            ]
        ) { silentResult = $0 }
        XCTAssertEqual(silentResult, .newData)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.reasonKind, .turnEnd)
        XCTAssertEqual(posted.first?.sessionId, "session-silent")

        var alertResult: UIBackgroundFetchResult?
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "aps": ["alert": ["title": "DSH 回合完成", "body": "任务已在 Mac 上完成"]],
                "type": "turn-end",
            ]
        ) { alertResult = $0 }
        XCTAssertEqual(alertResult, .noData)
        XCTAssertEqual(posted.count, 1)
    }
}
