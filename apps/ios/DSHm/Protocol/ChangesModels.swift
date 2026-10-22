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
}
