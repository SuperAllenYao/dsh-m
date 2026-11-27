import Foundation

// MARK: - 元数据

/// 文件面板头部展示所需的一次性元数据。
///
/// 每次打开面板新建；`workspaceFiles/read` / `workspaceFiles/stat` 的响应会持续刷新
/// `absolutePath` / `version` / `byteCount`，面板不缓存文件内容（AC-13）。
struct FileContentMetadata: Equatable, Sendable {
    /// 调用方传入的路径（工作区相对或绝对路径）；分页读取沿用同一个值。
    var path: String
    /// 桌面端解析出的绝对路径。
    var absolutePath: String?
    /// 宿主文件版本（不透明令牌，只透出、不解析）。
    var version: String?
    /// 完整文件的字节数（不是本页字节数；后端未报告时为 nil）。
    var byteCount: Int?

    init(path: String) {
        self.path = path
    }

    /// 文件名（路径最后一段），面板头标题使用。
    var fileName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// 小写扩展名（不含点）；无扩展名时为 nil，面板按它展示语言/类型。
    var fileExtension: String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    mutating func absorb(_ page: FileContentPage) {
        absolutePath = page.absolutePath
        version = page.version
        if let byteCount = page.byteCount {
            self.byteCount = byteCount
        }
    }

    mutating func absorb(_ stat: FileContentStat) {
        absolutePath = stat.absolutePath
        version = stat.version
        if let byteCount = stat.byteCount {
            self.byteCount = byteCount
        }
    }
}

// MARK: - Wire 解码

/// `workspaceFiles/read` 返回的一页文本。
///
/// wire：`{offset, text, lines, eof, absolutePath, version, bytes?}`。
/// `offset` 是 1-based 行号（宿主默认 1、响应原样回显）；`text` 是本页各行以 `\n`
/// 连接、末尾无换行；`lines` 是本页行数（`offset` 越过文件末尾时为 0）；
/// `bytes` 是**完整文件**字节数，不是本页字节数。
struct FileContentPage: Equatable, Sendable {
    var offset: Int
    var text: String
    var lines: Int
    var eof: Bool
    var absolutePath: String
    var version: String
    var byteCount: Int?

    /// 解析 unary `workspaceFiles/read` 的返回值。
    static func decode(_ value: JSONValue) throws -> FileContentPage {
        guard let object = value.objectValue,
              let offset = object["offset"]?.int,
              let text = object["text"]?.stringValue,
              let lines = object["lines"]?.int,
              let eof = object["eof"]?.boolValue,
              let absolutePath = object["absolutePath"]?.stringValue,
              let version = object["version"]?.stringValue
        else {
            throw FileContentLoadError.malformedReadResponse
        }
        return FileContentPage(
            offset: offset,
            text: text,
            lines: lines,
            eof: eof,
            absolutePath: absolutePath,
            version: version,
            byteCount: object["bytes"]?.int
        )
    }

    /// 本页正文行。
    ///
    /// 空 `text` 有两种含义（宿主用 `lines` 区分）：空页（`lines == 0`）或只有一个空行
    /// （`lines == 1`）。`text` 非空时按 `\n` 拆分；末尾无换行，拆出的元素数即行数。
    var displayLines: [String] {
        if text.isEmpty {
            return lines > 0 ? Array(repeating: "", count: lines) : []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// `workspaceFiles/stat` 返回的文件信息（二进制态取大小/版本用）。
struct FileContentStat: Equatable, Sendable {
    var absolutePath: String
    var version: String
    var byteCount: Int?

    static func decode(_ value: JSONValue) throws -> FileContentStat {
        guard let object = value.objectValue,
              let absolutePath = object["absolutePath"]?.stringValue,
              let version = object["version"]?.stringValue
        else {
            throw FileContentLoadError.malformedStatResponse
        }
        return FileContentStat(
            absolutePath: absolutePath,
            version: version,
            byteCount: object["bytes"]?.int
        )
    }
}

/// 文件读取响应的本地解析失败（不是远端业务错误）。
enum FileContentLoadError: Error, LocalizedError, Equatable {
    case malformedReadResponse
    case malformedStatResponse
    case emptyPage

    var errorDescription: String? {
        switch self {
        case .malformedReadResponse:
            return L10n.t("桌面端返回了无法解析的文件读取结果")
        case .malformedStatResponse:
            return L10n.t("桌面端返回了无法解析的文件信息")
        case .emptyPage:
            return L10n.t("桌面端返回了空的一页文件内容")
        }
    }
}

// MARK: - 状态

/// 文本态：已加载的行与分页游标。
struct FileContentText: Equatable, Sendable {
    /// 已加载的正文行（行号 = 下标 + 1，绝对行号）。
    var lines: [String]
    /// 是否已读到文件最后一行；为真时 `lines.count` 即总行数。
    var eof: Bool
    /// 「加载更多」是否在飞（入口据此禁用）。
    var isLoadingMore: Bool
    /// 「加载更多」失败时已加载行保留，失败原因在此；重试入口据此出现。
    var loadMoreFailure: FileContentFailure?

    init(
        lines: [String] = [],
        eof: Bool = false,
        isLoadingMore: Bool = false,
        loadMoreFailure: FileContentFailure? = nil
    ) {
        self.lines = lines
        self.eof = eof
        self.isLoadingMore = isLoadingMore
        self.loadMoreFailure = loadMoreFailure
    }

    /// 已加载行数；`eof` 为真时等于总行数。
    var loadedLines: Int { lines.count }

    /// 总行数：只有读到 `eof` 后才知道，否则为 nil（总行数不在 `eof` 前暴露）。
    var totalLines: Int? { eof ? lines.count : nil }

    /// 「加载更多」入口是否可用：已到 `eof`、正在加载或已有待重试的失败时禁用。
    var canLoadMore: Bool { !eof && !isLoadingMore && loadMoreFailure == nil }
}

/// 二进制态：`not-text` 映射而来；按扩展名给出类型，大小尽力用 `stat` 取。
struct FileContentBinary: Equatable, Sendable {
    /// 完整文件字节数；`stat` 失败时为 nil。
    var byteCount: Int?
    /// 按扩展名给出的类型文案（未知扩展名 → 「未知类型」）。
    var typeLabel: String
    /// 小写扩展名（不含点）；无扩展名时为 nil，面板可用于显示后缀 chip。
    var fileExtension: String?
    /// `stat` 成功时的绝对路径。
    var absolutePath: String?

    init(byteCount: Int?, path: String, absolutePath: String? = nil) {
        self.byteCount = byteCount
        self.typeLabel = FileContentTypeName.label(forPath: path)
        self.fileExtension = FileContentTypeName.fileExtension(ofPath: path)
        self.absolutePath = absolutePath
    }
}

/// 按扩展名给文件类型名（二进制态展示；图片类型只做兜底，正常图片文件走全屏预览）。
enum FileContentTypeName {
    static func fileExtension(ofPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    static func label(forPath path: String) -> String {
        guard let ext = fileExtension(ofPath: path) else { return L10n.t("未知类型") }
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff", "svg", "ico":
            return L10n.t("图片")
        case "pdf":
            return L10n.t("PDF 文档")
        case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar":
            return L10n.t("压缩包")
        case "txt", "md", "markdown", "log", "csv", "json", "yaml", "yml", "toml", "ini", "conf",
             "xml", "html", "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "m", "mm", "h", "c",
             "cpp", "cc", "go", "py", "rs", "java", "kt", "rb", "php", "sh", "zsh", "bash", "sql":
            return L10n.t("文本")
        default:
            return L10n.t("未知类型")
        }
    }
}

/// 文件失败的分类（DD-10）。
enum FileContentFailureKind: String, Equatable, Sendable {
    case fileNotFound
    case outsideWorkspace
    case notDirectory
    case notRegularFile
    case permissionDenied
    case internalError
    /// 网关/宿主不提供 `workspaceFiles`（旧桌面端）；映射到 `unsupported` 态。
    case gatewayUnavailable
    /// `too-large` 减半重试后仍失败，或「加载更多」页过大。
    case tooLarge
    /// 文本读取遇到非文本内容（首页会转二进制态）。
    case notText
    case network
    case unknown

    /// 用户可见的失败原因。
    var reason: String {
        switch self {
        case .fileNotFound:
            return L10n.t("文件不存在或已被移动")
        case .outsideWorkspace:
            return L10n.t("文件不在当前工作区内，无法读取")
        case .notDirectory:
            return L10n.t("路径无效：上级路径不是目录")
        case .notRegularFile:
            return L10n.t("不是普通文件，无法预览")
        case .permissionDenied:
            return L10n.t("没有读取权限，无法查看此文件")
        case .internalError:
            return L10n.t("桌面端读取文件失败")
        case .gatewayUnavailable:
            return L10n.t("桌面端版本不支持查看文件")
        case .tooLarge:
            return L10n.t("文件行太长，无法继续加载")
        case .notText:
            return L10n.t("这是二进制文件，不能按文本预览")
        case .network:
            return L10n.t("连接中断，读取文件失败")
        case .unknown:
            return L10n.t("读取文件失败")
        }
    }
}

/// 一次文件读取失败的分类与用户可见原因。
struct FileContentFailure: Equatable, Sendable {
    var kind: FileContentFailureKind
    /// 宿主原始错误码（诊断/测试断言用，不直接展示）。
    var remoteCode: String?
    /// 用户点过「重试」之后仍然失败；错误态据此追加「仍然读取失败」。
    var retriedAndFailed: Bool
    /// 用户可见的失败原因（已本地化）。
    var reason: String

    init(kind: FileContentFailureKind, remoteCode: String? = nil, retriedAndFailed: Bool = false) {
        self.init(kind: kind, remoteCode: remoteCode, retriedAndFailed: retriedAndFailed, reason: kind.reason)
    }

    init(kind: FileContentFailureKind, remoteCode: String?, retriedAndFailed: Bool, reason: String) {
        self.kind = kind
        self.remoteCode = remoteCode
        self.retriedAndFailed = retriedAndFailed
        self.reason = reason
    }

    /// 错误态直接展示的完整文案（重试后仍失败时带「仍然读取失败」后缀）。
    var displayReason: String {
        retriedAndFailed ? L10n.f("%@（仍然读取失败）", reason) : reason
    }

    /// 把一次 unary 失败按 DD-10 归类。
    static func map(_ error: Error, retriedAndFailed: Bool) -> FileContentFailure {
        if let loadError = error as? FileContentLoadError {
            return FileContentFailure(
                kind: .internalError,
                remoteCode: nil,
                retriedAndFailed: retriedAndFailed,
                reason: loadError.errorDescription ?? FileContentFailureKind.internalError.reason
            )
        }
        if error is CancellationError {
            return FileContentFailure(
                kind: .network,
                remoteCode: nil,
                retriedAndFailed: retriedAndFailed,
                reason: L10n.t("已取消")
            )
        }
        if let code = remoteCode(from: error) {
            return remoteFailure(code: code, retriedAndFailed: retriedAndFailed)
        }
        return FileContentFailure(
            kind: fallbackKind(for: error),
            remoteCode: nil,
            retriedAndFailed: retriedAndFailed,
            reason: NetworkErrorInterpreter.message(for: error)
        )
    }

    /// 从 `LinkError.remote` / 直接抛出的 `RemoteError` 取远端错误码。
    static func remoteCode(from error: Error) -> String? {
        if let linkError = error as? LinkError, case .remote(let remote) = linkError {
            return remote.code
        }
        if let remote = error as? RemoteError {
            return remote.code
        }
        return nil
    }

    private static func remoteFailure(code: String, retriedAndFailed: Bool) -> FileContentFailure {
        let kind: FileContentFailureKind
        switch code {
        case "workspace-file/not-found":
            kind = .fileNotFound
        case "workspace-file/outside-workspace":
            kind = .outsideWorkspace
        case "workspace-file/not-directory":
            kind = .notDirectory
        case "workspace-file/not-regular-file":
            kind = .notRegularFile
        case "workspace-file/too-large":
            kind = .tooLarge
        case "workspace-file/not-text":
            kind = .notText
        case "remote-access/denied":
            kind = .permissionDenied
        case "gateway/internal":
            kind = .internalError
        case "gateway/method-unavailable", "lookup-not-found", "service-unavailable", "invocation-unavailable":
            kind = .gatewayUnavailable
        default:
            kind = .unknown
        }
        return FileContentFailure(
            kind: kind,
            remoteCode: code,
            retriedAndFailed: retriedAndFailed,
            reason: kind.reason
        )
    }

    private static func fallbackKind(for error: Error) -> FileContentFailureKind {
        guard let linkError = error as? LinkError else { return .internalError }
        switch linkError {
        case .transport, .timeout, .notConnected, .notPaired, .httpStatus, .cancelled:
            return .network
        case .tlsPinMismatch, .malformedEnvelope, .rpcMismatch, .remote:
            return .internalError
        }
    }
}

/// 文件面板状态机（每次打开新建）。
///
/// `loading` → `text` / `binary` / `large` / `unsupported` / `error`；
/// 文本态可经「加载更多」继续追加；错误态可重试回 `loading`。
enum FileContentState: Equatable, Sendable {
    case loading
    case text(FileContentText)
    case binary(FileContentBinary)
    /// 单页行数减半重试一次后仍 `too-large`：行太长，不可预览。
    case large
    /// 网关/宿主不提供 `workspaceFiles`：桌面端版本不支持查看文件。
    case unsupported
    case error(FileContentFailure)

    /// 文本态（其它状态为 nil）。
    var textValue: FileContentText? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// 「加载更多」入口是否可用。
    var canLoadMore: Bool { textValue?.canLoadMore ?? false }

    /// 是否可重试：错误态，或文本态下「加载更多」失败。
    var canRetry: Bool {
        switch self {
        case .error:
            return true
        case .text(let text):
            return text.loadMoreFailure != nil
        case .loading, .binary, .large, .unsupported:
            return false
        }
    }

    /// 首屏是否仍在读取（spinner）。
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
