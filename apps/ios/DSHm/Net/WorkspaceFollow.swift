import Foundation

/// One registered workspace from `workspace/follow` (`items[]` in baseline/replace).
/// Mirrors the Host's workspace registry: id, canonical path, display title and the
/// sessions accounted to it (in manual order).
struct WorkspaceDescriptor: Decodable, Equatable, Identifiable {
    var workspaceId: String
    var path: String
    var title: String
    var sessionIds: [String]
    var createdAt: String?
    var updatedAt: String?

    var id: String { workspaceId }

    init(
        workspaceId: String,
        path: String,
        title: String,
        sessionIds: [String] = [],
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Registry-global snapshot: ordered workspaces plus archive/pin sets.
struct WorkspaceFollowSnapshot: Decodable, Equatable {
    var items: [WorkspaceDescriptor]
    var archivedSessionIds: [String]
    var pinnedSessionIds: [String]

    init(items: [WorkspaceDescriptor] = [], archivedSessionIds: [String] = [], pinnedSessionIds: [String] = []) {
        self.items = items
        self.archivedSessionIds = archivedSessionIds
        self.pinnedSessionIds = pinnedSessionIds
    }
}

/// One item frame of the `workspace/follow` stream (protocol §3.13/§5):
/// `baseline` → `replace`/`upsert`/`remove`/`archived`/`pinned`/`order`.
/// Shapes verified against the Host's zod schema in the DSH core asar.
enum WorkspaceFollowFrame: Decodable, Equatable {
    case baseline(WorkspaceFollowSnapshot)
    case replace(WorkspaceFollowSnapshot)
    case upsert(WorkspaceDescriptor)
    case remove(workspaceId: String)
    case order(workspaceIds: [String])
    case archived(archivedSessionIds: [String])
    case pinned(pinnedSessionIds: [String])
 /// Forward compatibility: unknown frame types are ignored by the reducer.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case workspace
        case workspaceId
        case workspaceIds
        case archivedSessionIds
        case pinnedSessionIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "baseline":
            self = .baseline(try container.decode(WorkspaceFollowSnapshot.self, forKey: .value))
        case "replace":
            self = .replace(try container.decode(WorkspaceFollowSnapshot.self, forKey: .value))
        case "upsert":
            self = .upsert(try container.decode(WorkspaceDescriptor.self, forKey: .workspace))
        case "remove":
            self = .remove(workspaceId: try container.decode(String.self, forKey: .workspaceId))
        case "order":
            self = .order(workspaceIds: try container.decode([String].self, forKey: .workspaceIds))
        case "archived":
            self = .archived(archivedSessionIds: try container.decode([String].self, forKey: .archivedSessionIds))
        case "pinned":
            self = .pinned(pinnedSessionIds: try container.decode([String].self, forKey: .pinnedSessionIds))
        default:
            self = .unknown(type: type)
        }
    }
}

/// Client-side `workspace/follow` state machine: ordered registered workspaces plus
/// archive/pin sets. A baseline or replace replaces the whole table; the remaining
/// frames apply incrementally. On reconnect the stream is reopened and the new
/// baseline replaces local state (protocol §4.3/§4.4).
struct WorkspaceFollowState: Equatable {
    private(set) var workspaces: [WorkspaceDescriptor] = []
    private(set) var archivedSessionIds: Set<String> = []
 /// Registry-global pin set, most recently pinned first.
    private(set) var pinnedSessionIds: [String] = []

    var baselineApplied = false

    init() {}

    init(snapshot: WorkspaceFollowSnapshot) {
        applySnapshot(snapshot)
    }

    mutating func apply(_ frame: WorkspaceFollowFrame) {
        switch frame {
        case .baseline(let snapshot), .replace(let snapshot):
            applySnapshot(snapshot)
        case .upsert(let workspace):
            if let index = workspaces.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
                workspaces[index] = workspace
            } else {
 // The Host prepends newly created workspaces to the durable order.
                workspaces.insert(workspace, at: 0)
            }
        case .remove(let workspaceId):
            workspaces.removeAll { $0.workspaceId == workspaceId }
        case .order(let workspaceIds):
            applyOrder(workspaceIds)
        case .archived(let archivedSessionIds):
            self.archivedSessionIds = Set(archivedSessionIds)
        case .pinned(let pinnedSessionIds):
            self.pinnedSessionIds = pinnedSessionIds
        case .unknown:
            break
        }
    }

    private mutating func applySnapshot(_ snapshot: WorkspaceFollowSnapshot) {
        workspaces = snapshot.items
        archivedSessionIds = Set(snapshot.archivedSessionIds)
        pinnedSessionIds = snapshot.pinnedSessionIds
        baselineApplied = true
    }

    private mutating func applyOrder(_ workspaceIds: [String]) {
        let order = Dictionary(workspaceIds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ranked = workspaces.enumerated().sorted { lhs, rhs in
            let left = order[lhs.element.workspaceId] ?? Int.max
            let right = order[rhs.element.workspaceId] ?? Int.max
            if left != right { return left < right }
 // Keep unknown workspaces in their existing relative order after known ones.
            return lhs.offset < rhs.offset
        }
        workspaces = ranked.map(\.element)
    }
}
