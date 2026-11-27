import Combine
import Foundation

/// 文件内容面板的读取服务与状态机（DD-01 / DD-03 / DD-10）。
///
/// - 每次打开面板新建一个实例：首屏 300 行，「加载更多」每次再 300 行直到 `eof`；
///   内容不缓存、不跨实例复用（AC-09、AC-13）。
/// - 读取全部经构造时注入的 unary 闭包走宿主 `workspaceFiles/read` / `workspaceFiles/stat`，
///   不直接依赖 `LinkService`，便于单测脚本化每一页与每一种错误（AC-11 的可测试性）。
/// - 状态机：`loading` → `text` / `binary` / `large` / `unsupported` / `error`；
///   `text` 可继续 append，`error` 可重试回 `loading`；非法动作（已 `eof`、正在 `loading`）
///   时加载入口禁用。
///
/// 面板视图的接法：
/// ```swift
/// @StateObject private var loader = FileContentLoader(sessionId: sessionId, path: path, link: link)
/// // ...
/// .task { await loader.start() }                       // 首屏（每次打开新建实例）
/// // 「加载更多」：Task { await loader.loadMore() }
/// // 「重试」：    Task { await loader.retry() }
/// ```
@MainActor
final class FileContentLoader: ObservableObject {
    /// unary 调用闭包：`(method, args) async throws -> JSONValue`。
    typealias UnaryCall = (_ method: String, _ args: [String: JSONValue]) async throws -> JSONValue

    static let readMethod = "workspaceFiles/read"
    static let statMethod = "workspaceFiles/stat"
    /// 首屏与每次「加载更多」请求的行数；`too-large` 时按页减半（每页最多减半重试一次）。
    static let pageLines = 300

    let sessionId: String
    let path: String

    /// 当前状态（初始为 `loading`，`start()` 后进入首屏读取结果）。
    @Published private(set) var state: FileContentState = .loading
    /// 面板头元数据；随每次 `read` / `stat` 响应刷新。
    @Published private(set) var metadata: FileContentMetadata

    private let unary: UnaryCall
    /// 当前页大小；`too-large` 减半后在本次打开内沿用（避免每页重复触发同样的失败）。
    private var pageSize = FileContentLoader.pageLines
    /// 下一页的 1-based 起始行号；首屏从 1 开始。
    private var nextOffset = 1
    private var started = false

    init(sessionId: String, path: String, unary: @escaping UnaryCall) {
        self.sessionId = sessionId
        self.path = path
        self.unary = unary
        self.metadata = FileContentMetadata(path: path)
    }

    /// 用真实 `LinkService` 构造（生产路径；单测用上面的闭包构造器）。
    convenience init(sessionId: String, path: String, link: LinkService) {
        self.init(sessionId: sessionId, path: path, unary: { method, args in
            try await link.unary(method, args: args)
        })
    }

    /// 「加载更多」入口是否可用（已到 `eof`、正在加载或已有待重试失败时为 false）。
    var canLoadMore: Bool { state.canLoadMore }

    /// 重试入口是否可用（错误态，或「加载更多」失败）。
    var canRetry: Bool { state.canRetry }

    /// 首屏是否仍在读取。
    var isLoadingFirstPage: Bool { state.isLoading }

    // MARK: - 动作

    /// 读取首屏；重复调用无副作用（每次打开新建实例，不跨实例复用）。
    func start() async {
        guard !started else { return }
        started = true
        state = .loading
        await readFirstPage(isRetry: false)
    }

    /// 「加载更多」：从当前偏移再读一页并追加；`eof` / 正在加载 / 有失败待重试时禁用。
    func loadMore() async {
        guard case .text(var text) = state, text.canLoadMore else { return }
        text.isLoadingMore = true
        text.loadMoreFailure = nil
        state = .text(text)
        await readNextPage(isRetry: false)
    }

    /// 重试：错误态回到 `loading` 重读首屏；「加载更多」失败时保留已加载行、从当前偏移重读。
    /// 重试再失败会在失败原因上标记 `retriedAndFailed`。
    func retry() async {
        switch state {
        case .error:
            state = .loading
            await readFirstPage(isRetry: true)
        case .text(let text) where text.loadMoreFailure != nil:
            var text = text
            text.loadMoreFailure = nil
            text.isLoadingMore = true
            state = .text(text)
            await readNextPage(isRetry: true)
        case .loading, .text, .binary, .large, .unsupported:
            return
        }
    }

    // MARK: - 读取流程

    private func readFirstPage(isRetry: Bool) async {
        nextOffset = 1
        await readPage(offset: 1, isFirstPage: true, isRetry: isRetry)
    }

    private func readNextPage(isRetry: Bool) async {
        await readPage(offset: nextOffset, isFirstPage: false, isRetry: isRetry)
    }

    private func readPage(offset: Int, isFirstPage: Bool, isRetry: Bool) async {
        // 每一页最多做一次「行数减半」重试（DD-10：too-large → 减半重试一次）。
        var mayHalvePage = true
        while true {
            do {
                let page = try await requestPage(offset: offset, limit: pageSize)
                let lines = page.displayLines
                // 宿主契约：非 eof 页至少有一行；空页视为异常，避免「加载更多」原地空转。
                if lines.isEmpty && !page.eof {
                    throw FileContentLoadError.emptyPage
                }
                apply(page: page, lines: lines, requestedOffset: offset, isFirstPage: isFirstPage)
                return
            } catch {
                let failure = FileContentFailure.map(error, retriedAndFailed: isRetry)
                if failure.kind == .tooLarge {
                    // 单页行数减半重试一次，仍 too-large → 「行太长」终态（DD-10）。
                    if mayHalvePage, pageSize > 1 {
                        pageSize = max(1, pageSize / 2)
                        mayHalvePage = false
                        continue
                    }
                    state = .large
                    return
                }
                // 网关不可用 = 旧桌面端没有 workspaceFiles，整面板进「版本不支持」态（DD-10）。
                if failure.kind == .gatewayUnavailable {
                    state = .unsupported
                    return
                }
                // not-text → 二进制态（先 stat 取大小，按扩展名给类型）（DD-10）。
                if failure.kind == .notText {
                    await enterBinaryState()
                    return
                }
                // 其余失败：首屏进错误态；「加载更多」失败保留已加载行（§5：重试从当前偏移继续）。
                if isFirstPage {
                    state = .error(failure)
                } else {
                    appendFailure(failure)
                }
                return
            }
        }
    }

    private func apply(page: FileContentPage, lines: [String], requestedOffset: Int, isFirstPage: Bool) {
        metadata.absorb(page)
        nextOffset = requestedOffset + lines.count
        if isFirstPage {
            state = .text(FileContentText(lines: lines, eof: page.eof))
            return
        }
        guard case .text(var text) = state else { return }
        text.lines.append(contentsOf: lines)
        text.eof = page.eof
        text.isLoadingMore = false
        text.loadMoreFailure = nil
        state = .text(text)
    }

    /// 「加载更多」失败：保留已加载行，底部给出失败原因与重试入口。
    private func appendFailure(_ failure: FileContentFailure) {
        guard case .text(var text) = state else { return }
        text.isLoadingMore = false
        text.loadMoreFailure = failure
        state = .text(text)
    }

    /// 二进制态：`not-text` 后尽力用 `stat` 取大小；`stat` 失败不影响进入二进制态。
    private func enterBinaryState() async {
        var absolutePath: String?
        var byteCount: Int?
        if let stat = try? await requestStat() {
            metadata.absorb(stat)
            absolutePath = stat.absolutePath
            byteCount = stat.byteCount
        }
        state = .binary(FileContentBinary(byteCount: byteCount, path: path, absolutePath: absolutePath))
    }

    // MARK: - Unary

    private func requestPage(offset: Int, limit: Int) async throws -> FileContentPage {
        let value = try await unary(Self.readMethod, [
            "workspaceFileScopeId": .string(sessionId),
            "path": .string(path),
            "range": .object([
                "offset": .int(Int64(offset)),
                "limit": .int(Int64(limit)),
            ]),
        ])
        return try FileContentPage.decode(value)
    }

    private func requestStat() async throws -> FileContentStat {
        let value = try await unary(Self.statMethod, [
            "workspaceFileScopeId": .string(sessionId),
            "path": .string(path),
        ])
        return try FileContentStat.decode(value)
    }
}
