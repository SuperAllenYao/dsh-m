import Foundation

/// Resolves notification deep-link session ids to `session/follow` addresses.
///
/// Notifications carry only a session id (dsh-m-link `notifier.js` contract:
/// `{type, sessionId?, toolName?, eventId?}`). Subagent (Agent Teams teammate)
/// sessions must be opened through their durable parent address, so the id is
/// looked up in the most recently loaded `session/list` rows:
///
/// - found → that row's `followAddress` (plain or subagent, see task-3)
/// - not found → plain session address fallback. This happens when no list has
///   been loaded yet (cold launch straight from the notification) or when the
///   session was created after the last refresh; the Host then reports its own
///   business error instead of the app crashing (documented M1 limitation).
struct SessionDeepLinkResolver {
    private var addressesBySessionId: [String: SessionFollowAddress] = [:]

    init(sessions: [SessionListItem] = []) {
        update(sessions: sessions)
    }

    /// Replaces the lookup table with the freshest `session/list` rows.
    mutating func update(sessions: [SessionListItem]) {
        var addresses: [String: SessionFollowAddress] = [:]
        for session in sessions {
            addresses[session.sessionId] = session.followAddress
        }
        addressesBySessionId = addresses
    }

    /// Number of session ids currently resolvable (diagnostics/tests).
    var knownSessionCount: Int { addressesBySessionId.count }

    /// Address used to open a deep-linked session id.
    func address(for sessionId: String) -> SessionFollowAddress {
        addressesBySessionId[sessionId] ?? .session(sessionId: sessionId)
    }
}
