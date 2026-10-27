#if DEBUG
import Foundation
import QuartzCore

/// DEBUG-only 过程组展开/收起方向取证探针。
///
/// 默认零开销：`DSHM_PROCGROUP_PROBE=1` 未设置时 `shared == nil`，所有调用点 no-op。
///
/// 采集（NDJSON，写到 App Documents/proctoggle-<epoch>.jsonl，路径另存
/// proctoggle-latest.txt）：
/// - 每帧（CADisplayLink）：`t`(unix 秒) `off`(列表归一 offset) `vh`(视口高)
/// `rowMinY`/`rowMaxY`(激活行在列表内容坐标系的布局 frame——滚动时不变，
/// 展开时 MaxY 增长 Δ)。UIKit 底座下全部直读 UITableView 真值。
/// - 事件行：`toggle`(模式切换 + ProcessGroupExpandAnchor 的计划：Δ/u/预期 offset)
/// `mark`(测试打点)。
///
/// 判定（脚本 apps/ios/scripts/analyze-proctoggle.py）：
/// - **组头定住**：行视觉顶 = vh − (rowMaxY − off)，切换期间逐帧漂移 ≤ 2pt；
/// - **方向**：offset 与 rowMaxY 同步 +Δ（展开）/−Δ（收起），即下方内容被推开；
/// - **非线性动效**：offset 进度曲线中段耗时占比 < 线性（easeInOut ≈ 1/3）。
@MainActor
final class ProcessToggleProbe {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["DSHM_PROCGROUP_PROBE"] == "1"
    }()

    static let shared: ProcessToggleProbe? = {
        isEnabled ? ProcessToggleProbe() : nil
    }()

    private var ticker: CADisplayLink?
    private var fileHandle: FileHandle?
    private var pendingLines: [String] = []
    private var lastFlush = Date.distantPast
    private var startedUptime = CACurrentMediaTime()
    private var maxSeconds: Double = {
        guard let raw = ProcessInfo.processInfo.environment["DSHM_PROCGROUP_PROBE_MAX"],
              let value = Double(raw), value > 0 else { return 180 }
        return value
    }()

 // 绑定数据源（列表视图 onAppear 注册）。
    private var offsetProvider: (() -> CGFloat)?
    private var viewportProvider: (() -> CGFloat)?
    private var contentHeightProvider: (() -> CGFloat)?
    private var rowFrameProvider: ((String) -> CGRect)?
 /// 最近一次 toggle 的行 id（逐帧采样对象）。
    private(set) var activeRowID: String?
 /// 组头全局 frame 的 minY（onGeometryChange 逐帧上报；组头动了它就动——
 /// 这是「用户实际看到什么」的真值，不受 Preference 合并上报影响）。
    private(set) var headerGlobalMinY: CGFloat = -1
 /// 激活行的渲染高度（onGeometryChange 逐帧上报：高度插值是否真实发生——
 /// Preference 的内容系 frame 只在终值上报，不能证伪/证实动画）。
    private(set) var activeRowHeight: CGFloat = -1

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "proctoggle-\(Int(Date().timeIntervalSince1970)).jsonl"
        let url = documents.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        try? name.write(to: documents.appendingPathComponent("proctoggle-latest.txt"),
                        atomically: true, encoding: .utf8)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        ticker = link
        write(line: "{\"type\":\"probeStart\",\"t\":\(now())}")
    }

    func bind(offset: @escaping () -> CGFloat,
              viewportHeight: @escaping () -> CGFloat,
              contentHeight: @escaping () -> CGFloat,
              rowFrame: @escaping (String) -> CGRect) {
        offsetProvider = offset
        viewportProvider = viewportHeight
        contentHeightProvider = contentHeight
        rowFrameProvider = rowFrame
    }

 /// toggle 事件（含 ProcessGroupExpandAnchor 计划）。
    func event(_ type: String, _ fields: [String: Any]) {
        var parts: [String] = ["\"type\":\"\(type)\"", "\"t\":\(now())"]
        for (key, value) in fields.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            parts.append("\"\(key)\":\(jsonValue(value))")
        }
        if type == "toggle", let id = fields["id"] as? String {
            activeRowID = id
        }
        write(line: "{" + parts.joined(separator: ",") + "}")
    }

 /// 过程组行布局 frame（内容坐标系，滚动不变、展开时增长）：
 /// UIKit 版由 Coordinator 的 rowFrameProvider（rectForRow）逐 tick 直读真值。

 /// 组头全局 frame（ProcessGroupView 内 onGeometryChange 上报）。
 /// **按激活行过滤**（v5）：会话里所有组都在上报，不过滤的话
 /// 槽位被 last-writer 覆盖——reveal 期间下方行被推开时它们的组头逐帧
 /// 上报，激活组自己的轨迹反而被冲掉。
    func headerFrame(id: String, _ frame: CGRect) {
        guard id == activeRowID else { return }
        headerGlobalMinY = frame.minY
    }

 /// 行渲染高度采样（ProcessRowFrameMeasure 内 onGeometryChange 上报）。
    func rowHeight(id: String, height: CGFloat) {
        if id == activeRowID {
            activeRowHeight = height
        }
    }

    private func jsonValue(_ value: Any) -> String {
        switch value {
        case let string as String: return "\"\(string)\""
        case let double as Double: return String(format: "%.2f", double)
        case let number as NSNumber: return number.stringValue
        default: return "\"\(value)\""
        }
    }

    @objc private func tick() {
        guard CACurrentMediaTime() - startedUptime < maxSeconds else {
            ticker?.invalidate()
            ticker = nil
            flush(force: true)
            return
        }
        guard let offset = offsetProvider?() else { return }
 // 未激活行时也采样（rowMinY/rowMaxY = -1）：给 toggle 前留基线。
        let frame = activeRowID.flatMap { rowFrameProvider?($0) } ?? .null
        let minY = frame.isNull ? -1 : frame.minY
        let maxY = frame.isNull ? -1 : frame.maxY
        write(line: String(
            format: "{\"type\":\"f\",\"t\":%.4f,\"off\":%.2f,\"vh\":%.1f,\"ch\":%.1f,\"rowMinY\":%.2f,\"rowMaxY\":%.2f,\"hdrG\":%.2f,\"rowH\":%.2f}",
            now(), offset, viewportProvider?() ?? 0, contentHeightProvider?() ?? 0, minY, maxY, headerGlobalMinY, activeRowHeight
        ))
    }

    private func now() -> Double {
        Date().timeIntervalSince1970
    }

    private func write(line: String) {
        pendingLines.append(line)
        if Date().timeIntervalSince(lastFlush) > 0.2 {
            flush(force: false)
        }
    }

    private func flush(force: Bool) {
        guard !pendingLines.isEmpty else { return }
        pendingLines.append("")
        let text = pendingLines.joined(separator: "\n")
        pendingLines.removeAll()
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(Data(text.utf8))
        lastFlush = Date()
    }
}
#endif
