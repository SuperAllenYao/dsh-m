import Foundation

// MARK: - Session actions: create / pin / archive (R2 + R3, design §2.2 & §3.2)
//
// Three device-authenticated plugin routes, one shared transport helper with
// the exact setSessionPermission shape: bearer api token, one silent refresh
// retry on a plain 401 (never on auth/revoked), JSON error envelope mapped to
// LinkError.remote with localized text from SessionActionErrorText.

/// POST /session/create success body.
struct SessionCreateResult: Decodable, Equatable, Sendable {
    var ok: Bool
    var sessionId: String
    var reused: Bool

    init(ok: Bool = true, sessionId: String, reused: Bool) {
        self.ok = ok
        self.sessionId = sessionId
        self.reused = reused
    }
}

/// POST /session/pin success body (complete pin set, newest pin first).
struct SessionPinResult: Decodable, Equatable, Sendable {
    var ok: Bool
    var pinnedSessionIds: [String]

    init(ok: Bool = true, pinnedSessionIds: [String]) {
        self.ok = ok
        self.pinnedSessionIds = pinnedSessionIds
    }
}

/// POST /session/archive success body (complete archive set).
struct SessionArchiveResult: Decodable, Equatable, Sendable {
    var ok: Bool
    var archivedSessionIds: [String]

    init(ok: Bool = true, archivedSessionIds: [String]) {
        self.ok = ok
        self.archivedSessionIds = archivedSessionIds
    }
}

/// Localized text for the three routes' error codes (mirrors
/// PermissionSwitchErrorText: a known code always reads the same, the host
/// message only shows for unrecognized codes).
enum SessionActionErrorText {
 /// True when the failure is a plain 404 from a plugin too old to know the
 /// route — the one case the App must explain as "upgrade the Mac plugin".
    static func isPluginUpgradeRequired(status: Int, code: String) -> Bool {
        status == 404 && code.isEmpty
    }

    static func createMessage(forCode code: String, serverMessage: String? = nil) -> String {
        switch code {
        case "session-create/workspace-not-found":
            return L10n.t("工作区不存在，请返回列表刷新")
        case "session-create/host-unavailable":
            return L10n.t("Mac 端不支持此操作")
        case "session-create/bad-request":
            return L10n.t("新建会话请求被拒绝（参数非法）")
        default:
            return nonEmpty(serverMessage) ?? L10n.t("新建会话失败，请重试")
        }
    }

    static func pinMessage(forCode code: String, serverMessage: String? = nil) -> String {
        switch code {
        case "pin/session-not-found":
            return L10n.t("会话不存在或已结束，请返回列表刷新")
        case "pin/host-unavailable":
            return L10n.t("Mac 端不支持此操作")
        default:
            return nonEmpty(serverMessage) ?? L10n.t("置顶操作失败，请重试")
        }
    }

    static func archiveMessage(forCode code: String, serverMessage: String? = nil) -> String {
        switch code {
        case "archive/session-not-found":
            return L10n.t("会话不存在，列表即将同步")
        case "archive/host-unavailable":
            return L10n.t("Mac 端不支持此操作")
        default:
            return nonEmpty(serverMessage) ?? L10n.t("归档失败，请重试")
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

extension LinkService {
 /// Shared transport for the three session-action routes. Returns the raw
 /// (status, json); callers decode their own success body.
    private func postSessionAction(path: String, body: JSONValue, timeout: TimeInterval) async throws -> (Int, JSONValue) {
        guard let credentials, let origin = credentials.originURL else { throw LinkError.notPaired }
        let revokedText = L10n.t("设备已被撤销，请重新配对")

        func attempt(_ apiToken: String) async throws -> (Int, JSONValue) {
            let result = try await HTTPSClient.json(
                origin: origin,
                method: "POST",
                path: path,
                headers: ["authorization": "Bearer \(apiToken)"],
                body: body,
                leafPin: credentials.leafPin,
                caCertBase64: credentials.caCertBase64,
                timeout: timeout
            )
            return (result.status, result.json)
        }

        var apiToken = try await ensureAPIToken()
        var (status, json) = try await attempt(apiToken)
 // auth/revoked must not be retried (the device is blacklisted: re-pair).
        if status == 401, json["error"]?.stringValue == "auth/revoked" {
            throw LinkError.remote(RemoteError(code: "auth/revoked", message: revokedText))
        }
        if status == 401 {
            apiToken = try await ensureAPIToken(forceRefresh: true)
            (status, json) = try await attempt(apiToken)
            if status == 401, json["error"]?.stringValue == "auth/revoked" {
                throw LinkError.remote(RemoteError(code: "auth/revoked", message: revokedText))
            }
        }
        return (status, json)
    }

 /// Map a non-200 answer onto the shared error shape. A plain 404 without a
 /// JSON error code is the old-plugin case → dedicated upgrade text.
    private static func actionError(
        status: Int, json: JSONValue, fallbackCode: String, message: String
    ) -> LinkError {
        let code = json["error"]?.stringValue ?? ""
        if SessionActionErrorText.isPluginUpgradeRequired(status: status, code: code) {
            return LinkError.remote(RemoteError(
                code: "plugin/upgrade-required",
                message: L10n.t("Mac 端 dsh-m-link 插件需升级后可用")
            ))
        }
        let effectiveCode = code.isEmpty ? fallbackCode : code
        return LinkError.remote(RemoteError(code: effectiveCode, message: message))
    }

    private static func decodeBody<T: Decodable>(
        _ type: T.Type, json: JSONValue, route: String
    ) throws -> T {
        do {
            return try json.decode(type)
        } catch {
            throw LinkError.malformedEnvelope(
                L10n.f("%@ 响应解析失败: %@", route, error.localizedDescription)
            )
        }
    }

 /// POST /session/create — mint (or reuse a blank) session in one workspace.
    func createSession(workspaceId: String, timeout: TimeInterval = 20) async throws -> SessionCreateResult {
        let (status, json) = try await postSessionAction(
            path: "/session/create",
            body: .object(["workspaceId": .string(workspaceId)]),
            timeout: timeout
        )
        if status == 200 {
            let result = try Self.decodeBody(SessionCreateResult.self, json: json, route: "session/create")
            guard result.ok else {
                throw LinkError.remote(RemoteError(
                    code: "session-create/failed",
                    message: SessionActionErrorText.createMessage(forCode: "session-create/failed")
                ))
            }
            return result
        }
        let code = json["error"]?.stringValue ?? ""
        throw Self.actionError(
            status: status, json: json, fallbackCode: "session-create/failed",
            message: SessionActionErrorText.createMessage(forCode: code, serverMessage: json["message"]?.stringValue)
        )
    }

 /// POST /session/pin — pin or unpin one session; the answer carries the
 /// complete pin set so the caller can reconcile its optimistic copy.
    func pinSession(sessionId: String, pinned: Bool, timeout: TimeInterval = 15) async throws -> SessionPinResult {
        let (status, json) = try await postSessionAction(
            path: "/session/pin",
            body: .object(["sessionId": .string(sessionId), "pinned": .bool(pinned)]),
            timeout: timeout
        )
        if status == 200 {
            let result = try Self.decodeBody(SessionPinResult.self, json: json, route: "session/pin")
            guard result.ok else {
                throw LinkError.remote(RemoteError(
                    code: "pin/failed",
                    message: SessionActionErrorText.pinMessage(forCode: "pin/failed")
                ))
            }
            return result
        }
        let code = json["error"]?.stringValue ?? ""
        throw Self.actionError(
            status: status, json: json, fallbackCode: "pin/failed",
            message: SessionActionErrorText.pinMessage(forCode: code, serverMessage: json["message"]?.stringValue)
        )
    }

 /// POST /session/archive — archive one session. A 409 archive/session-active
 /// means the session still runs work (R3 shows the stop-and-archive
 /// confirmation); a 404 means the desktop already removed/archived it.
    func archiveSession(
        sessionId: String,
        stopActivity: Bool,
        timeout: TimeInterval = 20
    ) async throws -> SessionArchiveResult {
        let (status, json) = try await postSessionAction(
            path: "/session/archive",
            body: .object(["sessionId": .string(sessionId), "stopActivity": .bool(stopActivity)]),
            timeout: timeout
        )
        if status == 200 {
            let result = try Self.decodeBody(SessionArchiveResult.self, json: json, route: "session/archive")
            guard result.ok else {
                throw LinkError.remote(RemoteError(
                    code: "archive/failed",
                    message: SessionActionErrorText.archiveMessage(forCode: "archive/failed")
                ))
            }
            return result
        }
        let code = json["error"]?.stringValue ?? ""
        throw Self.actionError(
            status: status, json: json, fallbackCode: "archive/failed",
            message: SessionActionErrorText.archiveMessage(forCode: code, serverMessage: json["message"]?.stringValue)
        )
    }
}
