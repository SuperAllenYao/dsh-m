#if DEBUG
import Foundation
import QuartzCore

/// DEBUG 性能探针：`DSHM_PERFDBG=1` 时把主线程重活的耗时写成 NDJSON
/// （Documents/perf-<epoch>.jsonl），用于真机滑动卡顿归因。
///
/// - 默认零开销：未设置 env 时 `enabled == false`，所有调用点直接走 body / 直接返回。
/// - 只记录 >= 3ms 的样本，避免日志量影响被测对象。
/// - 写入在独立串行队列，不阻塞调用方（调用方本身通常就在主线程）。
final class PerfProbe {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["DSHM_PERFDBG"] == "1"
    }()

    static let shared = PerfProbe(enabled: isEnabled)

    let enabled: Bool
    private let writeQueue = DispatchQueue(label: "com.dshm.perfprobe.write", qos: .utility)
    private var handle: FileHandle?

    private init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("perf-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write(["type": "start", "t": Date().timeIntervalSince1970])
    }

    /// 记录一条耗时样本（毫秒）。info 会平铺进 JSON 行。
    func record(_ name: String, ms: Double, _ info: [String: Any] = [:]) {
        guard enabled, ms >= 3.0 else { return }
        var payload: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "name": name,
            "ms": (ms * 100).rounded() / 100,
        ]
        for (key, value) in info { payload[key] = value }
        write(payload)
    }

    /// 测量同步 block 的耗时并记录。
    @discardableResult
    func measure<T>(_ name: String, _ info: [String: Any] = [:], _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let started = CACurrentMediaTime()
        let result = try body()
        record(name, ms: (CACurrentMediaTime() - started) * 1000, info)
        return result
    }

    private func write(_ payload: [String: Any]) {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        writeQueue.async {
            if let chunk = line.data(using: .utf8) {
                handle.write(chunk)
            }
        }
    }
}
#endif
