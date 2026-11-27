import Foundation
import UniformTypeIdentifiers

/// Fetches image-file bytes for the full-screen preview.
///
/// DD-02 image byte channel: `workspaceFiles/stat` first, then a binary exact
/// GET of `/api/file?path=<absolutePath>&v=<version>`. Bytes are never cached
/// (design §4): every `load` re-stats and re-fetches so the preview always
/// shows the file as it is on disk right now.
///
/// DD-10 failure classification is mapped onto `Failure`; callers render the
/// user-visible reason plus a retry entry instead of showing raw host codes.
///
/// The `/api/file` route is forwarded by the link plugin with
/// `redirect: 'manual'` and the plugin does not pass `Location` through, so a
/// stale `v` (302) must re-stat; the redirect target is not usable on the App
/// side. DD-02 retries that path exactly once.
@MainActor
final class WorkspaceImageClient {
    struct ImagePayload {
        var data: Data
        var mimeType: String?
    }

    /// Why an image file could not be loaded, in the categories the preview
    /// layer renders (DD-10: explicit reason + retry).
    enum Failure: Error, Equatable, LocalizedError {
        case notFound
        case forbidden
        case tooLarge
        case notRegularFile
        case unsupportedDesktopVersion
        case network
        case versionChanged
        case server
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notFound: return L10n.t("文件不存在或已被移动")
            case .forbidden: return L10n.t("没有读取该文件的权限")
            case .tooLarge: return L10n.t("图片文件过大")
            case .notRegularFile: return L10n.t("该路径不是可预览的文件")
            case .unsupportedDesktopVersion: return L10n.t("桌面端版本不支持查看文件")
            case .network: return L10n.t("网络连接失败")
            case .versionChanged: return L10n.t("文件版本持续变化，请重试")
            case .server: return L10n.t("图片读取失败")
            case .cancelled: return L10n.t("已取消")
            }
        }
    }

    private struct StatValue: Decodable {
        var absolutePath: String
        var version: String
    }

    private let link: LinkService

    // Same bounds as the existing exact-fetch routes: the primary origin gets
    // the full timeout, the alternate one a tighter 8s cap.
    private static let primaryTimeout: TimeInterval = 20
    private static let alternateTimeout: TimeInterval = 8

    init(link: LinkService) {
        self.link = link
    }

    /// `sessionId` maps to the host `workspaceFileScopeId`; `path` may be a
    /// workspace-relative or an absolute path (the host stat accepts both).
    func load(sessionId: String, path: String) async throws -> ImagePayload {
        let first = try await stat(sessionId: sessionId, path: path)
        do {
            return try await fetch(absolutePath: first.absolutePath, version: first.version)
        } catch let failure as Failure where failure == .versionChanged {
            // 302: `v` is stale (DD-02) — re-stat and retry exactly once.
            let current = try await stat(sessionId: sessionId, path: path)
            return try await fetch(absolutePath: current.absolutePath, version: current.version)
        }
    }

    // MARK: - Stat

    private func stat(sessionId: String, path: String) async throws -> StatValue {
        do {
            let value = try await link.unary(
                "workspaceFiles/stat",
                args: [
                    "workspaceFileScopeId": .string(sessionId),
                    "path": .string(path),
                ]
            )
            return try value.decode(StatValue.self)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Bytes

    private func fetch(absolutePath: String, version: String) async throws -> ImagePayload {
        let origins = fetchOrigins()
        guard !origins.isEmpty else { throw Failure.network }
        var lastFailure: Failure = .network
        for (index, origin) in origins.enumerated() {
            let timeout = index == 0
                ? Self.primaryTimeout
                : min(Self.primaryTimeout, Self.alternateTimeout)
            do {
                return try await fetch(
                    origin: origin,
                    absolutePath: absolutePath,
                    version: version,
                    timeout: timeout
                )
            } catch let failure as Failure {
                lastFailure = failure
                guard index + 1 < origins.count, Self.canTryAlternateOrigin(after: failure) else {
                    throw failure
                }
            }
        }
        throw lastFailure
    }

    /// Same origin ordering policy as the existing exact-fetch routes: the
    /// persisted origin first, one reachable alternate second, and the LAN
    /// alternate skipped on the cellular/relay path.
    private func fetchOrigins() -> [URL] {
        guard let credentials = link.credentials else { return [] }
        return LinkService.exactFetchOriginCandidates(
            persisted: credentials.originURL,
            stored: credentials.originCandidates,
            relayOverride: link.earlyListOriginOverride(),
            prefersRelay: NetworkPathMonitor.shared.prefersRelay
        )
    }

    private func fetch(
        origin: URL,
        absolutePath: String,
        version: String,
        timeout: TimeInterval
    ) async throws -> ImagePayload {
        var token = try await apiToken(origin: origin)
        var response: HTTPResponse
        do {
            response = try await get(
                origin: origin,
                absolutePath: absolutePath,
                version: version,
                token: token,
                timeout: timeout
            )
            if response.status == 401, Self.isExpiredToken(body: response.bodyText) {
                token = try await apiToken(origin: origin, forceRefresh: true)
                response = try await get(
                    origin: origin,
                    absolutePath: absolutePath,
                    version: version,
                    token: token,
                    timeout: timeout
                )
            }
        } catch {
            throw Self.map(error)
        }
        switch response.status {
        case 200:
            return ImagePayload(
                data: response.body,
                mimeType: Self.mimeType(response: response, path: absolutePath)
            )
        case 302:
            throw Failure.versionChanged
        default:
            throw Self.map(status: response.status, body: response.bodyText)
        }
    }

    private func apiToken(origin: URL, forceRefresh: Bool = false) async throws -> String {
        do {
            return try await link.ensureAPIToken(forceRefresh: forceRefresh, originOverride: origin)
        } catch {
            throw Self.map(error)
        }
    }

    /// Binary exact GET against the pinned link origin. This is the same
    /// transport `HTTPSClient.exactGETJSON` uses (same leaf pin / CA / bearer
    /// token / pooled connection); the JSON helper cannot be reused because it
    /// converts the body to `String`, which is lossy for image bytes.
    private func get(
        origin: URL,
        absolutePath: String,
        version: String,
        token: String,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        guard let host = origin.host, !host.isEmpty else { throw Failure.network }
        var headers: [String: String] = [
            "authorization": "Bearer \(token)",
            "accept": "image/*,*/*",
            "accept-encoding": "identity",
        ]
        for (name, value) in link.currentTraceHeaders() {
            headers[name.lowercased()] = value
        }
        let request = HTTPRequest(
            method: "GET",
            path: Self.fileRequestPath(absolutePath: absolutePath, version: version),
            headers: headers,
            body: nil
        )
        let credentials = link.credentials
        let client = HTTPSClient(
            host: host,
            port: UInt16(origin.port ?? 443),
            leafPin: credentials?.leafPin,
            caCertBase64: credentials?.caCertBase64
        )
        return try await client.perform(request, timeout: timeout)
    }

    /// Query encoding mirrors `HTTPSClient.exactGETJSON` (same allowed set), so
    /// absolute paths with spaces, `#`, `?` or non-ASCII characters round-trip.
    private static func fileRequestPath(absolutePath: String, version: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))
        let encodedPath = absolutePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? absolutePath
        let encodedVersion = version.addingPercentEncoding(withAllowedCharacters: allowed) ?? version
        return "/api/file?path=\(encodedPath)&v=\(encodedVersion)"
    }

    private static func mimeType(response: HTTPResponse, path: String) -> String? {
        if let raw = response.header("content-type") {
            let type = (raw.split(separator: ";", maxSplits: 1).first.map { String($0) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !type.isEmpty, type.lowercased() != "application/octet-stream" {
                return type
            }
        }
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    // MARK: - Error mapping (DD-10)

    private static func isExpiredToken(body: String) -> Bool {
        body.contains("auth/token-expired") || body.contains("auth/invalid")
    }

    private static func map(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return .cancelled }
        guard let linkError = error as? LinkError else { return .server }
        switch linkError {
        case .remote(let remote):
            return map(remoteCode: remote.code)
        case .httpStatus(let status, let body):
            return map(status: status, body: body)
        case .cancelled:
            return .cancelled
        case .timeout, .transport, .notConnected, .notPaired, .tlsPinMismatch:
            return .network
        case .malformedEnvelope, .rpcMismatch:
            return .server
        }
    }

    private static func map(remoteCode: String) -> Failure {
        switch remoteCode {
        case "workspace-file/not-found":
            return .notFound
        case "workspace-file/not-regular-file":
            return .notRegularFile
        case "workspace-file/too-large":
            return .tooLarge
        case "remote-access/denied":
            return .forbidden
        case "gateway/method-unavailable", "lookup-not-found",
             "service-unavailable", "invocation-unavailable":
            return .unsupportedDesktopVersion
        default:
            return .server
        }
    }

    private static func map(status: Int, body: String) -> Failure {
        switch status {
        case 403: return .forbidden
        case 404:
            // A plugin without `/api/file` in its exact-fetch allowlist answers
            // `route/not-allowed`, not the host's file-level 404 (DD-10:
            // "桌面端版本不支持").
            return body.contains("route/not-allowed") ? .unsupportedDesktopVersion : .notFound
        case 413: return .tooLarge
        case 499: return .cancelled
        default: return .server
        }
    }

    /// Only transport/5xx-class failures can be fixed by dialing the alternate
    /// origin; definitive file-level answers (404/403/413/version change) cannot.
    private static func canTryAlternateOrigin(after failure: Failure) -> Bool {
        switch failure {
        case .network, .server:
            return true
        case .notFound, .forbidden, .tooLarge, .notRegularFile,
             .unsupportedDesktopVersion, .versionChanged, .cancelled:
            return false
        }
    }
}
