import Foundation

// MARK: - Session permission preset catalog (M5)

/// One selectable permission preset of a session (`permissions.currentValue`).
///
/// Wire shape shared by the read-only `permissionPresets/catalog` unary method and
/// the `catalog` block of a successful `POST /session/permission`:
/// `{value, name, description?}`. `description` is optional in the contract.
struct PermissionPresetOption: Decodable, Equatable, Identifiable, Sendable {
    var value: String
    var name: String
    var description: String?

    var id: String { value }

    init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case name
        case description
    }

 /// Tolerant decode: `description` may be missing/null, and a `name`-less entry
 /// falls back to the raw value so the row stays selectable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        let decodedName = (try? container.decode(String.self, forKey: .name)) ?? ""
        name = decodedName.isEmpty ? value : decodedName
        description = try? container.decode(String.self, forKey: .description)
    }
}

/// Catalog of selectable presets: `permissionPresets/catalog` (read-only remote
/// unary proxy) and the `catalog` member of `POST /session/permission`.
struct PermissionPresetCatalog: Decodable, Equatable, Sendable {
    var options: [PermissionPresetOption]
    var defaultPreset: String?

    init(options: [PermissionPresetOption] = [], defaultPreset: String? = nil) {
        self.options = options
        self.defaultPreset = defaultPreset
    }

    private enum CodingKeys: String, CodingKey {
        case options
        case defaultPreset
    }

 /// Tolerant decode: a catalog without a usable `options` array degrades to an
 /// empty list (the sheet then keeps its read-only fallback row instead of
 /// failing the whole catalog).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = (try? container.decode([PermissionPresetOption].self, forKey: .options)) ?? []
        defaultPreset = try? container.decode(String.self, forKey: .defaultPreset)
    }
}

/// 200 body of `POST /session/permission`:
/// `{ok, sessionId, preset, previous, catalog}`.
struct SessionPermissionUpdate: Decodable, Equatable, Sendable {
    var ok: Bool
    var sessionId: String?
    var preset: String
    var previous: String?
    var catalog: PermissionPresetCatalog

    init(
        ok: Bool = true,
        sessionId: String? = nil,
        preset: String,
        previous: String? = nil,
        catalog: PermissionPresetCatalog = PermissionPresetCatalog()
    ) {
        self.ok = ok
        self.sessionId = sessionId
        self.preset = preset
        self.previous = previous
        self.catalog = catalog
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case sessionId
        case preset
        case previous
        case catalog
    }

 /// Tolerant decode: the host always sends `ok`/`preset`, but a missing
 /// `catalog` (or a null one) must not fail the successful switch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(Bool.self, forKey: .ok)) ?? false
        sessionId = try? container.decode(String.self, forKey: .sessionId)
        preset = (try? container.decode(String.self, forKey: .preset)) ?? ""
        previous = try? container.decode(String.self, forKey: .previous)
        catalog = (try? container.decode(PermissionPresetCatalog.self, forKey: .catalog))
            ?? PermissionPresetCatalog()
    }
}

// MARK: - Catalog read

extension LinkService {
 /// Reads the selectable preset catalog through the existing read-only remote
 /// unary proxy (endpoint `permissionPresets/catalog`, args `{}`, file-route
 /// style response `{options:[{value,name,description?}], defaultPreset}`).
    func permissionPresetCatalog() async throws -> PermissionPresetCatalog {
        let value = try await unary("permissionPresets/catalog", args: [:])
        do {
            return try value.decode(PermissionPresetCatalog.self)
        } catch {
            throw LinkError.malformedEnvelope(
                L10n.f("permissionPresets/catalog 响应解析失败: %@", error.localizedDescription)
            )
        }
    }
}

// MARK: - Error text mapping

/// User-facing text for the M5 `POST /session/permission` failures.
///
/// Pure by design so the mapping is unit-tested without a live plugin/host and the
/// App never shows a raw `code: message` pair for known codes. Keys mirror the
/// plugin contract (`permission/*`, `auth/*`).
enum PermissionSwitchErrorText {
 /// Maps one plugin error code to localized text. The host-provided `message`
 /// is only used for the generic/unrecognized codes, so a known code always
 /// reads the same in the App.
    static func message(forCode code: String, serverMessage: String? = nil) -> String {
        switch code {
        case "auth/required", "auth/invalid", "auth/token-expired":
            return L10n.t("设备认证已失效，请重新配对后重试")
        case "auth/revoked":
 // Same wording as push-token registration: no retry, re-pair.
            return L10n.t("设备已被撤销，请重新配对")
        case "permission/bad-request":
            return L10n.t("权限切换请求被拒绝（参数非法）")
        case "permission/session-not-found":
            return L10n.t("会话不存在或已结束，请返回列表刷新")
        case "permission/preset-unavailable":
            return L10n.t("该权限预设当前不可用")
        case "permission/host-unavailable":
            return L10n.t("桌面端未就绪，请稍后重试")
        case "permission/failed":
            return nonEmpty(serverMessage) ?? L10n.t("权限切换失败，请重试")
        default:
            return nonEmpty(serverMessage) ?? L10n.t("权限切换失败，请重试")
        }
    }

 /// Display bridge for any error thrown by the preset switch (business error,
 /// transport loss or an unrecognized host failure).
    static func message(for error: Error) -> String {
        if let linkError = error as? LinkError, case .remote(let remote) = linkError {
            return message(forCode: remote.code, serverMessage: remote.message)
        }
        return NetworkErrorInterpreter.message(for: error)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
