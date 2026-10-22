import Foundation

/// P1.5-A: opt-in for the plugin's "lite" `session/list` projection trim.
///
/// The full `session/list` response is ~1 MB on a busy host because every row
/// carries the complete projection block (turnOutline / todos / subagentCatalog
/// / …). The list only renders a subset; detail state arrives through
/// `session/follow`. The plugin trims the projection block **only** when the
/// client explicitly asks for it (old clients keep the byte-identical legacy
/// response).
///
/// Wire contract (plugin: `packages/dsh-m-link/lib/list-lite.js`):
/// - Preferred transport signal: request header `x-dshm-list-lite: 1`.
/// Not available today: `Net/` is frozen (P1 transport final), and the legacy
/// `HTTPSClient` / `rpc` frame builders do not take per-request headers.
/// - Interim signal used by this App: the legacy-shaped body hint
/// `payload.args._request.listMode = "lite"`. The plugin strips the hint
/// before forwarding, so the upstream DSH request stays byte-identical.
///
/// The plugin keeps: `sessionId, updatedAt, agentAvailable, formatStatus,
/// running, blank, cwd, origin, parentSessionId` plus
/// `projections.values.{title, sessionListMetadata, userQuestions.active,
/// contextPressure}`. `SessionListItem` decodes all of them as optionals, so a
/// lite response and a full response decode through the same path.
enum SessionListLite {
 /// Key/value of the interim body hint consumed by the plugin.
    static let requestKey = "listMode"
    static let requestValue = "lite"

 /// Plugin response marker (legacy path only); useful for E2E diagnostics.
    static let responseHeader = "x-dshm-list-lite"

 /// Unary args for one lite `session/list` request.
    static func requestArgs() -> [String: JSONValue] {
        ["_request": .object([requestKey: .string(requestValue)])]
    }
}
