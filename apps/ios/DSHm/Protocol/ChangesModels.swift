import Foundation

// MARK: - Exact-fetch file changes (protocol §3.9)

/// `GET /api/changes.summary?sessionId&seq` (Host-process memory; 404 after a
/// host restart / session release -> callers fall back to tool/result meta.diffs).
struct ChangesSummaryValue: Decodable, Equatable {
    struct File: Decodable, Equatable, Identifiable {
        var path: String
        var display: String?
        var added: Int?
        var deleted: Int?
        var id: String { path }
    }

    var turn: Int?
    var files: [File]
    var total: Int?
    var added: Int?
    var deleted: Int?
}

/// `GET /api/changes.diff?sessionId&seq&index`.
struct ChangesDiffValue: Decodable, Equatable {
    struct Hunk: Decodable, Equatable {
        var oldStart: Int?
        var oldLines: Int?
        var newStart: Int?
        var newLines: Int?
        var lines: [String]
    }

    var kind: String?
    var path: String?
    var display: String?
    var before: Bool?
    var after: Bool?
    var hunks: [Hunk]?
    var coarse: Bool?
}

/// One turn's file-change view: exact-fetch summary when available, otherwise
/// the meta.diffs fallback aggregated client-side.
struct TurnFileChanges: Equatable {
    enum Source: Equatable {
        case exactFetch
        case metaDiffsFallback
    }

    var source: Source
    var files: [ChangesSummaryValue.File]
    var added: Int
    var deleted: Int
    var seq: Int?
 /// 跨端口径（桌面端一致）：标题文件数用 Host 的 `total`，不是客户端 files 数组长度。
 /// 桌面端实测「标题用 total、列表用 files.length」，二者可能不等。
    var total: Int? = nil

 /// 卡片标题的文件数口径（跨端一致）：Host `total` 优先，缺省才回退客户端
 /// files 数组长度。桌面端实测「标题用 total、列表用 files.length」，二者可能
 /// 不等（fixture: total=50 / files=18），所以这里不能直接写 files.count。
    var titleFileCount: Int { total ?? files.count }

 /// Exact-fetch summary → 卡片/sheet 视图模型。真实取数与 DEBUG E2E seam 共用，
 /// 保证两者走同一套 total/added/deleted 口径。
    static func exact(from summary: ChangesSummaryValue, seq: Int?) -> TurnFileChanges {
        TurnFileChanges(
            source: .exactFetch,
            files: summary.files,
            added: summary.added ?? summary.files.reduce(0) { $0 + ($1.added ?? 0) },
            deleted: summary.deleted ?? summary.files.reduce(0) { $0 + ($1.deleted ?? 0) },
            seq: seq,
            total: summary.total
        )
    }
}
