import Foundation
import SwiftUI

/// One background job projection from the host's `job/list` stream
/// (`dsh-api-job-controller`). The plugin forwards the stream over the same P1
/// channel used by `$events` / `session/follow`.
struct JobRow: Identifiable, Equatable {
    var id: String
    var kind: String
    var label: String
    var owner: String?
    var status: JobStatus
    var startedAt: Int64?
    var finishedAt: Int64?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        self.kind = json["kind"]?.stringValue ?? "job"
        self.label = json["label"]?.stringValue ?? L10n.t("后台任务")
        self.owner = json["owner"]?.stringValue
        self.status = JobStatus(raw: json["status"]?.stringValue)
        self.startedAt = json["startedAt"]?.intValue
        self.finishedAt = json["finishedAt"]?.intValue
    }
}

/// Host job status (`dsh-jobs-local` isTerminal: completed / killed / failed).
enum JobStatus: Equatable {
    case running
    case stopping
    case completed
    case killed
    case failed
    case unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "running": self = .running
        case "stopping": self = .stopping
        case "completed": self = .completed
        case "killed": self = .killed
        case "failed": self = .failed
        default: self = .unknown
        }
    }

    var isLive: Bool { self == .running || self == .stopping }

    var localizedLabel: String {
        switch self {
        case .running: return L10n.t("运行中")
        case .stopping: return L10n.t("正在停止")
        case .completed: return L10n.t("已完成")
        case .killed: return L10n.t("已停止")
        case .failed: return L10n.t("已失败")
        case .unknown: return L10n.t("未知")
        }
    }

    var color: Color {
        switch self {
        case .running: return Theme.Palette.accent
        case .stopping: return Theme.Palette.warning
        case .completed: return Theme.Palette.textSecondary
        case .killed: return Theme.Palette.textSecondary
        case .failed: return Theme.Palette.danger
        case .unknown: return Theme.Palette.textTertiary
        }
    }

 /// 0 running / 1 stopping / 2 terminal — the sheet's row order.
    var sortRank: Int {
        switch self {
        case .running: return 0
        case .stopping: return 1
        default: return 2
        }
    }
}

/// Session-scoped background-job roster.
///
/// Lifecycle: opened when the session detail appears (and the link is ready),
/// cancelled on disappear / session switch / disconnect; reopened on reconnect.
/// The stream replaces the whole roster on every frame; `job/kill` never mutates
/// local state — the next frame is the single source of truth.
@MainActor
final class JobListModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case available
        case unavailable
    }

    @Published private(set) var jobs: [JobRow] = []
    @Published private(set) var state: LoadState = .idle

    private var stream: RemoteStreamHandle?
    private var sessionId: String?

    var hasLiveJobs: Bool {
        jobs.contains { $0.status.isLive }
    }

 /// Start (or restart) the roster stream for one session. Safe to call often.
    func start(sessionId: String, link: LinkService) {
        guard link.phase.isConnected else { return }
        if self.sessionId == sessionId, stream != nil { return }
        stop()
        self.sessionId = sessionId
        state = .loading
        do {
            stream = try link.openStream(
                endpoint: "job/list",
                args: ["request": .object(["sessionId": .string(sessionId)])],
                onItem: { [weak self] value in
                    self?.apply(value)
                },
                onEnd: { [weak self] in
                    self?.markUnavailable()
                },
                onError: { [weak self] _ in
                    self?.markUnavailable()
                },
                onClose: { [weak self] _, _ in
                    self?.markUnavailable()
                }
            )
        } catch {
            state = .unavailable
            stream = nil
        }
    }

 /// Release the roster stream (session detail dismissed / disconnected).
    func stop() {
        stream?.cancel()
        stream = nil
        sessionId = nil
        jobs = []
        state = .idle
    }

 /// Stop one live job on the user's behalf. The roster frame will report the
 /// terminal state; a failed call surfaces to the sheet as an inline error.
 /// Returns the host outcome (`"already-finished"` when the job settled before
 /// the tap); callers surface that as a neutral "任务已结束" hint, not an error.
    func kill(_ job: JobRow, link: LinkService) async throws -> String? {
        guard let sessionId else { throw LinkError.notConnected }
        let value = try await link.unary(
            "job/kill",
            args: ["request": .object([
                "sessionId": .string(sessionId),
                "jobId": .string(job.id),
            ])],
            timeout: 15
        )
        return value["outcome"]?.stringValue
    }

    private func apply(_ value: JSONValue?) {
        guard let value,
              let array = value["jobs"]?.arrayValue else { return }
        let rows = array
            .compactMap { JobRow(json: $0) }
            .filter { row in
 // `registry.list(sessionId)` returns own + unowned jobs; the
 // sheet only shows this session's own work (DEC-03).
                guard let owner = row.owner else { return false }
                return owner == sessionId
            }
            .sorted { lhs, rhs in
                if lhs.status.sortRank != rhs.status.sortRank {
                    return lhs.status.sortRank < rhs.status.sortRank
                }
                let leftTime = lhs.startedAt ?? 0
                let rightTime = rhs.startedAt ?? 0
                if leftTime != rightTime { return leftTime > rightTime }
                return lhs.id < rhs.id
            }
        jobs = rows
        state = .available
    }

    private func markUnavailable() {
 // A normal stop() clears the handle first; only an unexpected end marks
 // the roster unavailable.
        guard stream != nil else { return }
        stream = nil
 // code review P3: drop the last frame too. Keeping the rows
 // behind an "unavailable" state rendered stale jobs whose Stop buttons
 // could no longer succeed (and kept the entry capsule's live ring lit).
        jobs = []
        state = .unavailable
    }
}
