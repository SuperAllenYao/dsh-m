import Foundation

/// Errors surfaced by the network-log pipeline. The settings row only needs to know
/// "export failed", but callers and tests get a real reason.
enum NetworkLogError: Error {
    /// No event shard with content — the caller should have disabled the row.
    case noEvents
    /// Application Support / Caches directory could not be created.
    case storageUnavailable
    /// The archive could not be assembled or written.
    case exportFailed(String)
}

/// Always-on network connection log writer (DD-01 / DD-02 / DD-13 / DD-15).
///
/// Storage (root `Library/Application Support/NetworkLog/`, backup-excluded):
/// - `events/events-YYYYMMDDHH.ndjson` — UTC hour shards, append-only, `\n` terminated
/// - `incidents/<unixms>-<trace>.ndjson` — incident snapshots (7 days, no size cap)
///
/// Concurrency: this class is the single writer. Encoding, file appends, retention,
/// incident capture and export snapshotting all run on one serial `utility` queue.
/// `record`/`triggerIncident` only capture the timestamp and enqueue, so connection
/// code never performs synchronous I/O (DD-02). Callers may use any thread.
final class NetworkLogWriter {
    // MARK: Retention constants

    /// Full event log window (AC-07).
    static let eventsRetention: TimeInterval = 72 * 60 * 60
    /// Full event log cap; incidents are explicitly excluded (DEC-09).
    static let eventsMaxBytes = 20 * 1024 * 1024
    /// Incident snapshot retention.
    static let incidentsRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Rolling in-memory window written into a new incident snapshot (AC-06).
    static let incidentWindow: TimeInterval = 60
    /// Retention pass rate limit.
    private static let maintenanceInterval: TimeInterval = 60

    // MARK: Configuration

    let baseDirectory: URL
    private let now: () -> Date
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let timestampFormatter: ISO8601DateFormatter = NetworkLogWriter.makeTimestampFormatter()
    private let hourFormatter: DateFormatter = NetworkLogWriter.makeHourFormatter()

    // MARK: Queue-confined state

    private struct Capture {
        let url: URL
        let handle: FileHandle
        let deadline: Date
    }

    private var didStart = false
    private var didRunStartupHousekeeping = false
    private var currentHourKey: String?
    private var eventsHandle: FileHandle?
    private var currentEventsURL: URL?
    private var currentEventsBytes = 0
    private var rolling: [(ts: Date, line: Data)] = []
    private var captures: [Capture] = []
    private var cachedHasEvents: Bool?
    private var lastMaintenanceAt: Date?
    private var maintenanceTimer: DispatchSourceTimer?

    // MARK: Init

    /// - Parameters:
    ///   - baseDirectory: overrides `Library/Application Support/NetworkLog` (tests).
    ///   - now: injectable clock; timestamps are captured on the caller thread.
    ///   - queue: overrides the internal serial queue (tests).
    init(
        baseDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        queue: DispatchQueue? = nil
    ) {
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory()
        self.now = now
        self.queue = queue ?? DispatchQueue(label: "com.dshm.networklog.writer", qos: .utility)
        self.queue.setSpecific(key: queueKey, value: ())
    }

    /// Compatibility alias for the `writerQueue:` label used in the implementation
    /// record (T-04 interface note). Prefer the `queue:` initializer.
    convenience init(
        baseDirectory: URL,
        now: @escaping () -> Date = Date.init,
        writerQueue: DispatchQueue?
    ) {
        self.init(baseDirectory: baseDirectory, now: now, queue: writerQueue)
    }

    deinit {
        maintenanceTimer?.setEventHandler {}
        maintenanceTimer?.cancel()
        try? eventsHandle?.close()
        for capture in captures { try? capture.handle.close() }
    }

    // MARK: Paths

    static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support.appendingPathComponent("NetworkLog", isDirectory: true)
    }

    var eventsDirectory: URL { baseDirectory.appendingPathComponent("events", isDirectory: true) }
    var incidentsDirectory: URL { baseDirectory.appendingPathComponent("incidents", isDirectory: true) }

    // MARK: Public API

    /// Idempotent. Called once per process at launch and again when the app returns
    /// to the foreground; each call also runs the rate-limited retention pass.
    func start() {
        sync {
            let firstStart = !self.didStart
            self.ensureStartedOnQueue()
            if firstStart {
                NetworkLogExport.clearTemporaryFiles()
            }
            self.scheduleMaintenanceTimerIfNeeded()
            self.runMaintenanceOnQueueIfNeeded(force: !self.didRunStartupHousekeeping)
            self.didRunStartupHousekeeping = true
        }
    }

    /// Appends one event. Non-blocking: only the timestamp and the field dictionary
    /// are captured here; JSON encoding and the file write happen on the writer queue.
    func record(_ event: String, _ fields: [String: Any]) {
        let timestamp = now()
        queue.async { [weak self] in
            self?.appendOnQueue(event: event, fields: fields, at: timestamp)
        }
    }

    /// Drains the writer queue (called when the app moves to the background). File
    /// handles write straight through to the kernel, so no `fsync` is issued (DD-02).
    func flush() {
        sync {
            let timestamp = self.now()
            self.closeExpiredCaptures(at: timestamp)
            self.pruneRolling(at: timestamp)
        }
    }

    /// Starts an incident snapshot: writes `incident.trigger`, opens an independent
    /// file, replays the last 60 s of events, then keeps appending for 60 s (AC-06).
    /// Concurrent triggers each get their own file; nothing is dropped.
    func triggerIncident(trace: String, kind: String, totalMs: Int) {
        let timestamp = now()
        queue.async { [weak self] in
            self?.triggerIncidentOnQueue(trace: trace, kind: kind, totalMs: totalMs, at: timestamp)
        }
    }

    /// Cheap availability probe for the settings row (DD-16); the result is cached
    /// after writes and retention passes, so this is a stat scan at most once.
    func hasEvents() -> Bool {
        sync {
            self.ensureStartedOnQueue()
            if let cached = self.cachedHasEvents { return cached }
            let value = self.eventsDirectoryHasContent()
            self.cachedHasEvents = value
            return value
        }
    }

    /// Snapshot on the writer queue, then build the ZIP off-queue. Returns
    /// `Library/Caches/NetworkLogExport/dshm-network-log-YYYYMMDD-HHMM.zip`.
    func exportZip() async throws -> URL {
        let snapshot = try sync { try self.makeSnapshotOnQueue() }
        return try await Task.detached(priority: .utility) {
            try NetworkLogExport.build(snapshot: snapshot)
        }.value
    }

    // MARK: Queue plumbing

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    private func ensureStartedOnQueue() {
        guard !didStart else { return }
        didStart = true
        ensureDirectory(baseDirectory)
        ensureDirectory(eventsDirectory)
        ensureDirectory(incidentsDirectory)
        markExcludedFromBackup(baseDirectory)
        markExcludedFromBackup(eventsDirectory)
        markExcludedFromBackup(incidentsDirectory)
    }

    private func scheduleMaintenanceTimerIfNeeded() {
        guard maintenanceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.maintenanceInterval,
            repeating: Self.maintenanceInterval,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceOnQueueIfNeeded(force: false)
        }
        timer.resume()
        maintenanceTimer = timer
    }

    // MARK: Writing

    private func appendOnQueue(event: String, fields: [String: Any], at timestamp: Date) {
        ensureStartedOnQueue()
        guard let line = encodeLine(event, fields, at: timestamp) else { return }
        appendToRolling(line, at: timestamp)
        writeEventLine(line, at: timestamp)
        writeToCaptures(line, at: timestamp)
    }

    /// One NDJSON line with a stable prefix (`{"ts":"…","ev":"…",…}`) so retention
    /// can compare timestamps as plain ISO8601 strings without parsing JSON.
    private func encodeLine(_ event: String, _ fields: [String: Any], at timestamp: Date) -> Data? {
        var parts: [String] = []
        parts.reserveCapacity(fields.count + 2)
        parts.append("\"ts\":" + Self.jsonString(self.timestampFormatter.string(from: timestamp)))
        parts.append("\"ev\":" + Self.jsonString(event))
        for key in fields.keys.sorted() {
            guard let value = fields[key], let fragment = Self.jsonFragment(value) else { continue }
            parts.append(Self.jsonString(key) + ":" + fragment)
        }
        let text = "{" + parts.joined(separator: ",") + "}\n"
        return Data(text.utf8)
    }

    private func appendToRolling(_ line: Data, at timestamp: Date) {
        rolling.append((timestamp, line))
        pruneRolling(at: timestamp)
    }

    private func pruneRolling(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-Self.incidentWindow)
        if let firstRecent = rolling.firstIndex(where: { $0.ts >= cutoff }) {
            if firstRecent > 0 { rolling.removeFirst(firstRecent) }
        } else if !rolling.isEmpty {
            rolling.removeAll(keepingCapacity: true)
        }
    }

    private func writeEventLine(_ line: Data, at timestamp: Date) {
        let hourKey = hourFormatter.string(from: timestamp)
        if hourKey != currentHourKey {
            let rotated = currentHourKey != nil
            closeEventsHandle()
            currentHourKey = hourKey
            openEventsHandle(forHourKey: hourKey)
            if rotated {
                runMaintenanceOnQueueIfNeeded(force: false)
            }
        }
        if eventsHandle == nil {
            openEventsHandle(forHourKey: hourKey)
        }
        guard let handle = eventsHandle else { return }
        do {
            try handle.write(contentsOf: line)
            currentEventsBytes += line.count
            cachedHasEvents = true
        } catch {
            NSLog("[NetworkLog] event write failed: \(error)")
            closeEventsHandle()
            currentHourKey = nil
        }
    }

    private func openEventsHandle(forHourKey key: String) {
        ensureDirectory(eventsDirectory)
        let manager = FileManager.default
        let url = eventsDirectory.appendingPathComponent("events-\(key).ndjson")
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                NSLog("[NetworkLog] cannot create \(url.path)")
                return
            }
            markExcludedFromBackup(url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("[NetworkLog] cannot open \(url.path)")
            return
        }
        do {
            _ = try handle.seekToEnd()
        } catch {
            NSLog("[NetworkLog] seek failed: \(error)")
            try? handle.close()
            return
        }
        eventsHandle = handle
        currentEventsURL = url
        currentEventsBytes = fileSize(at: url)
        cachedHasEvents = true
    }

    private func closeEventsHandle() {
        try? eventsHandle?.close()
        eventsHandle = nil
        currentEventsURL = nil
        currentEventsBytes = 0
    }

    /// Compares by file name: the writer owns the only file in the shard directory
    /// with that name, and name comparison avoids symlink-normalization differences
    /// between `URL`s built by hand and `FileManager`.
    private func isCurrentEventsFile(_ url: URL) -> Bool {
        guard let current = currentEventsURL else { return false }
        return url.lastPathComponent == current.lastPathComponent
    }

    // MARK: Incident snapshots

    private func triggerIncidentOnQueue(trace: String, kind: String, totalMs: Int, at timestamp: Date) {
        ensureStartedOnQueue()
        let safeTrace = Self.sanitizedTrace(trace)
        let fields: [String: Any] = [
            "trace": safeTrace,
            "kind": kind,
            "totalMs": totalMs,
            "windowMs": Int(Self.incidentWindow * 1000),
        ]
        if let line = encodeLine("incident.trigger", fields, at: timestamp) {
            appendToRolling(line, at: timestamp)
            writeEventLine(line, at: timestamp)
            writeToCaptures(line, at: timestamp)
        }

        ensureDirectory(incidentsDirectory)
        let manager = FileManager.default
        let millis = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        let url = uniqueIncidentURL(millis: millis, trace: safeTrace)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            NSLog("[NetworkLog] cannot create incident \(url.path)")
            return
        }
        markExcludedFromBackup(url)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("[NetworkLog] cannot open incident \(url.path)")
            return
        }
        _ = try? handle.seekToEnd()
        // Replay the rolling window: everything from the last 60 s precedes the trigger.
        for entry in rolling {
            do {
                try handle.write(contentsOf: entry.line)
            } catch {
                NSLog("[NetworkLog] incident write failed: \(error)")
                try? handle.close()
                return
            }
        }
        captures.append(Capture(
            url: url,
            handle: handle,
            deadline: timestamp.addingTimeInterval(Self.incidentWindow)
        ))
        runMaintenanceOnQueueIfNeeded(force: false)
    }

    private func writeToCaptures(_ line: Data, at timestamp: Date) {
        guard !captures.isEmpty else { return }
        var index = captures.count - 1
        while index >= 0 {
            let capture = captures[index]
            if timestamp >= capture.deadline {
                try? capture.handle.close()
                captures.remove(at: index)
            } else {
                do {
                    try capture.handle.write(contentsOf: line)
                } catch {
                    NSLog("[NetworkLog] incident write failed: \(error)")
                    try? capture.handle.close()
                    captures.remove(at: index)
                }
            }
            index -= 1
        }
    }

    private func closeExpiredCaptures(at timestamp: Date) {
        guard !captures.isEmpty else { return }
        var index = captures.count - 1
        while index >= 0 {
            if timestamp >= captures[index].deadline {
                try? captures[index].handle.close()
                captures.remove(at: index)
            }
            index -= 1
        }
    }

    private func uniqueIncidentURL(millis: Int64, trace: String) -> URL {
        let base = "\(millis)-\(trace)"
        var url = incidentsDirectory.appendingPathComponent(base + ".ndjson")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = incidentsDirectory.appendingPathComponent("\(base)-\(suffix).ndjson")
            suffix += 1
        }
        return url
    }

    // MARK: Retention (DD-03)

    private func runMaintenanceOnQueueIfNeeded(force: Bool) {
        let currentDate = now()
        // Closing expired captures is cheap and time-sensitive: never rate-limit it.
        closeExpiredCaptures(at: currentDate)
        pruneRolling(at: currentDate)

        if !force, let last = lastMaintenanceAt,
           currentDate.timeIntervalSince(last) < Self.maintenanceInterval {
            return
        }
        lastMaintenanceAt = currentDate
        removeExpiredIncidents(at: currentDate)
        trimEvents(at: currentDate)
        cachedHasEvents = eventsDirectoryHasContent()
    }

    private func trimEvents(at currentDate: Date) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var files: [(url: URL, hour: Date)] = []
        for url in urls {
            guard url.lastPathComponent.hasPrefix("events-"),
                  url.pathExtension == "ndjson",
                  let hour = hourDate(from: url) else { continue }
            files.append((url, hour))
        }
        files.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }

        let cutoff = currentDate.addingTimeInterval(-Self.eventsRetention)
        let cutoffString = timestampFormatter.string(from: cutoff)

        // 1. Whole shards entirely older than the window.
        for file in files where file.hour.addingTimeInterval(3600) <= cutoff {
            removeEventsFile(file.url)
        }
        // 2. The shard straddling the cutoff: rewrite it without older lines.
        for file in files where file.hour < cutoff && file.hour.addingTimeInterval(3600) > cutoff {
            guard !isCurrentEventsFile(file.url) else { continue }
            trimLines(in: file.url, olderThan: cutoffString)
        }
        // 3. 20 MB cap over the event shards only (incidents are excluded).
        enforceEventSizeLimit()
    }

    private func removeEventsFile(_ url: URL) {
        if isCurrentEventsFile(url) {
            closeEventsHandle()
            currentHourKey = nil
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func trimLines(in url: URL, olderThan cutoff: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        var kept = Data()
        kept.reserveCapacity(data.count)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let timestamp = Self.timestampPrefix(of: line), timestamp < cutoff { continue }
            kept.append(line)
            kept.append(0x0A)
        }
        guard kept.count != data.count else { return }
        do {
            try kept.write(to: url, options: .atomic)
        } catch {
            NSLog("[NetworkLog] trim failed: \(error)")
        }
    }

    private func enforceEventSizeLimit() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let files: [(url: URL, bytes: Int)] = urls
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "ndjson" }
            .map { ($0, fileSize(at: $0)) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > Self.eventsMaxBytes else { return }

        for file in files {
            guard total > Self.eventsMaxBytes else { break }
            if isCurrentEventsFile(file.url) {
                let otherBytes = total - file.bytes
                let removed = truncateEventsFile(file.url, keepingLastBytes: Self.eventsMaxBytes - otherBytes)
                total -= removed
            } else {
                try? manager.removeItem(at: file.url)
                total -= file.bytes
            }
        }
    }

    /// Keeps the newest `keepingLastBytes` of the live shard (aligned to a line
    /// start), then leaves it closed so the next write reopens it.
    @discardableResult
    private func truncateEventsFile(_ url: URL, keepingLastBytes: Int) -> Int {
        closeEventsHandle()
        currentHourKey = nil
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let keep = max(0, min(keepingLastBytes, data.count))
        var start = data.count - keep
        if start > 0 {
            if let newline = data[start...].firstIndex(of: 0x0A) {
                start = data.index(after: newline)
            } else {
                start = data.count
            }
        }
        let kept = data.subdata(in: start..<data.count)
        try? kept.write(to: url, options: .atomic)
        return data.count - kept.count
    }

    private func removeExpiredIncidents(at currentDate: Date) {
        let manager = FileManager.default
        let cutoffMillis = Int64(
            (currentDate.addingTimeInterval(-Self.incidentsRetention).timeIntervalSince1970 * 1000).rounded()
        )
        guard let urls = try? manager.contentsOfDirectory(
            at: incidentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            guard let prefix = base.split(separator: "-").first, let millis = Int64(prefix) else { continue }
            guard millis < cutoffMillis else { continue }
            if let index = captures.firstIndex(where: { $0.url == url }) {
                try? captures[index].handle.close()
                captures.remove(at: index)
            }
            try? manager.removeItem(at: url)
        }
    }

    // MARK: Export snapshot (DD-15)

    private func makeSnapshotOnQueue() throws -> NetworkLogExport.Snapshot {
        ensureStartedOnQueue()
        let manager = FileManager.default
        closeExpiredCaptures(at: now())

        let events = eventFilesOnDisk()
        let incidents = incidentFilesOnDisk()
        guard !events.isEmpty else { throw NetworkLogError.noEvents }

        let staging = try NetworkLogExport.makeStagingDirectory()
        do {
            let eventDirectory = staging.appendingPathComponent("events", isDirectory: true)
            try manager.createDirectory(at: eventDirectory, withIntermediateDirectories: true)
            var eventFiles: [NetworkLogExport.FileInfo] = []
            for url in events {
                let destination = eventDirectory.appendingPathComponent(url.lastPathComponent)
                // No writer is running: the copy is a byte-exact snapshot, including
                // the still-open shard truncated at its committed length.
                try manager.copyItem(at: url, to: destination)
                eventFiles.append(NetworkLogExport.FileInfo(
                    name: "events/" + url.lastPathComponent,
                    path: destination,
                    bytes: fileSize(at: destination)
                ))
            }

            var incidentFiles: [NetworkLogExport.FileInfo] = []
            if !incidents.isEmpty {
                let incidentDirectory = staging.appendingPathComponent("incidents", isDirectory: true)
                try manager.createDirectory(at: incidentDirectory, withIntermediateDirectories: true)
                for url in incidents {
                    let destination = incidentDirectory.appendingPathComponent(url.lastPathComponent)
                    try manager.copyItem(at: url, to: destination)
                    incidentFiles.append(NetworkLogExport.FileInfo(
                        name: "incidents/" + url.lastPathComponent,
                        path: destination,
                        bytes: fileSize(at: destination)
                    ))
                }
            }

            return NetworkLogExport.Snapshot(
                stagingDirectory: staging,
                eventFiles: eventFiles,
                incidentFiles: incidentFiles,
                generatedAt: now()
            )
        } catch {
            try? manager.removeItem(at: staging)
            if let networkLogError = error as? NetworkLogError { throw networkLogError }
            throw NetworkLogError.exportFailed("snapshot: \(error)")
        }
    }

    private func eventFilesOnDisk() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func incidentFilesOnDisk() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: incidentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func eventsDirectoryHasContent() -> Bool {
        eventFilesOnDisk().contains { fileSize(at: $0) > 0 }
    }

    // MARK: Small helpers

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    @discardableResult
    private func ensureDirectory(_ url: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return true }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("[NetworkLog] cannot create \(url.path): \(error)")
            return false
        }
    }

    private func markExcludedFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func hourDate(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("events-") else { return nil }
        return hourFormatter.date(from: String(name.dropFirst("events-".count)))
    }

    private static func timestampPrefix(of line: Data) -> String? {
        let marker = Data("\"ts\":\"".utf8)
        guard let range = line.range(of: marker),
              let end = line[range.upperBound...].firstIndex(of: 0x22) else { return nil }
        return String(data: line[range.upperBound..<end], encoding: .utf8)
    }

    private static func sanitizedTrace(_ trace: String) -> String {
        let allowed = trace.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
        let text = String(String.UnicodeScalarView(allowed.prefix(40)))
        return text.isEmpty ? "unknown" : text
    }

    private static func jsonString(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func jsonFragment(_ value: Any) -> String? {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        // Unsupported value (NaN, Date, …): fall back to its description so a single
        // odd field can never drop the whole event line.
        return jsonString(String(describing: value))
    }

    private static func makeTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func makeHourFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMddHH"
        return formatter
    }
}

/// Fire-and-forget facade used by the connection layer (T-02) and the settings row.
enum NetworkLog {
    static let writer = NetworkLogWriter()

    static func start() {
        writer.start()
    }

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        writer.record(event, fields)
    }

    static func flush() {
        writer.flush()
    }

    static func triggerIncident(trace: String, kind: String, totalMs: Int) {
        writer.triggerIncident(trace: trace, kind: kind, totalMs: totalMs)
    }

    static func hasEvents() -> Bool {
        writer.hasEvents()
    }

    static func exportZip() async throws -> URL {
        try await writer.exportZip()
    }
}
