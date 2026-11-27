import SwiftUI

// MARK: - 统一打开契约（DD-06 / AC-07 / AC-15）

/// 正文文件链接的打开目标。
///
/// 只描述「打开哪一种承载 + 哪个路径」，**不带 sessionId**：承载方（会话详情）从自己的
/// 上下文补。路由层因此不依赖会话状态，正文链接、工具行、变更列表等入口共用同一契约。
enum FileOpenTarget: Equatable, Sendable {
    /// 文本类文件 → 底部文件内容面板。
    case filePanel(path: String)
    /// 图片文件 → 全屏图片预览。
    case imagePreview(path: String)

    /// 目标文件路径：已剥离 `file://`、已解码百分号转义；相对路径保持相对。
    var path: String {
        switch self {
        case .filePanel(let path), .imagePreview(let path):
            return path
        }
    }
}

/// 链接目标 → 打开目标的唯一分类器（DD-06）。
///
/// 分类口径（AC-07 / AC-15）：
/// - `http`/`https`/`mailto`/锚点等**非文件链接** → `nil`，调用方保持原行为；
/// - 图片扩展名 → `.imagePreview`。只列 `UIImage` 可解码的格式：svg/ico 不进预览
///   （预览层解不出图，只会变成失败态），按文件路径走面板的二进制态；
/// - 其它「看起来是文件路径」的（带扩展名、含 `/`、或 `.gitignore` 这类隐藏文件）→ `.filePanel`。
enum FileOpenRouter {
    /// 可全屏预览的图片扩展名（小写；AC-15 要求不只认 png）。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp", "tif", "tiff",
    ]

    /// 链接目标（URL 字符串）→ 打开目标。
    ///
    /// 接受相对路径（`docs/x/y.md`）、绝对路径（`/Users/me/a.png`）与 `file://` URL；
    /// query/fragment（如 `a.md#L12`）按路径语义丢弃，百分号转义解码后交下游。
    static func target(forLinkTarget raw: String) -> FileOpenTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 锚点链接与协议相对链接（`//host/path`）都不是文件路径。
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        // 只有 `file://` 算文件；http/https/mailto 等一律交回调用方。
        if let scheme = url.scheme, !scheme.isEmpty, scheme.lowercased() != "file" {
            return nil
        }
        // `path(percentEncoded: false)` 同时做三件事：丢 query/fragment、剥离 `file://`、解码 `%20`。
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty, !path.hasSuffix("/") else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return .imagePreview(path: path)
        }
        guard isFileLikePath(path: path, name: name, extension: ext) else { return nil }
        return .filePanel(path: path)
    }

    /// `openURL` 环境值的拦截器（不含行内代码的正文段落 / 扁平化正文共用）。
    ///
    /// 分类为文件 → 交 `fileOpenAction` 并 `.handled`；其余（http/https/锚点…）返回
    /// `.systemAction`，与改造前完全一致。`fileOpenAction == nil`（没人承载）时同样返回
    /// `.systemAction`：文件链接保持现状，不崩、不误触。
    static func openURLAction(fileOpenAction: ((FileOpenTarget) -> Void)?) -> OpenURLAction {
        OpenURLAction { url in
            guard let fileOpenAction,
                  let target = target(forLinkTarget: url.absoluteString) else {
                return .systemAction
            }
            fileOpenAction(target)
            return .handled
        }
    }

    // MARK: 判定细节

    private static func isFileLikePath(path: String, name: String, extension ext: String) -> Bool {
        if isValidExtension(ext) { return true }
        // 隐藏文件没有 pathExtension（`.gitignore` / `.env`），但它就是文件。
        if name.hasPrefix(".") { return true }
        // 无扩展名但带目录分隔符（`docs/settings`）：按文件路径处理（DD-06：含 `/` 即文件路径）。
        return path.contains("/")
    }

    /// 扩展名合法性：1...10 个 ASCII 字母/数字，且至少含一个字母。
    /// 目的：不把 `v2.8.0` 这类版本号链接（扩展名是纯数字）误判成文件路径。
    private static func isValidExtension(_ ext: String) -> Bool {
        guard (1...10).contains(ext.count) else { return false }
        var hasLetter = false
        for character in ext {
            guard character.isASCII, character.isLetter || character.isNumber else { return false }
            if character.isLetter { hasLetter = true }
        }
        return hasLetter
    }
}

// MARK: - 环境接线点

/// 正文文件链接打开动作的环境键；`nil` = 没人承载（保持现状）。
struct FileOpenActionKey: EnvironmentKey {
    static let defaultValue: ((FileOpenTarget) -> Void)? = nil
}

extension EnvironmentValues {
    /// 文件链接打开动作：由承载方（会话详情）注入；这是各入口与预览层**唯一**的接线点。
    var fileOpenAction: ((FileOpenTarget) -> Void)? {
        get { self[FileOpenActionKey.self] }
        set { self[FileOpenActionKey.self] = newValue }
    }
}
