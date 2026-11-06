import Darwin
import Foundation

/// Builds the iPhone network-log export package (DD-06 / DD-14).
///
/// The writer takes a byte snapshot of the log directory on its own serial queue and
/// hands over `Snapshot` describing *staged copies*. Everything expensive — parsing,
/// summarizing, CRC32, ZIP assembly — then happens off that queue, so connections are
/// never blocked by a 20 MB export (DD-15).
///
/// Archive layout:
/// - `events/<hour shard>.ndjson`   (verbatim copies, all retained shards)
/// - `incidents/<unixms>-<trace>.ndjson` (incident snapshots, when any)
/// - `metadata.json`                (machine readable, see `metadata(...)` below)
/// - `summary.txt`                  (human readable: window, counts, rounds, incidents)
enum NetworkLogExport {
    /// One staged log file plus its archive-relative name.
    struct FileInfo: Sendable {
        /// Archive-relative path, e.g. `events/events-2026110606.ndjson`.
        let name: String
        /// Staged copy on disk (never the live writer file).
        let path: URL
        let bytes: Int
    }

    /// Immutable input for one export. Produced on the writer queue.
    struct Snapshot: Sendable {
        let stagingDirectory: URL
        let eventFiles: [FileInfo]
        let incidentFiles: [FileInfo]
        let generatedAt: Date
    }

    static let exportDirectoryName = "NetworkLogExport"

    /// `Library/Caches/NetworkLogExport/` — cleared at launch, one archive per export.
    static var temporaryDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches.appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    // MARK: - Temporary files

    @discardableResult
    static func prepareTemporaryDirectory() -> URL? {
        let manager = FileManager.default
        let directory = temporaryDirectory
        if !manager.fileExists(atPath: directory.path) {
            guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
                NSLog("[NetworkLogExport] cannot create \(directory.path)")
                return nil
            }
        }
        return directory
    }

    /// Removes every file and staging directory left over from a previous run.
    static func clearTemporaryFiles() {
        let manager = FileManager.default
        let directory = temporaryDirectory
        guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            try? manager.removeItem(at: item)
        }
    }

    /// Deletes one finished export (share sheet dismissed) but nothing outside the
    /// export directory — the caller passes the URL the writer returned.
    static func discard(_ url: URL) {
        let root = temporaryDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func makeStagingDirectory() throws -> URL {
        guard let directory = prepareTemporaryDirectory() else {
            throw NetworkLogError.storageUnavailable
        }
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw NetworkLogError.exportFailed("create staging: \(error)")
        }
        return staging
    }

    // MARK: - Build

    /// Assembles the ZIP from a staged snapshot and returns its URL in
    /// `Library/Caches/NetworkLogExport/`. Removes the staging directory on exit.
    static func build(snapshot: Snapshot) throws -> URL {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: snapshot.stagingDirectory) }
        guard let directory = prepareTemporaryDirectory() else {
            throw NetworkLogError.storageUnavailable
        }

        var eventEntries: [(name: String, data: Data)] = []
        var eventBytes = 0
        var totalEventLines = 0
        var hourCounts: [(name: String, lines: Int)] = []
        var rounds: [RoundSummary] = []
        var roundIndex: [String: Int] = [:]
        var windowFrom: String?
        var windowTo: String?

        for file in snapshot.eventFiles {
            let data = try Data(contentsOf: file.path)
            eventEntries.append((file.name, data))
            eventBytes += data.count
            let lines = countLines(data)
            totalEventLines += lines
            hourCounts.append((URL(fileURLWithPath: file.name).lastPathComponent, lines))
            parseRounds(
                data: data,
                rounds: &rounds,
                index: &roundIndex,
                windowFrom: &windowFrom,
                windowTo: &windowTo
            )
        }

        var incidentEntries: [(name: String, data: Data)] = []
        var incidents: [IncidentSummary] = []
        for file in snapshot.incidentFiles {
            let data = try Data(contentsOf: file.path)
            incidentEntries.append((file.name, data))
            incidents.append(incidentSummary(for: file, data: data))
        }

        let appVersion = appVersion()
        let osVersion = operatingSystemVersion()
        let model = hardwareModel()
        let generatedAt = snapshot.generatedAt

        let metadata = metadataJSON(
            generatedAt: generatedAt,
            appVersion: appVersion,
            osVersion: osVersion,
            model: model,
            eventFiles: snapshot.eventFiles,
            incidentFiles: snapshot.incidentFiles,
            eventCount: totalEventLines,
            incidentCount: incidents.count
        )
        let summary = summaryText(
            generatedAt: generatedAt,
            appVersion: appVersion,
            osVersion: osVersion,
            model: model,
            windowFrom: windowFrom,
            windowTo: windowTo,
            totalEventLines: totalEventLines,
            eventBytes: eventBytes,
            hourCounts: hourCounts,
            rounds: rounds,
            incidents: incidents
        )

        var entries = eventEntries + incidentEntries
        entries.append(("metadata.json", metadata))
        entries.append(("summary.txt", Data(summary.utf8)))

        let archive = try NetworkLogZip.make(entries: entries)
        let url = archiveURL(in: directory, date: generatedAt)
        do {
            try archive.write(to: url, options: .atomic)
        } catch {
            throw NetworkLogError.exportFailed("write archive: \(error)")
        }
        return url
    }

    // MARK: - metadata.json

    private static func metadataJSON(
        generatedAt: Date,
        appVersion: (version: String, build: String),
        osVersion: String,
        model: String,
        eventFiles: [FileInfo],
        incidentFiles: [FileInfo],
        eventCount: Int,
        incidentCount: Int
    ) -> Data {
        var files: [[String: Any]] = []
        for file in eventFiles + incidentFiles {
            files.append(["name": file.name, "bytes": file.bytes])
        }
        let payload: [String: Any] = [
            "schema": "netlog-export/1",
            "app": [
                "version": appVersion.version,
                "build": appVersion.build,
            ],
            // Flat aliases keep the JSON easy to read without nesting (same source).
            "appVersion": appVersion.version,
            "appBuild": appVersion.build,
            "os": osVersion,
            "model": model,
            "generatedAt": iso8601(generatedAt),
            "retention": [
                "eventsHours": Int(NetworkLogWriter.eventsRetention / 3600),
                "eventsMaxBytes": NetworkLogWriter.eventsMaxBytes,
                "incidentsDays": Int(NetworkLogWriter.incidentsRetention / (24 * 3600)),
            ],
            "files": files,
            "counts": [
                "events": eventCount,
                "incidents": incidentCount,
            ],
            // Live network state lives in the `env` event written by the connection
            // layer; the export does not read live state (kept empty on purpose).
            "network": [] as [Any],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }

    // MARK: - summary.txt

    private struct RoundSummary {
        let trace: String
        let startTS: String
        var reason: String?
        var outcome: String?
        var elapsedMs: Int?
        var connectMs: Int?
        var switchTotalMs: Int?
        var failures: Int?
    }

    private struct IncidentSummary {
        let name: String
        let bytes: Int
        let startedAt: Date?
        let kind: String?
        let totalMs: Int?
    }

    private static func summaryText(
        generatedAt: Date,
        appVersion: (version: String, build: String),
        osVersion: String,
        model: String,
        windowFrom: String?,
        windowTo: String?,
        totalEventLines: Int,
        eventBytes: Int,
        hourCounts: [(name: String, lines: Int)],
        rounds: [RoundSummary],
        incidents: [IncidentSummary]
    ) -> String {
        var lines: [String] = []
        lines.append("DSH-m 网络日志导出摘要")
        lines.append("生成时间: \(localTimestamp(generatedAt))（\(iso8601(generatedAt))）")
        lines.append("App: \(appVersion.version) (\(appVersion.build))")
        lines.append("系统: \(osVersion)")
        lines.append("机型: \(model)")
        let window = "\(windowFrom ?? "—") ~ \(windowTo ?? "—")"
        lines.append("日志窗口: \(window)")
        lines.append(
            "全量事件: \(totalEventLines) 行 / \(fileSize(eventBytes))"
                + "（保留最近 72 小时，上限 20 MB）"
        )
        lines.append("异常快照: \(incidents.count) 个（保留最近 7 天，不计入 20 MB）")
        lines.append("按小时计数:")
        if hourCounts.isEmpty {
            lines.append("  （无）")
        } else {
            for hour in hourCounts {
                lines.append("  \(hour.name)  \(hour.lines) 行")
            }
        }

        let recentRounds = rounds.suffix(100)
        lines.append("最近连接轮次（最多 100 轮）:")
        if recentRounds.isEmpty {
            lines.append("  （无）")
        } else {
            for (index, round) in recentRounds.enumerated() {
                lines.append("  \(index + 1)) " + roundLine(round))
            }
        }

        lines.append("异常快照清单:")
        if incidents.isEmpty {
            lines.append("  （无）")
        } else {
            for incident in incidents {
                var line = "  \(incident.name)"
                if let startedAt = incident.startedAt {
                    line += "  " + localTimestamp(startedAt)
                }
                if let kind = incident.kind {
                    line += "  kind=\(kind)"
                }
                if let totalMs = incident.totalMs {
                    line += "  totalMs=\(totalMs)"
                }
                line += "  \(fileSize(incident.bytes))"
                lines.append(line)
            }
        }

        lines.append("隐私说明: 仅本机生成、不含正文/凭据。")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func roundLine(_ round: RoundSummary) -> String {
        let result = round.outcome ?? (round.connectMs != nil ? "connected" : "—")
        let total = round.switchTotalMs ?? round.elapsedMs ?? round.connectMs
        var line = "\(round.startTS.isEmpty ? "—" : round.startTS)  trace=\(round.trace.isEmpty ? "—" : round.trace)"
        line += "  reason=\(round.reason ?? "—")  result=\(result)"
        line += "  总耗时=\(total.map { "\($0) ms" } ?? "—")"
        if let failures = round.failures {
            line += "  失败候选=\(failures)"
        }
        return line
    }

    // MARK: - Event parsing

    private static func parseRounds(
        data: Data,
        rounds: inout [RoundSummary],
        index: inout [String: Int],
        windowFrom: inout String?,
        windowTo: inout String?
    ) {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                continue
            }
            if let ts = object["ts"] as? String {
                if windowFrom.map({ ts < $0 }) ?? true { windowFrom = ts }
                if windowTo.map({ ts > $0 }) ?? true { windowTo = ts }
            }
            guard let event = object["ev"] as? String else { continue }
            let trace = object["trace"] as? String ?? ""
            switch event {
            case "round.start":
                var round = RoundSummary(trace: trace, startTS: object["ts"] as? String ?? "")
                round.reason = object["reason"] as? String
                rounds.append(round)
                if !trace.isEmpty { index[trace] = rounds.count - 1 }
            case "connected":
                guard let position = index[trace], rounds.indices.contains(position) else { continue }
                rounds[position].connectMs = intValue(object["connectMs"])
            case "switch.reconnect":
                guard let position = index[trace], rounds.indices.contains(position) else { continue }
                rounds[position].switchTotalMs = intValue(object["totalMs"])
                rounds[position].outcome = object["outcome"] as? String ?? rounds[position].outcome
            case "round.end":
                guard let position = index[trace], rounds.indices.contains(position) else { continue }
                rounds[position].outcome = object["outcome"] as? String
                rounds[position].elapsedMs = intValue(object["elapsedMs"])
                rounds[position].failures = (object["failures"] as? [Any])?.count
            default:
                continue
            }
        }
    }

    private static func incidentSummary(for file: FileInfo, data: Data) -> IncidentSummary {
        // The snapshot starts with the replayed 60 s window, which can already
        // contain *another* incident's trigger line. Match the trigger by the trace
        // encoded in this file's name, falling back to the first trigger seen.
        let expectedTrace = traceFromIncidentName(file.name)
        var kind: String?
        var totalMs: Int?
        var fallbackKind: String?
        var fallbackTotalMs: Int?
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["ev"] as? String == "incident.trigger" else { continue }
            let trace = object["trace"] as? String
            let matches = expectedTrace != nil && (trace == expectedTrace
                || (trace.map { expectedTrace!.hasPrefix($0 + "-") } ?? false))
            if fallbackKind == nil {
                fallbackKind = object["kind"] as? String
                fallbackTotalMs = intValue(object["totalMs"])
            }
            if matches {
                kind = object["kind"] as? String
                totalMs = intValue(object["totalMs"])
                break
            }
        }
        return IncidentSummary(
            name: file.name,
            bytes: file.bytes,
            startedAt: incidentStartDate(file.name),
            kind: kind ?? fallbackKind,
            totalMs: totalMs ?? fallbackTotalMs
        )
    }

    /// `<unixms>-<trace>[-<suffix>].ndjson` -> trace.
    private static func traceFromIncidentName(_ name: String) -> String? {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let parts = base.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// Incident files are named `<unixms>-<trace>.ndjson`.
    private static func incidentStartDate(_ name: String) -> Date? {
        let base = URL(fileURLWithPath: name).lastPathComponent
        guard let prefix = base.split(separator: "-").first, let millis = Int64(prefix) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // MARK: - Small helpers

    private static func countLines(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var lines = 0
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) where byte == 0x0A { lines += 1 }
        }
        if data.last != 0x0A { lines += 1 }
        return lines
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    private static func archiveURL(in directory: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let base = "dshm-network-log-" + formatter.string(from: date)
        var url = directory.appendingPathComponent(base + ".zip")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).zip")
            suffix += 1
        }
        return url
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func localTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: date)
    }

    private static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func appVersion() -> (version: String, build: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return (version, build)
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: machine)
    }
}
