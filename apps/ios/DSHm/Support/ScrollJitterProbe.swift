#if DEBUG
import SwiftUI
import UIKit
import QuartzCore

/// DEBUG-only **frame-level scroll jitter probe**.
///
/// 目的：把「补齐/插入是否让用户看到内容跳变」变成**机器可判定的数字**，不再依赖人工回忆。
/// 默认零开销：`DSHM_JITTERDBG=1` 未设置时 `shared == nil`，所有调用点 no-op、不创建视图/定时器。
///
/// 采集内容（NDJSON，写到 App Documents/scroll-jitter-<epoch>.jsonl）：
/// - 每帧（CADisplayLink，~60Hz）：`t`(unix 秒) `off`(contentOffset.y) `ch`(contentSize.height)
/// `vh`(viewport height) `phase`(idle/interacting/decelerating) `anim`(1=程序化动画滚动进行中)
/// `ys`({rowID: 该行在 window 坐标系的 minY})
/// - 事件行：`rows`（行数变化）、`prepend`（historyBatchToken 变化）、`phase`/`anim` 变更、`mark`
///
/// 判定方式见 `apps/ios/scripts/analyze-scroll-jitter.py`：
/// 同一行相邻帧的 window Y 变化 = 用户可见位移（手势滚动除外）；插入帧由「行内容坐标
/// （windowY+offset）整体变化」自动识别；插入帧上 `|中位 windowY 变化|` 超过 0.5pt 即判跳变。
@MainActor
final class ScrollJitterProbe {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["DSHM_JITTERDBG"] == "1"
    }()

    static let shared: ScrollJitterProbe? = {
        isEnabled ? ScrollJitterProbe() : nil
    }()

    private struct WeakView {
        weak var view: UIView?
    }

    private var registeredViews: [WeakView] = []
    private var registeredIDs: Set<ObjectIdentifier> = []
    private var ticker: CADisplayLink?
    private var startedAt: Date = Date()
    private var startedUptime: CFTimeInterval = CACurrentMediaTime()
    private var maxSeconds: Double = {
        guard let raw = ProcessInfo.processInfo.environment["DSHM_JITTER_MAX_SECONDS"],
              let value = Double(raw), value > 0 else { return 90 }
        return value
    }()
    private var geometry = (offset: 0.0, contentH: 0.0, viewportH: 0.0)
    private var anchorRowID: String?
    private var phase: String = "idle"
    private var animating = false
    private var pendingLines: [String] = []
    private var lastFlush = Date.distantPast
    private var fileURL: URL?
    private var fileHandle: FileHandle?
    private var stopped = false
    private var frameIndex: Int = 0

    private init() {}

 // MARK: - lifecycle

    func startIfNeeded() {
        guard !stopped, ticker == nil else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "scroll-jitter-\(Int(Date().timeIntervalSince1970)).jsonl"
        let url = documents.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileURL = url
        try? name.write(to: documents.appendingPathComponent("scroll-jitter-latest.txt"),
                        atomically: true, encoding: .utf8)
        startedAt = Date()
        startedUptime = CACurrentMediaTime()

        let env = ProcessInfo.processInfo.environment
        event("probeStart", [
            "session": env["DSHM_E2E_OPEN_SESSION"] ?? "-",
            "autoscroll": env["DSHM_JITTER_AUTOSCROLL"] ?? "0",
            "fillPaceMs": env["DSHM_FILL_PACE_MS"] ?? "0",
        ])

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
        NSLog("[JITTER] probe started file=%@ maxSeconds=%.0f", name, maxSeconds)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        ticker?.invalidate()
        ticker = nil
        event("probeStop", [:])
        flush(force: true)
        try? fileHandle?.close()
        fileHandle = nil
        NSLog("[JITTER] probe stopped file=%@", fileURL?.lastPathComponent ?? "-")
    }

 // MARK: - feeds

    func register(rowID: String, view: UIView) {
        let key = ObjectIdentifier(view)
        guard !registeredIDs.contains(key) else { return }
        registeredIDs.insert(key)
        registeredViews.append(WeakView(view: view))
        if ticker == nil { startIfNeeded() }
    }

    func unregister(rowID: String) { /* 弱引用 + 每帧清理，无需显式移除 */ }

    func updateGeometry(offsetY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        if ticker == nil { startIfNeeded() }
        geometry = (Double(offsetY), Double(contentHeight), Double(viewportHeight))
    }

    func setAnchor(_ value: String?) {
        guard anchorRowID != value else { return }
        anchorRowID = value
        event("anchor", ["value": value ?? "-"])
    }

    func setPhase(_ value: String) {
        guard phase != value else { return }
        phase = value
        event("phase", ["value": value])
    }

    func setAnimating(_ value: Bool) {
        guard animating != value else { return }
        animating = value
        event("anim", ["value": value ? 1 : 0])
    }

    func event(_ name: String, _ info: [String: Any]) {
        var payload: [String: Any] = [
            "type": "event",
            "t": Date().timeIntervalSince1970,
            "name": name,
        ]
        if !info.isEmpty { payload["info"] = info }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        append(line)
    }

 // MARK: - tick

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startedUptime
        if elapsed > maxSeconds {
            NSLog("[JITTER] max seconds reached (%.0f), stopping", maxSeconds)
            stop()
            return
        }
        frameIndex += 1
 // 每帧按 view 现读 row id（cell 复用安全），并清理已释放的 view。
        var ys: [String: Double] = [:]
        var alive: [WeakView] = []
        alive.reserveCapacity(registeredViews.count)
        for ref in registeredViews {
            guard let view = ref.view else { continue }
            alive.append(ref)
            guard view.window != nil,
                  let identified = view as? JitterProbeIdentifiable,
                  !identified.jitterRowID.isEmpty else { continue }
            let rect = view.convert(view.bounds, to: nil)
            ys[identified.jitterRowID] = Double(rect.minY)
        }
        registeredViews = alive
        registeredIDs = Set(alive.compactMap { $0.view.map(ObjectIdentifier.init) })
        guard !ys.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "frame",
            "t": Date().timeIntervalSince1970,
            "i": frameIndex,
            "off": geometry.offset,
            "ch": geometry.contentH,
            "vh": geometry.viewportH,
            "phase": phase,
            "anim": animating ? 1 : 0,
            "anchor": anchorRowID ?? "-",
            "ys": ys,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        append(line)
    }

 // MARK: - file IO

    private func append(_ line: String) {
        pendingLines.append(line)
        let now = Date()
        if pendingLines.count >= 30 || now.timeIntervalSince(lastFlush) > 0.5 {
            flush(force: false)
        }
    }

    private func flush(force: Bool) {
        guard let handle = fileHandle, !pendingLines.isEmpty || force else { return }
        guard !pendingLines.isEmpty else { return }
        let chunk = pendingLines.joined(separator: "\n") + "\n"
        pendingLines.removeAll(keepingCapacity: true)
        if let data = chunk.data(using: .utf8) {
            handle.write(data)
            try? handle.synchronize()
        }
        lastFlush = Date()
    }

 /// 便捷入口：行探针视图用（DEBUG 才挂载）。
    static func registerIfNeeded(rowID: String, view: UIView) {
        shared?.register(rowID: rowID, view: view)
    }
}

/// 探针可识别协议：列表 cell 在 configure 时写入当前行 id，probe 每帧按 view 现读，
/// 避免 UITableView 复用导致「id → view 映射」过期（产生假跳变）。
protocol JitterProbeIdentifiable: AnyObject {
    var jitterRowID: String { get }
}

/// 挂在每个流分组行背景上的零尺寸探针：只把 UIView 注册给 probe，不参与布局。
struct JitterRowProbeView: UIViewRepresentable {
    let rowID: String

    final class ProbeUIView: UIView, JitterProbeIdentifiable {
        var rowID: String = ""
        var jitterRowID: String { rowID }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                ScrollJitterProbe.shared?.unregister(rowID: rowID)
            } else {
                ScrollJitterProbe.shared?.register(rowID: rowID, view: self)
            }
        }
    }

    func makeUIView(context: Context) -> ProbeUIView {
        let view = ProbeUIView()
        view.rowID = rowID
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeUIView, context: Context) {
        if uiView.rowID != rowID {
            ScrollJitterProbe.shared?.unregister(rowID: uiView.rowID)
            uiView.rowID = rowID
            ScrollJitterProbe.shared?.register(rowID: rowID, view: uiView)
        }
    }
}

extension View {
 /// 行级抖动探针（DEBUG + `DSHM_JITTERDBG=1` 才挂载；否则返回 self，零开销）。
    @ViewBuilder
    func jitterRowProbe(rowID: String) -> some View {
        if ScrollJitterProbe.isEnabled {
            background(JitterRowProbeView(rowID: rowID))
        } else {
            self
        }
    }
}

/// 统一接线：几何/阶段馈入 + 行数/补齐事件 + 生命周期。
/// `DSHM_JITTERDBG=1` 未设置时完全 no-op（不创建视图/定时器，生产零开销）。
struct JitterDebugWiring: ViewModifier {
    let rowsCount: Int
    let batchToken: Int

    func body(content: Content) -> some View {
        #if DEBUG
        if ScrollJitterProbe.isEnabled {
            content
                .modifier(JitterGeometryFeed())
                .onAppear { ScrollJitterProbe.shared?.startIfNeeded() }
                .onDisappear { ScrollJitterProbe.shared?.stop() }
                .onChange(of: rowsCount) { old, new in
                    ScrollJitterProbe.shared?.event("rows", ["old": old, "new": new])
                }
                .onChange(of: batchToken) { _, new in
                    ScrollJitterProbe.shared?.event("prepend", ["token": new, "rows": rowsCount])
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct JitterScrollGeometry: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
}

/// 滚动几何 + 滚动阶段输入（iOS 18+；更低版本探针退化为只有行位置采样）。
struct JitterGeometryFeed: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), ScrollJitterProbe.isEnabled {
            content
                .onScrollGeometryChange(for: JitterScrollGeometry.self) { geometry in
                    JitterScrollGeometry(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { _, value in
                    ScrollJitterProbe.shared?.updateGeometry(
                        offsetY: value.offsetY,
                        contentHeight: value.contentHeight,
                        viewportHeight: value.viewportHeight
                    )
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .interacting: ScrollJitterProbe.shared?.setPhase("interacting")
                    case .decelerating: ScrollJitterProbe.shared?.setPhase("decelerating")
                    case .animating: ScrollJitterProbe.shared?.setPhase("animating")
                    default: ScrollJitterProbe.shared?.setPhase("idle")
                    }
                }
        } else {
            content
        }
    }
}
#endif
