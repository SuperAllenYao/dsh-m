import Foundation
import UserNotifications

/// Notification actions attached to the approval category (M4 §3).
///
/// Both actions require the device to be unlocked before iOS delivers the
/// response (decision,: an approval action is only executed after
/// unlock); deny carries the same requirement for consistency and adds
/// `.destructive` so it is styled red.
enum PushApprovalAction: String, CaseIterable {
    case allow = "dshm.approval.allow"
    case deny = "dshm.approval.deny"

    var title: String {
        switch self {
        case .allow: return L10n.t("允许")
        case .deny: return L10n.t("拒绝")
        }
    }

    var options: UNNotificationActionOptions {
        switch self {
        case .allow: return [.authenticationRequired]
        case .deny: return [.authenticationRequired, .destructive]
        }
    }

 /// `$events/result` outcome: only `allowed-once` permits the tool;
 /// `rejected` fails closed (protocol §3.7).
    var outcome: ApprovalOutcome {
        switch self {
        case .allow: return .allowedOnce
        case .deny: return .rejected
        }
    }
}

/// One approval decision taken from a notification action response.
struct PushApprovalDecision: Equatable {
    var eventId: String
    var sessionId: String?
    var toolName: String?
    var outcome: ApprovalOutcome

 /// Waterfall passed to `LinkService.respondApproval`. The live pending copy
 /// wins (it carries callId/reason/displayReason); a cold-launch decision falls
 /// back to the notification fields, which already contain the eventId the
 /// unary `$events/result` answer needs.
    func waterfall(pending: [ApprovalWaterfall]) -> ApprovalWaterfall {
        if let live = pending.first(where: { $0.eventId == eventId }) {
            return live
        }
        return ApprovalWaterfall(
            eventId: eventId,
            agentId: sessionId,
            toolName: toolName,
            callId: nil,
            reason: nil,
            displayReason: nil
        )
    }
}

/// Routed result of one `UNNotificationResponse` — the future work of
/// `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`.
enum PushApprovalRoute: Equatable {
 /// Allow/deny action with a usable eventId; answered from the background.
    case approval(PushApprovalDecision)
 /// Allow/deny action whose payload cannot be answered (missing/empty eventId,
 /// or the notification is not an approval): toast + open the session so the
 /// user decides in the app. Never guess an approval.
    case fallback(sessionId: String?)
 /// Default tap: keep the existing deep link to the session.
    case deepLink(sessionId: String?)
 /// Dismiss / unrelated action: nothing to do.
    case ignored
}

/// E2E-visible outcome of one notification-action approval:
/// `"sent:allowed-once"` / `"sent:rejected"` / `"failed"`. Product UI never shows
/// it; `RootView` exposes it only through a hidden accessibility element when
/// `DSHM_E2E=1`.
enum PushApprovalResult: Equatable {
    case sent(ApprovalOutcome)
    case failed

    var markerValue: String {
        switch self {
        case .sent(let outcome): return "sent:" + outcome.rawValue
        case .failed: return "failed"
        }
    }
}

/// Pure routing/mapping used by the app delegate and the unit tests.
enum PushActionRouter {
    static let approvalCategoryIdentifier = "dshm-approval"

 /// `UNNotificationCategory` registered at launch. Category options stay empty
 /// (M4 §3: no `.customDismissAction` etc.).
    static func makeApprovalCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: approvalCategoryIdentifier,
            actions: PushApprovalAction.allCases.map(makeAction),
            intentIdentifiers: [],
            options: []
        )
    }

    static func makeAction(_ action: PushApprovalAction) -> UNNotificationAction {
        UNNotificationAction(identifier: action.rawValue, title: action.title, options: action.options)
    }

 /// `actionIdentifier` -> outcome (only our two actions; everything else nil).
    static func approvalOutcome(forActionIdentifier identifier: String) -> ApprovalOutcome? {
        PushApprovalAction(rawValue: identifier)?.outcome
    }

 /// Maps one notification response to the work the app must do.
    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> PushApprovalRoute {
        if let outcome = approvalOutcome(forActionIdentifier: actionIdentifier) {
            return approvalRoute(userInfo: userInfo, outcome: outcome)
        }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            return .deepLink(sessionId: PushNotificationPayload(userInfo: userInfo).sessionId)
        }
        return .ignored
    }

    private static func approvalRoute(
        userInfo: [AnyHashable: Any],
        outcome: ApprovalOutcome
    ) -> PushApprovalRoute {
        let payload = PushNotificationPayload(userInfo: userInfo)
 // Only approval notifications are answerable. Anything else is a stale or
 // malformed category: fall back instead of answering an event we never saw.
        guard payload.kind == .approval else {
            return .fallback(sessionId: payload.sessionId)
        }
 // Without an eventId the `$events/result` answer cannot address the
 // waterfall; treat it as invalid and fall back to the app (M4 §3.2).
        guard let eventId = payload.eventId, !eventId.isEmpty else {
            return .fallback(sessionId: payload.sessionId)
        }
        return .approval(PushApprovalDecision(
            eventId: eventId,
            sessionId: payload.sessionId,
            toolName: payload.toolName,
            outcome: outcome
        ))
    }
}

/// In-process parking slot for notification-action routes. UIKit can deliver the
/// action response before SwiftUI builds `AppModel` (`@StateObject` is created
/// with the first scene), e.g. when iOS launches the app in the background from a
/// locked-screen action. The delegate stores the route before posting the
/// internal notification; `AppModel` drains the slot at init. The normal
/// NotificationCenter path stays primary — this only closes the cold-launch race.
final class PushActionInbox {
    static let shared = PushActionInbox()

    private let lock = NSLock()
    private var routes: [PushApprovalRoute] = []

    func store(_ route: PushApprovalRoute) {
        lock.lock()
        defer { lock.unlock() }
        routes.append(route)
    }

    func drain() -> [PushApprovalRoute] {
        lock.lock()
        defer { lock.unlock() }
        let drained = routes
        routes.removeAll()
        return drained
    }
}

/// In-process parking slot for a notification **tap** deep link.
///
/// UIKit delivers `didReceive response` during launch, before SwiftUI builds
/// `AppModel` (`@StateObject` is created with the first scene). The posted
/// `.dshmPushNotificationTapped` would therefore be lost, and the app would keep
/// its default `.workspaces` route — the "tap lands on the workspace list"
/// regression. The delegate stores the session id here before posting;
/// `AppModel.init` drains it once the model exists and routes to the session.
final class PushDeepLinkInbox {
    static let shared = PushDeepLinkInbox()

    private let lock = NSLock()
    private var pending: String?
 /// Once AppModel is alive the live NotificationCenter path is authoritative;
 /// storing late taps would replay a stale session on the next cold launch.
    private var appModelIsLive = false

    func markLive() {
        lock.lock()
        defer { lock.unlock() }
        appModelIsLive = true
    }

 /// Stores a tap that arrives before AppModel exists; later taps are ignored
 /// here because the live publisher handles them.
    func store(_ sessionId: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !appModelIsLive else { return }
        guard let sessionId, !sessionId.isEmpty else { return }
        pending = sessionId
    }

 /// Returns the parked session id (if any) and clears the slot.
    func drain() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }

 /// Unit-test seam: a process-wide singleton must not leak state between cases.
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
        appModelIsLive = false
    }
}

/// ≥2s throttle for background (silent) push refreshes. `session/list` returns
/// every session's projections (hundreds of KB) and the plugin
/// already coalesces silent pushes per device for 3s; the app still guards on its
/// own so a burst of simulated pushes cannot turn into a refresh storm.
struct SilentPushThrottle: Equatable {
    let minInterval: TimeInterval
    private(set) var lastAcceptedAt: Date?

    init(minInterval: TimeInterval = 2) {
        self.minInterval = minInterval
    }

    mutating func shouldAccept(now: Date = Date()) -> Bool {
        if let last = lastAcceptedAt, now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastAcceptedAt = now
        return true
    }
}

/// Bounded retry for a notification-action approval. When iOS launches the app in
/// the background from an action, the `$events` stream may still be opening and
/// `clientId` (required by `$events/result`) is not ready yet: retry every 500ms
/// for at most 8s, then fall back to opening the session (M4 §3.5 / §9).
struct PushApprovalRetryPolicy: Equatable {
    var retryInterval: TimeInterval = 0.5
    var deadline: TimeInterval = 8

    func shouldRetry(elapsed: TimeInterval) -> Bool {
        elapsed < deadline
    }

    var retryDelayNanoseconds: UInt64 {
        UInt64(retryInterval * 1_000_000_000)
    }

 /// Only readiness/transport failures are worth retrying. A remote business
 /// error means the Host already settled/refused the event (answered
 /// elsewhere, expired, unknown eventId): retrying cannot succeed.
    static func canRetry(after error: LinkError) -> Bool {
        switch error {
        case .notConnected, .transport, .timeout:
            return true
        default:
            return false
        }
    }
}
