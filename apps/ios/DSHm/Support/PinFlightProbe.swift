#if DEBUG
import Foundation
import QuartzCore

/// DEBUG-only 置顶/取消置顶逐帧探针（DD-17，测试方案 §3.0 帧级判据的真值来源）。
///
/// 默认零开销：`DSHM_PIN_PROBE=1` 未设置时 `shared == nil`，所有调用点 no-op；
/// 生产构建里整个类型不存在（本文件整体 `#if DEBUG`）。
///
/// 每次 App 启动写**一个独立文件** `Documents/pin-flight-probe-<epochMillis>.jsonl`，
/// 文件名另存 `pin-flight-probe-latest.txt`（E2E 每个用例都会重启 App，固定文件名
/// 会互相覆盖）。每行一个 JSON 对象，schema（字段名不得改）：
/// - `{"type":"probeStart","t0":<毫秒>}`（t0 = CACurrentMediaTime × 1000 取整）
/// - `{"type":"click","t":<毫秒>,"action":"pin"|"unpin","sid":"<id>","groupsVersion":<n>}`
/// - `{"type":"tick","t":<毫秒>,"flight":[x,y,w,h]|null,"targetOpacity":<0..1>,
/// "sourceVisible":<bool>,"railVisible":<bool>,"groupsVersion":<n>}`
/// - `{"type":"settle","t":<毫秒>,"action":"pin"|"unpin","reason":"finished"|"interrupted"|"failed"}`
///
/// 只记录点击前后 ±600ms 的 tick（点击前的帧来自 1.5s 环形缓冲）。`flight` 用
/// **列表内容坐标**（与行几何同一个命名坐标空间），不是屏幕绝对坐标；飞行卡由
/// `PinFlightFrameRecorder`（GeometryEffect 逐帧写入）提供真值。
@MainActor
final class PinFlightProbe {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["DSHM_PIN_PROBE"] == "1"
    static let shared: PinFlightProbe? = isEnabled ? PinFlightProbe() : nil

 /// 点击前/后各保留的窗口。
    private static let windowSeconds: Double = 0.6
 /// 点击前 tick 的环形缓冲长度。
    private static let ringSeconds: Double = 1.5

 /// 飞行卡逐帧渲染真值（GeometryEffect 写入）。
    let frameRecorder = PinFlightFrameRecorder()

    private var fileHandle: FileHandle?
    private var ticker: CADisplayLink?
    private var pendingLines: [String] = []
    private var lastFlush = Date.distantPast
    private var bufferedTicks: [(t: Double, line: String)] = []
    private var windowStart: Double = -.greatestFiniteMagnitude
    private var windowEnd: Double = -.greatestFiniteMagnitude

 // 视图绑定的真值来源（全部读列表侧状态，不重复渲染）。
    private var targetOpacityProvider: (() -> Double)?
    private var sourceVisibleProvider: (() -> Bool)?
    private var railVisibleProvider: (() -> Bool)?
    private var groupsVersionProvider: (() -> Int)?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = "pin-flight-probe-\(stamp).jsonl"
        let url = documents.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        try? name.write(
            to: documents.appendingPathComponent("pin-flight-probe-latest.txt"),
            atomically: true,
            encoding: .utf8
        )
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
        write(line: "{\"type\":\"probeStart\",\"t0\":\(Self.millis())}")
    }

 /// 列表侧真值来源（列表视图 `.task` 里绑定一次）。
    func bind(
        targetOpacity: @escaping () -> Double,
        sourceVisible: @escaping () -> Bool,
        railVisible: @escaping () -> Bool,
        groupsVersion: @escaping () -> Int
    ) {
        targetOpacityProvider = targetOpacity
        sourceVisibleProvider = sourceVisible
        railVisibleProvider = railVisible
        groupsVersionProvider = groupsVersion
    }

 /// 一次置顶/取消置顶的点击（记录点击前的窗口帧 + click 行，打开 ±600ms 窗口）。
    func click(action: String, sessionId: String, groupsVersion: Int) {
        let now = Self.now()
        let since = now - Self.windowSeconds
        for buffered in bufferedTicks where buffered.t >= since {
            pendingLines.append(buffered.line)
        }
        bufferedTicks.removeAll()
        write(line: "{\"type\":\"click\",\"t\":\(Self.millis()),"
            + "\"action\":\"\(action)\",\"sid\":\"\(Self.escape(sessionId))\","
            + "\"groupsVersion\":\(groupsVersion)}")
        windowStart = since
        windowEnd = now + Self.windowSeconds
    }

 /// 一段操作结束（飞行落位 / 被打断 / 请求被拒）。
    func settle(action: String, reason: String) {
        windowStart = -.greatestFiniteMagnitude
        windowEnd = -.greatestFiniteMagnitude
        flush(force: true)
        write(line: "{\"type\":\"settle\",\"t\":\(Self.millis()),"
            + "\"action\":\"\(action)\",\"reason\":\"\(reason)\"}")
        flush(force: true)
    }

 // MARK: - 逐帧

    @objc private func tick() {
        let now = Self.now()
        if now >= windowStart, now <= windowEnd {
            write(line: tickLine(t: now))
            return
        }
        if windowEnd > 0 || windowStart > 0 {
 // 窗口刚结束：收尾落盘，之后回到环形缓冲。
            windowStart = -.greatestFiniteMagnitude
            windowEnd = -.greatestFiniteMagnitude
            flush(force: true)
        }
 // 点击前：环形缓冲（供下一次 click 补写 ±600ms 的“前”半段）。
        bufferedTicks.append((t: now, line: tickLine(t: now)))
        let cutoff = now - Self.ringSeconds
        bufferedTicks.removeAll { $0.t < cutoff }
    }

    private func tickLine(t: Double) -> String {
        let flight: String
        if let rect = frameRecorder.rect {
            flight = String(
                format: "[%.2f,%.2f,%.2f,%.2f]",
                rect.minX, rect.minY, rect.width, rect.height
            )
        } else {
            flight = "null"
        }
        let opacity = min(max(targetOpacityProvider?() ?? 1, 0), 1)
        let sourceVisible = (sourceVisibleProvider?() ?? false) ? "true" : "false"
        let railVisible = (railVisibleProvider?() ?? false) ? "true" : "false"
        let version = groupsVersionProvider?() ?? 0
        return String(
            format: "{\"type\":\"tick\",\"t\":%.0f,\"flight\":%@,"
                + "\"targetOpacity\":%.3f,\"sourceVisible\":%@,"
                + "\"railVisible\":%@,\"groupsVersion\":%d}",
            t * 1000, flight, opacity, sourceVisible, railVisible, version
        )
    }

 // MARK: - 落盘

    private func write(line: String) {
        pendingLines.append(line)
        flush(force: false)
    }

    private func flush(force: Bool) {
        guard !pendingLines.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastFlush) > 0.2 else { return }
        pendingLines.append("")
        let text = pendingLines.joined(separator: "\n")
        pendingLines.removeAll()
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(Data(text.utf8))
        lastFlush = Date()
    }

 // MARK: - 时钟/转义

    private static func now() -> Double {
        CACurrentMediaTime()
    }

    private static func millis() -> Int {
        Int((CACurrentMediaTime() * 1000).rounded())
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif

#if DEBUG
/// 临时调试日志（`DSHM_SWIPE_DEBUG=1`）：左滑回弹/行重建问题定位用，定位完删除。
enum SwipeDebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["DSHM_SWIPE_DEBUG"] == "1"
    private static var handle: FileHandle?

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let url = dir?.appendingPathComponent("swipe-debug.log")
            if let url {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
            }
        }
        handle?.seekToEndOfFile()
        handle?.write(data)
    }
}
#endif
