import Foundation

/// APNs payload contract from dsh-m-link `notifier.js`:
/// `{ type: "approval"|"question"|"turn-end"|"failure"|"test"|"apns-test",
///    toolName?, eventId?, sessionId?, questionCount?, aps: { category? } }`.
/// Notifications never contain message bodies or tool output.
///
/// Where those custom keys live depends on the sender version:
/// - dsh-m-link >= 2026-10-21 release hardening puts them at the **payload root**
///   (`packages/dsh-m-link/lib/apns.js`: `buildApnsPayload()` → `{aps, ...data}`),
/// - older dsh-m-link builds nested them inside `aps` under `"dsh-m"`
///   (kept for compatibility with any build pinned before that change),
/// - `xcrun simctl push` fixtures put them at the root.
/// Decode every shape, otherwise a tapped real-device notification cannot
/// deep-link (2026-10-21: root-only decode silently produced an empty sessionId).
struct PushNotificationPayload: Equatable {
    enum Kind: String {
        case approval
        case question
        case turnEnd = "turn-end"
        case failure
        case test
        case apnsTest = "apns-test"
        case unknown
    }

    var kind: Kind
    var sessionId: String?
    var toolName: String?
    var eventId: String?
    /// `aps.category` — only approval pushes carry `dshm-approval` (M4 §2.1/§3).
    var category: String?
    /// Number of questions bundled in a `question` notification (body copy only:
    /// the app deep-links to the session and the existing card collects answers).
    var questionCount: Int?

    init(userInfo: [AnyHashable: Any]) {
        let rawType = pushPayloadValue("type", in: userInfo) as? String ?? ""
        kind = Kind(rawValue: rawType) ?? .unknown
        sessionId = pushPayloadValue("sessionId", in: userInfo) as? String
        toolName = pushPayloadValue("toolName", in: userInfo) as? String
        eventId = pushPayloadValue("eventId", in: userInfo) as? String
        questionCount = pushPayloadInt(pushPayloadValue("questionCount", in: userInfo))
        // `category` is a system key inside `aps` (never a custom root key), but
        // simctl fixtures occasionally keep it at the root; accept both.
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        category = (aps?["category"] as? String) ?? (userInfo["category"] as? String)
    }

    var shortDescription: String {
        switch kind {
        case .approval: return "approval · " + (toolName ?? "tool")
        case .question: return "question"
        case .turnEnd: return "turn-end"
        case .failure: return "failure"
        case .test, .apnsTest: return "test"
        case .unknown: return "notification"
        }
    }
}

/// Background/silent push (`aps: {"content-available": 1}`, M4 §2.2/§4).
///
/// The payload only hints at *what* changed (`reason`) and *where*
/// (`sessionId`); the app uses it to pre-warm list/detail data. It must never
/// approve or answer anything by itself.
struct SilentPushEnvelope: Equatable {
    var isSilent: Bool
    var reason: String?
    var sessionId: String?
    var eventId: String?

    init(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let contentAvailable = pushPayloadInt(aps?["content-available"])
            ?? pushPayloadInt(userInfo["content-available"])
        isSilent = contentAvailable == 1
        reason = pushPayloadValue("reason", in: userInfo) as? String
        sessionId = pushPayloadValue("sessionId", in: userInfo) as? String
        eventId = pushPayloadValue("eventId", in: userInfo) as? String
    }

    /// Silent `reason` shares the alert-payload vocabulary
    /// (`approval` / `question` / `turn-end` / `failure` / `test`).
    var reasonKind: PushNotificationPayload.Kind? {
        reason.flatMap(PushNotificationPayload.Kind.init(rawValue:))
    }

    /// userInfo attached to the internal `.dshmSilentPushReceived` notification
    /// (reason/sessionId, M4 §4).
    var notificationUserInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let reason { info["reason"] = reason }
        if let sessionId { info["sessionId"] = sessionId }
        if let eventId { info["eventId"] = eventId }
        return info
    }
}

/// Looks up a custom payload key across the three sender shapes:
/// `aps["dsh-m"]` (legacy) > `root["dsh-m"]` (intermediate) > root (current).
private func pushPayloadValue(_ key: String, in userInfo: [AnyHashable: Any]) -> Any? {
    let aps = userInfo["aps"] as? [AnyHashable: Any]
    let nested = (aps?["dsh-m"] as? [AnyHashable: Any]) ?? (userInfo["dsh-m"] as? [AnyHashable: Any])
    if let nestedValue = nested?[key] { return nestedValue }
    return userInfo[key]
}

/// Coerces APNs/JSON numeric values (`CFBoolean`, `NSNumber`, `Int`, numeric
/// strings). APNs delivers JSON numbers/bools as `NSNumber`; simctl fixtures and
/// unit-test literals may use Swift `Int`/`Bool`.
private func pushPayloadInt(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if let bool = value as? Bool { return bool ? 1 : 0 }
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

enum PushTokenFormatter {
    /// Hex string (lowercase, no separators) as expected by the link plugin.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
