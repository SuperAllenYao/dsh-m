#if DEBUG
import Foundation
import QuartzCore

/// DEBUG-only 帧级卡顿探针。
///
/// 为什么新建而不是复用 ScrollJitterProbe：后者是 UITableView 底座时代的
/// 行位移判定探针，靠注册行 UIView 逐帧采样「行在屏幕上的位置」；当前消息列表
/// 是 SwiftUI ScrollView + LazyVStack（inverted），没有行视图注册点，行位移
/// 判定已不适用。本探针只做与行无关的两件事：
/// 1. **帧节奏**：CADisplayLink 逐帧记录相邻回调的屏幕时间戳差 iv（ms）——
/// 主线程被同步工作占住时回调会合并，iv 直接放大成 33/50/100/300ms；
/// 2. **事件归属**：业务热路径打 mark（history 页拉取/应用、rebuild、窗口扩展、
/// 展开收起动画帧、messageItems 构建、Markdown 解析…），帧行带「最近 mark」，
/// 卡顿帧可自动归因到最近发生的主线程工作。
///
/// 默认零开销：DSHM_HITCHDBG=1 未设置时 shared == nil，所有入口先判 isEnabled，
/// 不建定时器、不写盘、不拼字符串（info 用 autoclosure，关闭时不求值）。
///
/// 输出 Documents/hitch-<epoch>.jsonl（NDJSON，flush 全部在后台串行队列，不干扰
/// 被测主线程）：
/// - frame 行：type/i/t/iv/off/ch/vh/phase/disp/total/pin/lm/lma
/// - mark 行：type/i/t/name/info
///
/// 判读见 apps/ios/scripts/analyze-scroll-hitch.py：帧间隔 p50/p95/p99/max、
/// 用户滚动相位内 >50ms / >100ms 帧计数、卡顿帧最近 mark 归因、滚动期间
/// pageApplied 次数（证明「加载没有因为用户滑动而停」）。
@MainActor
final class ScrollHitchProbe {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["DSHM_HITCHDBG"] == "1"
    }()

    static let shared: ScrollHitchProbe? = isEnabled ? ScrollHitchProbe() : nil

 // MARK: - 零开销量入口

 /// 记一个事件点（无附加信息）。
    static func mark(_ name: @autoclosure () -> String) {
        guard isEnabled, let probe = shared else { return }
        probe.recordMark(name(), [:])
    }

 /// 记一个事件点（附带诊断信息；关闭时 info 不求值）。
    static func mark(_ name: @autoclosure () -> String, _ info: @autoclosure () -> [String: Any]) {
        guard isEnabled, let probe = shared else { return }
        probe.recordMark(name(), info())
    }

 /// 滚动几何馈入（每帧一次；关闭时只是 nil 判断）。
    static func feedGeometry(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        shared?.geometry = (Double(offset), Double(contentHeight), Double(viewportHeight))
    }

 /// 滚动相位馈入：idle / tracking / interacting / decelerating / animating。
    static func feedPhase(_ phase: String) {
        shared?.phase = phase
    }

 /// 列表规模馈入（显示窗口行数 / 总行数 / 是否贴底）。
    static func feedRows(displayed: Int, total: Int, pinned: Bool) {
        guard let probe = shared else { return }
        probe.displayedRows = displayed
        probe.totalRows = total
        probe.pinned = pinned
    }

 /// 列表出现时调用（幂等）；也可由第一个 mark 自动触发。
    static func start() {
        shared?.startIfNeeded()
    }

 /// 列表消失时调用。
    static func stop() {
        shared?.stop()
    }

 // MARK: - state

    private var ticker: CADisplayLink?
    private var started = false
    private var stopped = false
    private var frameIndex: Int = 0
    private var startedUptime: CFTimeInterval = CACurrentMediaTime()
    private var lastTimestamp: CFTimeInterval = 0
    private var geometry: (offset: Double, contentH: Double, viewportH: Double) = (0, 0, 0)
    private var phase: String = "idle"
    private var displayedRows: Int = 0
    private var totalRows: Int = 0
    private var pinned: Bool = true
    private var lastMarkName: String = "-"
    private var lastMarkUptime: CFTimeInterval = 0

    private var pendingLines: [String] = []
    private var lastFlush = Date.distantPast
    private var fileURL: URL?
    private let writeQueue = DispatchQueue(label: "com.dshm.hitchprobe.write", qos: .utility)
 /// 只在 writeQueue 上读写（主线程不做文件 IO，避免探针自己制造卡顿）。
    private var handle: FileHandle?

    private var maxSeconds: Double = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["DSHM_HITCH_MAX_SECONDS"], let value = Double(raw), value > 0 {
            return value
        }
        if let raw = env["DSHM_JITTER_MAX_SECONDS"], let value = Double(raw), value > 0 {
            return value
        }
        return 120
    }()

    private init() {}

 // MARK: - lifecycle

    private func startIfNeeded() {
        guard !started, !stopped else { return }
        started = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "hitch-\(Int(Date().timeIntervalSince1970)).jsonl"
        let url = documents.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let created = try? FileHandle(forWritingTo: url)
        fileURL = url
        writeQueue.async { [weak self] in self?.handle = created }
        try? name.write(to: documents.appendingPathComponent("hitch-latest.txt"),
                        atomically: true, encoding: .utf8)
        startedUptime = CACurrentMediaTime()
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
        NSLog("[HITCH] probe started file=%@ maxSeconds=%.0f", name, maxSeconds)
    }

    private func stop() {
        guard started, !stopped else { return }
        stopped = true
        ticker?.invalidate()
        ticker = nil
        append(["type": "event", "t": Date().timeIntervalSince1970, "name": "probeStop",
                "i": frameIndex])
        flush(force: true)
        NSLog("[HITCH] probe stopped file=%@ frames=%d", fileURL?.lastPathComponent ?? "-", frameIndex)
    }

 // MARK: - tick

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startedUptime
        if elapsed > maxSeconds {
            stop()
            return
        }
        frameIndex += 1
        let timestamp = ticker?.timestamp ?? CACurrentMediaTime()
        let interval: Double
        if lastTimestamp > 0, timestamp > lastTimestamp {
            interval = (timestamp - lastTimestamp) * 1000
        } else {
            interval = 0
        }
        lastTimestamp = timestamp
        let markAge: Double
        if lastMarkUptime > 0 {
            markAge = (CACurrentMediaTime() - lastMarkUptime) * 1000
        } else {
            markAge = -1
        }
        append([
            "type": "frame",
            "i": frameIndex,
            "t": Date().timeIntervalSince1970,
            "iv": (interval * 100).rounded() / 100,
            "off": (geometry.offset * 10).rounded() / 10,
            "ch": (geometry.contentH * 10).rounded() / 10,
            "vh": (geometry.viewportH * 10).rounded() / 10,
            "phase": phase,
            "disp": displayedRows,
            "total": totalRows,
            "pin": pinned ? 1 : 0,
            "lm": lastMarkName,
            "lma": markAge >= 0 ? (markAge * 10).rounded() / 10 : -1,
        ])
    }

 // MARK: - marks

    private func recordMark(_ name: String, _ info: [String: Any]) {
        startIfNeeded()
        lastMarkName = name
        lastMarkUptime = CACurrentMediaTime()
        var payload: [String: Any] = [
            "type": "mark",
            "i": frameIndex,
            "t": Date().timeIntervalSince1970,
            "name": name,
        ]
        if !info.isEmpty { payload["info"] = info }
        append(payload)
    }

 // MARK: - file IO（主线程只做 JSON 序列化 + 入队，写盘在后台）

    private func append(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        pendingLines.append(line)
        let now = Date()
        if pendingLines.count >= 30 || now.timeIntervalSince(lastFlush) > 0.5 {
            flush(force: false)
        }
    }

    private func flush(force: Bool) {
        guard !pendingLines.isEmpty || force else { return }
        guard !pendingLines.isEmpty else { return }
        let chunk = pendingLines.joined(separator: "\n") + "\n"
        pendingLines.removeAll(keepingCapacity: true)
        lastFlush = Date()
        guard let data = chunk.data(using: .utf8) else { return }
        writeQueue.async { [weak self] in
            guard let handle = self?.handle else { return }
            handle.write(data)
        }
    }
}
#endif
