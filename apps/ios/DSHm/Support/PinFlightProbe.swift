#if DEBUG
import CoreGraphics
import Foundation
import QuartzCore

/// 列表侧逐帧快照（弹跳取证 / 测试方案 §2 真值来源）。
///
/// 置顶/取消置顶会改变滚动内容在「变更点」之后的高度；逐帧记录每行 frame、
/// 滚动 offset、行渲染偏移（`.offset`）与卡片缩放，才能区分「曲线过冲」「二次校正」
/// 「一帧瞬移」三种成因。行 frame 是**布局坐标**（不含 `.offset` 渲染变换），
/// 屏幕位置 = `rowFrames.minY − scrollOffset + rowShift`。
struct PinListSnapshot {
    var scrollOffset: CGFloat = 0
    /// 行 id → 内容坐标 frame（置顶行 + 分组行 + 分组头 `header:<path>`）。
    var rowFrames: [String: CGRect] = [:]
    /// 当前处于置顶区的 sessionId（用于把行归到置顶区/分组）。
    var pinnedIds: [String] = []
    /// 行 id → 当帧实际渲染的 `.offset` 偏移（逐帧真值）。
    /// 注意：`rowFrames` 的 `frame(in:)` 已包含该渲染偏移，屏幕位置不要再叠加一次。
    var rowShift: [String: CGFloat] = [:]
    /// 新置顶卡当帧缩放（v4.0：上边缘中心长出 `0 → 1`；无插入卡时为 1）。
    var newPinnedScale: CGFloat = 1
    /// 幽灵卡当帧缩放；`ghostVisible` 为 false 时无意义。
    var ghostScale: CGFloat = 0
    /// 本段幽灵卡**首个渲染帧**的缩放（首帧零点：零点=首帧 → 起始 ≈1.0）。
    var ghostStartScale: CGFloat?
    var ghostVisible: Bool = false
    /// 归位卡当帧缩放（v4.0：屏内时上边缘中心长出 `0 → 1`；其余恒为 1）。
    var restoredScale: CGFloat = 1
    /// 视口高度（屏幕坐标，pt）。
    var viewportHeight: CGFloat = 0
    /// 诊断：置顶区实测高度（DD-04 屏外分支的布局增长源是否已落地）。
    var pinnedAreaHeight: CGFloat = 0
    /// 诊断：底层 UIScrollView 的 contentSize.height / 实时 contentOffset.y。
    var contentHeight: CGFloat = 0
    var rawOffset: CGFloat = 0
}

/// 过渡段真值（由列表视图提供；idle 时 mode/kind = "idle"）。
struct PinMotionProbeState {
    var mode: String = "idle"
    var kind: String = "idle"
    var segment: Int = 0
    var elapsedMs: Double = 0
    /// 当帧已渲染到曲线的进度（逐帧限速后；v4.0 无过冲，≤1）。
    var progress: Double = 0
    /// 已推进的渲染帧数（首帧 = 1）。
    var renderedFrames: Int = 0
    /// 首个渲染帧的 `CACurrentMediaTime()`（毫秒，与 tick.t 同一时基）。
    var clockStartMediaMs: Double?
    /// 本段时间轴时长（毫秒；≤150ms，DD-07 后段按 450ms 预算缩短）。
    var durationMs: Double = 0
    var shifts: [String: CGFloat] = [:]
    var insertedId: String?
    var restoredId: String?
    /// DD-05：归位卡在过渡开始时是否视口内（true = 同一段播上边缘中心长出）。
    var restoredVisible: Bool = false
    /// DD-05 锚点方向：幽灵卡 `top`/`bottom`（内容底部 DEC-13 为 bottom）；
    /// 新置顶卡恒为 `top`；归位卡恒为 `top`。idle 段三者均为 `none`。
    var ghostAnchor: String = "none"
    var insertedAnchor: String = "none"
    var restoredAnchor: String = "none"
    var pendingRefresh: Bool = false
    /// 是否还有逐帧任务（过渡段 / 幽灵卡在跑）。
    var taskActive: Bool = false
    /// DD-04 内容底部（DEC-13）诊断：段开始时可用滚动余量、缺口与实施的滚动校正。
    var headroom: CGFloat = 0
    var residual: CGFloat = 0
    var scrollCorrection: CGFloat = 0
}

/// DEBUG-only 置顶/取消置顶逐帧探针（测试方案 §2 帧级判据的真值来源）。
///
/// 默认零开销：`DSHM_PIN_PROBE=1` 未设置时 `shared == nil`，所有调用点 no-op；
/// 生产构建里整个类型不存在（本文件整体 `#if DEBUG`）。
///
/// 每次 App 启动写**一个独立文件** `Documents/pin-flight-probe-<epochMillis>.jsonl`，
/// 文件名另存 `pin-flight-probe-latest.txt`（E2E 每个用例都会重启 App，固定文件名
/// 会互相覆盖）。每行一个 JSON 对象：
/// - `{"type":"probeStart","t0":<毫秒>}`
/// - `{"type":"click","t":<毫秒>,"action":"pin"|"unpin","sid":"<id>","groupsVersion":<n>}`
/// - `{"type":"transition","phase":"start"|"end","t":<毫秒>,"segment":<n>,
///    "mode":"inPlace"|"anchored"|"refresh","kind":"pin"|"unpin"|"refresh",
///    "dataVersion":<n>,"pinnedCount":<n>,"source":"<id>"|null,"inserted":"<id>"|null,
///    "restored":"<id>"|null,
///    "rows":[{"id":"<id>","oldY":<内容坐标>|null,"newY":<内容坐标>|null,
///             "measuredY":<内容坐标>|null,"shift":<pt>,"visible":<bool>}]}`
/// - `{"type":"deviation","t":<毫秒>,"segment":<n>,
///    "rows":[{"id":"<id>","predicted":<内容坐标>,"measured":<内容坐标>,"delta":<pt>}]}`
/// - `{"type":"anchor","t":<毫秒>,"segment":<n>,"anchor":"<id>","deviation":<pt>,
///    "inFirstFrame":<bool>,"outcome":"keepPrediction|keepOppositeSign|replaced|replaceTooLate|noAnchor"}`
/// - `{"type":"tick","t":<毫秒>,"flight":[...]|null,"ghostScale":<0..1>,
///    "ghostStartScale":<0..1|null>,"restoredScale":<0..1>,
///    "newPinnedScale":<..>,"targetOpacity":<0..1>,"sourceVisible":<bool>,
///    "railVisible":<bool>,"groupsVersion":<n>,"scroll":<内容坐标>,
///    "rows":{id:[minY,height]},"rowShift":{id:pt},"rowScreen":{id:[screenY,height]},
///    "pinned":[<id>],"motion":{"mode","kind","segment","elapsedMs","shifts",
///    "inserted","restored","restoredVisible","ghostAnchor":"top|bottom|none",
///    "insertedAnchor":"top|none","restoredAnchor":"top|none",
///    "pendingRefresh","taskActive",
///    "progress":<0..1>,"frames":<n>,"clockStart":<绝对毫秒|null>,
///    "durationMs":<n>,"headroom":<pt>,"residual":<pt>,"scrollCorrection":<pt>},
///    "task":{"sinceSettleMs":<n|null>,"framesAfterSettle":<n>,
///            "rowShiftRenders":<n>,"taskActive":<bool>}}`
/// - `{"type":"settle","t":<毫秒>,"action":"pin"|"unpin","reason":"..."}`
///
/// 只记录点击前后 ±600ms 的 tick（点击前的帧来自 1.5s 环形缓冲）；settle 后继续
/// 采 ~1.2s，供 AC-09「结束后 ≥1s 无逐帧刷新」判定。`flight` 用**列表内容坐标**
/// （与行几何同一个命名坐标空间），由幽灵卡 GeometryEffect 逐帧写入。
@MainActor
final class PinFlightProbe {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["DSHM_PIN_PROBE"] == "1"
    static let shared: PinFlightProbe? = isEnabled ? PinFlightProbe() : nil

    /// 点击前/后各保留的窗口。
    private static let windowSeconds: Double = 0.6
    /// settle 后继续采样的窗口（AC-09 要求 ≥1s）。
    private static let settleWindowSeconds: Double = 1.2
    /// 点击前 tick 的环形缓冲长度。
    private static let ringSeconds: Double = 1.5

    /// 幽灵卡逐帧渲染真值（GeometryEffect 写入）。
    let frameRecorder = PinGhostFrameRecorder()

    private var fileHandle: FileHandle?
    private var ticker: CADisplayLink?
    private var pendingLines: [String] = []
    private var lastFlush = Date.distantPast
    private var bufferedTicks: [(t: Double, line: String)] = []
    private var windowStart: Double = -.greatestFiniteMagnitude
    private var windowEnd: Double = -.greatestFiniteMagnitude

    // settle 后的任务真值（AC-09）：settle 时刻、settle 后收到的 tick 数、
    // settle 后行偏移渲染次数（逐帧任务是否还在跑）。
    private var settleAt: Double?
    private var ticksAfterSettle = 0
    private var rowShiftRendersAfterSettle = 0

    // 视图绑定的真值来源（全部读列表侧状态，不重复渲染）。
    private var targetOpacityProvider: (() -> Double)?
    private var sourceVisibleProvider: (() -> Bool)?
    private var railVisibleProvider: (() -> Bool)?
    private var groupsVersionProvider: (() -> Int)?
    private var listSnapshotProvider: (() -> PinListSnapshot)?
    private var motionProvider: (() -> PinMotionProbeState)?

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
        groupsVersion: @escaping () -> Int,
        listSnapshot: @escaping () -> PinListSnapshot,
        motion: @escaping () -> PinMotionProbeState
    ) {
        targetOpacityProvider = targetOpacity
        sourceVisibleProvider = sourceVisible
        railVisibleProvider = railVisible
        groupsVersionProvider = groupsVersion
        listSnapshotProvider = listSnapshot
        motionProvider = motion
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

    /// 一段操作结束（落位 / 被打断 / 刷新应用）。settle 后继续采 1.2s（AC-09）。
    func settle(action: String, reason: String) {
        let now = Self.now()
        if windowStart < now - 1 {
            windowStart = now - 0.05
        }
        windowEnd = max(windowEnd, now + Self.settleWindowSeconds)
        settleAt = now
        ticksAfterSettle = 0
        rowShiftRendersAfterSettle = 0
        write(line: "{\"type\":\"settle\",\"t\":\(Self.millis()),"
            + "\"action\":\"\(action)\",\"reason\":\"\(reason)\"}")
        flush(force: true)
    }

    /// 段开始/结束快照：全量行（含屏外）旧/新内容坐标 + 被驱动行偏移。
    func transition(
        phase: String,
        segment: Int,
        mode: String,
        kind: String,
        dataVersion: Int,
        pinnedCount: Int,
        sourceId: String?,
        insertedId: String?,
        restoredId: String?,
        rows: [(id: String, oldY: CGFloat?, newY: CGFloat?, measuredY: CGFloat?, shift: CGFloat, visible: Bool)]
    ) {
        let now = Self.now()
        if phase == "start" {
            windowEnd = max(windowEnd, now + Self.windowSeconds)
        }
        let rowsJSON = rows.map { row -> String in
            let old = row.oldY.map { String(format: "%.1f", $0) } ?? "null"
            let new = row.newY.map { String(format: "%.1f", $0) } ?? "null"
            let measured = row.measuredY.map { String(format: "%.1f", $0) } ?? "null"
            return "{\"id\":\"\(Self.escape(row.id))\",\"oldY\":\(old),\"newY\":\(new),"
                + "\"measuredY\":\(measured),\"shift\":\(String(format: "%.2f", row.shift)),"
                + "\"visible\":\(row.visible)}"
        }.joined(separator: ",")
        let line = "{\"type\":\"transition\",\"phase\":\"\(phase)\",\"t\":\(Self.millis()),"
            + "\"segment\":\(segment),\"mode\":\"\(mode)\",\"kind\":\"\(kind)\","
            + "\"dataVersion\":\(dataVersion),\"pinnedCount\":\(pinnedCount),"
            + "\"source\":\(Self.optionalString(sourceId)),"
            + "\"inserted\":\(Self.optionalString(insertedId)),"
            + "\"restored\":\(Self.optionalString(restoredId)),"
            + "\"rows\":[\(rowsJSON)]}"
        write(line: line)
        if phase == "end" { flush(force: true) }
    }

    /// 刷新段预测 / 实测差异（只诊断，不作为 AC 判定）。
    func deviation(segment: Int, rows: [(id: String, predicted: CGFloat, measured: CGFloat)]) {
        guard !rows.isEmpty else { return }
        let rowsJSON = rows.map { row in
            String(
                format: "{\"id\":\"%@\",\"predicted\":%.1f,\"measured\":%.1f,\"delta\":%.1f}",
                Self.escape(row.id), row.predicted, row.measured, row.measured - row.predicted
            )
        }.joined(separator: ",")
        write(line: "{\"type\":\"deviation\",\"t\":\(Self.millis()),"
            + "\"segment\":\(segment),\"rows\":[\(rowsJSON)]}")
    }

    /// DD-04 锚点实测校验（屏外分支）：偏差、是否仍在首帧、判定与是否落地。
    func anchor(
        segment: Int,
        anchorId: String,
        deviation: CGFloat,
        inFirstFrame: Bool,
        outcome: String
    ) {
        write(
            line: String(
                format: "{\"type\":\"anchor\",\"t\":%d,\"segment\":%d,\"anchor\":\"%@\","
                    + "\"deviation\":%.1f,\"inFirstFrame\":%@,\"outcome\":\"%@\"}",
                Self.millis(), segment, Self.escape(anchorId), deviation,
                inFirstFrame ? "true" : "false", outcome
            )
        )
    }

    /// 行偏移逐帧渲染一次（`PinRowShiftModifier` 调用；AC-09 的任务真值）。
    func noteRowShiftRender() {
        if settleAt != nil { rowShiftRendersAfterSettle += 1 }
    }

    // MARK: - 逐帧

    @objc private func tick() {
        let now = Self.now()
        if now >= windowStart, now <= windowEnd {
            if settleAt != nil { ticksAfterSettle += 1 }
            write(line: tickLine(t: now))
            return
        }
        if windowEnd > 0 || windowStart > 0 {
            // 窗口刚结束：收尾落盘，之后回到环形缓冲。
            windowStart = -.greatestFiniteMagnitude
            windowEnd = -.greatestFiniteMagnitude
            settleAt = nil
            flush(force: true)
        }
        // 点击前：环形缓冲（供下一次 click 补写 ±600ms 的“前”半段）。
        bufferedTicks.append((t: now, line: tickLine(t: now)))
        let cutoff = now - Self.ringSeconds
        bufferedTicks.removeAll { $0.t < cutoff }
    }

    private func tickLine(t: Double) -> String {
        let snapshot = listSnapshotProvider?() ?? PinListSnapshot()
        let motion = motionProvider?() ?? PinMotionProbeState()
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
        let rowParts = snapshot.rowFrames
            .sorted { $0.key < $1.key }
            .prefix(60)
            .map { id, rect in
                String(
                    format: "\"%@\":[%.1f,%.1f]",
                    Self.escape(id), rect.minY, rect.height
                )
            }
        let rowsJSON = "{" + rowParts.joined(separator: ",") + "}"
        // 屏幕位置 = 行 frame（已含渲染偏移）− 滚动偏移（逐帧真值）。
        let screenParts = snapshot.rowFrames
            .sorted { $0.key < $1.key }
            .prefix(60)
            .map { id, rect in
                String(
                    format: "\"%@\":[%.1f,%.1f]",
                    Self.escape(id), rect.minY - snapshot.scrollOffset, rect.height
                )
            }
        let screenJSON = "{" + screenParts.joined(separator: ",") + "}"
        let shiftParts = snapshot.rowShift
            .sorted { $0.key < $1.key }
            .map { id, shift in
                String(format: "\"%@\":%.2f", Self.escape(id), shift)
            }
        let shiftJSON = "{" + shiftParts.joined(separator: ",") + "}"
        let pinnedJSON = "["
            + snapshot.pinnedIds.map { "\"\(Self.escape($0))\"" }.joined(separator: ",")
            + "]"
        let shiftsParts = motion.shifts
            .sorted { $0.key < $1.key }
            .map { id, shift in String(format: "\"%@\":%.2f", Self.escape(id), shift) }
        let motionShiftsJSON = "{" + shiftsParts.joined(separator: ",") + "}"
        let sinceSettle = settleAt.map { String(format: "%.0f", (t - $0) * 1000) } ?? "null"
        let ghostStartJSON = snapshot.ghostStartScale.map { String(format: "%.3f", $0) } ?? "null"
        return String(
            format: "{\"type\":\"tick\",\"t\":%.0f,\"flight\":%@,\"ghostScale\":%.3f,"
                + "\"ghostStartScale\":%@,\"restoredScale\":%.3f,"
                + "\"newPinnedScale\":%.3f,\"targetOpacity\":%.3f,\"sourceVisible\":%@,"
                + "\"railVisible\":%@,\"groupsVersion\":%d,\"scroll\":%.1f,"
                + "\"viewport\":%.0f,\"pinH\":%.1f,\"contentH\":%.1f,\"rawOff\":%.1f,"
                + "\"rows\":%@,\"rowShift\":%@,\"rowScreen\":%@,"
                + "\"pinned\":%@,\"motion\":{\"mode\":\"%@\",\"kind\":\"%@\",\"segment\":%d,"
                + "\"elapsedMs\":%.0f,\"shifts\":%@,\"inserted\":%@,\"restored\":%@,"
                + "\"restoredVisible\":%@,\"ghostAnchor\":\"%@\","
                + "\"insertedAnchor\":\"%@\",\"restoredAnchor\":\"%@\","
                + "\"pendingRefresh\":%@,\"taskActive\":%@,"
                + "\"progress\":%.4f,\"frames\":%d,\"clockStart\":%@,\"durationMs\":%.0f,"
                + "\"headroom\":%.1f,\"residual\":%.1f,\"scrollCorrection\":%.1f},"
                + "\"task\":{\"sinceSettleMs\":%@,\"framesAfterSettle\":%d,"
                + "\"rowShiftRenders\":%d,\"taskActive\":%@}}",
            t * 1000, flight, snapshot.ghostScale, ghostStartJSON, snapshot.restoredScale,
            snapshot.newPinnedScale, opacity,
            sourceVisible, railVisible, version, snapshot.scrollOffset,
            snapshot.viewportHeight, snapshot.pinnedAreaHeight, snapshot.contentHeight,
            snapshot.rawOffset, rowsJSON, shiftJSON, screenJSON, pinnedJSON,
            motion.mode, motion.kind, motion.segment, motion.elapsedMs, motionShiftsJSON,
            Self.optionalString(motion.insertedId), Self.optionalString(motion.restoredId),
            motion.restoredVisible ? "true" : "false",
            motion.ghostAnchor, motion.insertedAnchor, motion.restoredAnchor,
            motion.pendingRefresh ? "true" : "false",
            motion.taskActive ? "true" : "false",
            motion.progress, motion.renderedFrames,
            motion.clockStartMediaMs.map { String(format: "%.0f", $0) } ?? "null",
            motion.durationMs,
            motion.headroom, motion.residual, motion.scrollCorrection,
            sinceSettle, ticksAfterSettle, rowShiftRendersAfterSettle,
            motion.taskActive ? "true" : "false"
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

    private static func optionalString(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(escape(value))\""
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif

#if DEBUG
/// 幽灵卡逐帧渲染真值（GeometryEffect 写入；仅 DEBUG + 探针开启时非 nil）。
final class PinGhostFrameRecorder {
    var rect: CGRect?
    var scale: CGFloat = 0
}

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
