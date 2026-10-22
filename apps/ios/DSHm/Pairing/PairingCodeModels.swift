import Foundation

/// Eight-digit pairing code input state machine (M2a design §5.1).
///
/// The field accepts arbitrary text (keyboard, paste, one-time-code autofill);
/// everything but ASCII digits is dropped and the value is capped at 8 digits.
/// `update` reports the transition into the complete state so the view can
/// auto-submit exactly once, without retriggering on every later keystroke.
struct PairingCodeInput: Equatable {
    static let length = 8

    private(set) var digits: String = ""

    var isComplete: Bool { digits.count == Self.length }
    var isEmpty: Bool { digits.isEmpty }
    var canSubmit: Bool { isComplete }

 /// Display form with the desktop UI's `1234 5678` grouping.
    var grouped: String {
        guard digits.count > 4 else { return digits }
        let head = digits.prefix(4)
        let tail = digits.dropFirst(4)
        return String(head) + " " + String(tail)
    }

 /// Sanitizes `text` and returns true when this change completed the code.
    @discardableResult
    mutating func update(_ text: String) -> Bool {
        let wasComplete = isComplete
        let filtered = String(text.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.prefix(Self.length))
        digits = filtered
        return !wasComplete && isComplete
    }

    mutating func clear() {
        digits = ""
    }
}

/// User-facing pairing-code failure (design §5.2 redeem + §5.4 lookup mapping).
enum PairingCodeFailure: Equatable {
 /// `code/invalid` (HTTP 401); `remaining` is the Mac-reported attempts left.
    case invalid(remaining: Int?)
 /// `code/expired` (HTTP 410).
    case expired
 /// `code/locked` (HTTP 423): 5 wrong attempts, the code is void.
    case locked
 /// `code/rate-limited` / `rate-limited` (HTTP 429).
    case rateLimited
 /// Relay lookup `code/not-found` (HTTP 404): wrong code or Mac not online.
    case notFound
 /// `host/inactive` (HTTP 503): the Mac plugin is not reachable.
    case hostInactive
 /// `contract/pending` (HTTP 503): the Mac plugin is still starting.
    case contractPending
 /// No discovered Mac and no relay server configured.
    case noTarget
 /// Several Macs were discovered; the user must choose one first.
    case selectionRequired
 /// The Mac/relay answered with a shape the app cannot trust.
    case malformed(String)
 /// Handshake pin / response pin / payload pin disagree (§5.3 step 4).
    case pinMismatch(String)
 /// The signed pairing payload embedded in the redeem response failed Ed25519.
    case signatureInvalid
 /// Transport-level failure (localized by `NetworkErrorInterpreter`).
    case network(String)

 /// Whether the eight digits should stay in the field after this failure.
    var keepsCode: Bool {
        switch self {
        case .invalid, .rateLimited, .network, .noTarget, .selectionRequired,
             .notFound, .hostInactive, .contractPending:
            return true
        case .expired, .locked, .malformed, .pinMismatch, .signatureInvalid:
            return false
        }
    }

    var message: String {
        switch self {
        case .invalid(let remaining):
            if let remaining {
                return L10n.f("配对码不正确，还剩 %lld 次机会", remaining)
            }
            return L10n.t("配对码不正确")
        case .expired:
            return L10n.t("配对码已过期，请在 Mac 上刷新配对码")
        case .locked:
            return L10n.t("配对码输错次数过多，已作废；请在 Mac 上刷新配对码")
        case .rateLimited:
            return L10n.t("配对尝试过于频繁，请稍后再试")
        case .notFound:
            return L10n.t("配对码无效，或 Mac 未连接服务器")
        case .hostInactive:
            return L10n.t("Mac 上的连接服务未就绪，请稍后重试")
        case .contractPending:
            return L10n.t("Mac 上的连接服务正在启动，请稍后重试")
        case .noTarget:
            return L10n.t("未发现 Mac：请确认 iPhone 与 Mac 在同一 Wi-Fi，或在 Mac 上刷新配对码；也可以先配置远程服务器")
        case .selectionRequired:
            return L10n.t("发现多台 Mac，请先选择要配对的一台")
        case .malformed(let detail):
            return L10n.f("配对响应格式不正确：%@", detail)
        case .pinMismatch(let detail):
            return L10n.f("证书指纹校验失败，已拒绝连接：%@", detail)
        case .signatureInvalid:
            return L10n.t("配对载荷签名校验失败（载荷可能被篡改）")
        case .network(let detail):
            return detail
        }
    }
}

/// Error wrapper carrying the display failure out of the redeem layer.
struct PairingCodeError: Error, Equatable, LocalizedError {
    var failure: PairingCodeFailure

    init(_ failure: PairingCodeFailure) {
        self.failure = failure
    }

    var errorDescription: String? { failure.message }
}

/// Maps `/pair/code/redeem` and `/v1/lookup` HTTP envelopes to display failures.
enum PairingCodeErrorMapper {
    static func redeemFailure(status: Int, json: JSONValue) -> PairingCodeFailure {
        let code = json["error"]?.stringValue ?? ""
        switch code {
        case "code/invalid":
            return .invalid(remaining: json["remaining"]?.intValue.map(Int.init))
        case "code/expired":
            return .expired
        case "code/locked":
            return .locked
        case "code/rate-limited":
            return .rateLimited
        case "host/inactive":
            return .hostInactive
        case "contract/pending":
            return .contractPending
        default:
            break
        }
 // Fall back to the documented status-code contract when `error` is
 // missing or uses a newer enum value.
        switch status {
        case 401:
            return .invalid(remaining: json["remaining"]?.intValue.map(Int.init))
        case 410:
            return .expired
        case 423:
            return .locked
        case 429:
            return .rateLimited
        case 503:
            return .hostInactive
        default:
            let message = json["message"]?.stringValue ?? code
            return .malformed("HTTP \(status)" + (message.isEmpty ? "" : " · " + message))
        }
    }

    static func lookupFailure(status: Int, json: JSONValue) -> PairingCodeFailure {
        let code = json["error"]?.stringValue ?? ""
        switch code {
        case "code/not-found":
            return .notFound
        case "code/expired":
            return .expired
        case "rate-limited", "code/rate-limited":
            return .rateLimited
        case "host/inactive":
            return .hostInactive
        default:
            break
        }
        switch status {
        case 404:
            return .notFound
        case 410:
            return .expired
        case 429:
            return .rateLimited
        case 503:
            return .hostInactive
        default:
            let message = json["message"]?.stringValue ?? code
            return .malformed("HTTP \(status)" + (message.isEmpty ? "" : " · " + message))
        }
    }
}

/// Submission phase used by the code-entry view (idle -> submitting -> failed).
enum PairingCodeSubmissionPhase: Equatable {
    case idle
    case submitting
    case failed(PairingCodeFailure)

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }

    var failure: PairingCodeFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
