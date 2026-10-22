import Foundation
import UIKit

/// 诊断脚手架（不是产品功能）：量化「点击会话详情底部输入框 → 键盘弹出」的卡顿。
///
/// 只在环境变量 `DSHM_KEYBOARD_PROBE=1` 时启用（真机取证用 Xcode scheme 或
/// `devicectl... --environment-variables DSHM_KEYBOARD_PROBE=1` 启动 App 即可）；
/// 未启用时 `startIfEnabled()` 立即返回：不安装任何观察者、不写文件、对产品行为零影响。
/// 本探针随 task-2 引入，用于真机取证；问题定位后可删掉本文件，或整体保留在 Debug 构建。
///
/// 测量口径（时间基准 `ProcessInfo.processInfo.systemUptime`，单调递增，不受墙钟调整影响）：
/// - `beginToWillShowMs`：开始编辑 t0 → `keyboardWillShowNotification` 的毫秒差
/// - `beginToDidShowMs`：开始编辑 t0 → `keyboardDidShowNotification` 的毫秒差
/// - `mainQueueMs`：t0 时向主队列投递一个空任务，测它排队多久才被执行（主线程是否被占）
///
/// 每条样本追加写入 App Documents 下的 `keyboard-probe.jsonl`（只保留最近 200 条），
/// 供 `devicectl` 拉取分析；最近一条摘要同时给 SettingsView「连接诊断」展示。
enum KeyboardLatencyProbe {
 // MARK: - 配置

 /// 诊断开关的环境变量名；只有显式 `DSHM_KEYBOARD_PROBE=1` 才启用。
    static let enableEnvironmentKey = "DSHM_KEYBOARD_PROBE"
 /// 样本文件名（App Documents 目录下）。
    static let fileName = "keyboard-probe.jsonl"
 /// 只保留最近这么多条样本；超出后重写整个文件。
    static let maxSampleCount = 200
 /// 一次键盘弹出周期的最长等待；`didShow` 超时后收尾并重置，避免污染下一轮。
    static let cycleTimeout: TimeInterval = 5
 /// touchDown 到开始编辑的最大关联时间；超过则认为本次编辑不是这次点击触发。
    static let tapWindow: TimeInterval = 2

 // MARK: - 对外状态

 /// 最近一次样本的人类可读摘要，如 `willShow 42ms · didShow 180ms · mainQueue 3ms`。
 /// 未启用 / 尚无样本时为 nil。SettingsView 在 UI 层读取，故标 @MainActor。
    @MainActor
    static var lastMetricsText: String? { lastText.read() }

 /// JSONL 文件绝对路径；Documents 目录不可用时为 nil。给 `devicectl` 拉取用。
    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enableEnvironmentKey] == "1"
    }

 // MARK: - 启动 / 停止

 /// 在 `AppModel.init` 尽早调用（env 门控：未启用时立即返回，不产生任何副作用）。
 /// 幂等：重复调用不会重复安装观察者。
    static func startIfEnabled() {
        guard isEnabled, !didStart else { return }
        didStart = true
        let center = NotificationCenter.default
        observe(center, UITextField.textDidBeginEditingNotification) { beginEditing(source: "textfield") }
        observe(center, UITextView.textDidBeginEditingNotification) { beginEditing(source: "textview") }
        observe(center, UIResponder.keyboardWillShowNotification) { markWillShow() }
        observe(center, UIResponder.keyboardDidShowNotification) { markDidShow() }
        attachTouchObserverWhenPossible()
    }

 /// 移除观察者并清空状态。AppModel 生命周期 = App 生命周期，正常路径无需调用；
 /// 留给单元测试 / 重复测量场景。
    static func stop() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        if let windowObserver {
            center.removeObserver(windowObserver)
        }
        windowObserver = nil
        if let touchRecognizer {
            touchRecognizer.view?.removeGestureRecognizer(touchRecognizer)
        }
        touchRecognizer = nil
        lastTouchDownUptime = nil
        didStart = false
        pending = nil
        sequence = 0
    }

 // MARK: - 通知处理（统一在 main queue）

    private static func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping () -> Void
    ) {
 // queue:.main —— 通知回调统一投递到主队列处理，计时与状态都在 main 上，
 // 避免数据竞争。键盘/文本编辑通知本身就在主线程发出，额外调度开销可忽略。
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            handler()
        }
        observers.append(token)
    }

    private static func beginEditing(source: String) {
 // 关键假设（按 task-2 规格）：SwiftUI 拿不到「手指点击输入框」的原生事件，
 // 这里用 textDidBeginEditing（开始编辑）时刻充当 t0，作为点击输入框的代理。
 // 它比真实 tap 略晚（键盘弹出前的准备阶段已消耗一部分），所以本探针测的是
 // 「开始编辑 → 键盘出现」，而非完整的「手指离开屏幕 → 键盘出现」。
 // SwiftUI 单行 TextField 底层是 UITextField；axis:.vertical 等场景可能映射为
 // UITextView，因此两种 textDidBeginEditing 都要监听。
        guard pending == nil else { return } // 同一弹出周期内的重复 beginEditing 忽略
        let nowEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        let now = ProcessInfo.processInfo.systemUptime
 // 点击时刻由窗口级「只观察、不拦截」的手势识别器记录；2s 内才算本轮点击。
        let tapUptime = lastTouchDownUptime.flatMap { now - $0 <= tapWindow ? $0 : nil }
        sequence += 1
        let sample = PendingSample(
            sequence: sequence,
            source: source,
            tapUptime: tapUptime,
            beginUptime: now,
            beginEpochMs: nowEpochMs
        )
        pending = sample
        measureMainQueueLatency(sequence: sequence)
        scheduleCycleTimeout(sequence: sequence)
    }

 /// t0 时主线程占用：投递一个空任务，测「入队 → 真正被执行」的毫秒差。
    private static func measureMainQueueLatency(sequence: Int) {
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let delayMs = Double(DispatchTime.now().uptimeNanoseconds - enqueuedAt) / 1_000_000
            guard var sample = pending, sample.sequence == sequence, sample.mainQueueMs == nil else {
                return // 本轮已结束/被替换，丢弃这次迟到的主队列测量
            }
            sample.mainQueueMs = delayMs
            pending = sample
        }
    }

    private static func scheduleCycleTimeout(sequence: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cycleTimeout) {
            guard pending?.sequence == sequence else { return }
            guard pending?.willShowMs != nil else {
 // 连 willShow 都没看到：键盘本来就没弹（如键盘已在显示、只切换了输入框），
 // 直接丢弃本轮，避免往 JSONL 里写无意义的 -1 样本。
                pending = nil
                return
            }
 // willShow 已到但 didShow 超时：记录已有数据并收尾（didShow 落 -1）。
            finalizeCycle()
        }
    }

    private static func markWillShow() {
 // 正常顺序是「textDidBeginEditing → keyboardWillShow → keyboardDidShow」。
 // 若某个系统/输入法版本把 willShow 提前到 beginEditing 之前，本轮
 // beginToWillShowMs 会落 -1（didShow 口径不受影响）；真机取证时若看到
 // -1，说明该假设需要按实测顺序调整。
        guard var sample = pending, sample.willShowMs == nil else { return }
        sample.willShowMs = millisecondsSinceBegin(sample.beginUptime)
        pending = sample
    }

    private static func markDidShow() {
        guard var sample = pending, sample.didShowMs == nil else { return }
        sample.didShowMs = millisecondsSinceBegin(sample.beginUptime)
        pending = sample
        finalizeCycle()
    }

 // MARK: - 收尾：落盘 + 更新摘要

 /// 一次键盘弹出周期结束：写一行 JSONL、刷新 Settings 摘要，然后重置等待下一轮。
    private static func finalizeCycle() {
        guard let sample = pending else { return }
        pending = nil
        lastText.write(summaryText(for: sample))
        appendSampleToFile(sample)
    }

    private static func summaryText(for sample: PendingSample) -> String {
        func format(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.0fms", value)
        }
        return "tapToBegin \(format(sample.tapToBeginMs)) · willShow \(format(sample.willShowMs)) · didShow \(format(sample.didShowMs)) · mainQueue \(format(sample.mainQueueMs))"
    }

 /// 追加一行样本；写文件放在后台串行队列，避免 I/O 干扰被测的主线程口径。
    private static func appendSampleToFile(_ sample: PendingSample) {
        guard let url = fileURL else { return }
        let payload: [String: Any] = [
            "ts": sample.beginEpochMs,
            "tapToBeginMs": sample.tapToBeginMs ?? -1,
            "tapToWillShowMs": sample.tapToWillShowMs ?? -1,
            "tapToDidShowMs": sample.tapToDidShowMs ?? -1,
            "beginToWillShowMs": sample.willShowMs ?? -1,
            "beginToDidShowMs": sample.didShowMs ?? -1,
            "mainQueueMs": sample.mainQueueMs ?? -1,
            "source": sample.source,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        ioQueue.async {
            appendLine(line, to: url)
        }
    }

 /// 追加一行并裁剪到最近 `maxSampleCount` 条（读-改-写整文件；样本量小，代价可接受）。
    private static func appendLine(_ line: String, to url: URL) {
        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        lines.append(line)
        if lines.count > maxSampleCount {
            lines = Array(lines.suffix(maxSampleCount))
        }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
 // 诊断探针静默吞掉写入失败：拿不到样本不允许影响产品行为。
        }
    }

    private static func millisecondsSinceBegin(_ beginUptime: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - beginUptime) * 1000
    }

 // MARK: - 内部状态

 /// 尚未收尾的一次键盘弹出周期。
    private struct PendingSample {
        let sequence: Int
        let source: String
 /// 手指 touchDown 时刻（systemUptime，秒）；未捕获到点击时为 nil。
        let tapUptime: TimeInterval?
 /// 开始编辑时刻（systemUptime，秒）。
        let beginUptime: TimeInterval
 /// 开始编辑时刻（epoch 毫秒），写进 JSONL 的 `ts`。
        let beginEpochMs: Int64
        var mainQueueMs: Double?
        var willShowMs: Double?
        var didShowMs: Double?

 /// 手指点击 → 开始编辑（app 侧焦点/布局耗时）。
        var tapToBeginMs: Double? {
            guard let tapUptime else { return nil }
            return (beginUptime - tapUptime) * 1000
        }

        var tapToWillShowMs: Double? {
            guard let tapToBeginMs, let willShowMs else { return nil }
            return tapToBeginMs + willShowMs
        }

        var tapToDidShowMs: Double? {
            guard let tapToBeginMs, let didShowMs else { return nil }
            return tapToBeginMs + didShowMs
        }
    }

 /// 以下状态只在 main queue 上读写（观察者回调、asyncAfter 收尾都在 main）。
    private static var observers: [NSObjectProtocol] = []
    private static var didStart = false
 /// 窗口级「只观察 tapDown」的手势识别器 + 最近一次 touchDown 时刻。
    private static var touchRecognizer: TouchTimestampGestureRecognizer?
    private static var windowObserver: NSObjectProtocol?
    private static var lastTouchDownUptime: TimeInterval?
    private static var sequence = 0
    private static var pending: PendingSample?

 /// 后台写盘队列（串行，保证追加/裁剪不互相竞争）。
    private static let ioQueue = DispatchQueue(label: "com.dshm.keyboardProbe.io", qos: .utility)

 // MARK: - 点击时刻捕获（tap → beginEditing 段）

 /// 在 key window 上挂一个「只观察 touchDown、永不识别」的手势识别器：
 /// `cancelsTouchesInView = false` + 状态始终停留在 `.possible`，因此不拦截
 /// 任何点击/滚动；只记录最近一次 touchDown 的 systemUptime，供 beginEditing
 /// 关联出「手指点击 → 开始编辑」这一段（app 侧焦点/布局耗时）。
    private static func attachTouchObserverWhenPossible() {
        DispatchQueue.main.async {
            guard didStart, touchRecognizer == nil else { return }
            let recognizer = TouchTimestampGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.onTouchDown = { uptime in
                lastTouchDownUptime = uptime
            }
            guard let window = currentKeyWindow() else {
                if windowObserver == nil {
                    windowObserver = NotificationCenter.default.addObserver(
                        forName: UIWindow.didBecomeVisibleNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        attachTouchObserverWhenPossible()
                    }
                }
                return
            }
            window.addGestureRecognizer(recognizer)
            touchRecognizer = recognizer
        }
    }

    private static func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private final class TouchTimestampGestureRecognizer: UIGestureRecognizer {
        var onTouchDown: ((TimeInterval) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouchDown?(ProcessInfo.processInfo.systemUptime)
 // 永远不进入 recognized：只观察，不参与手势竞争。
            state = .possible
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .possible
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .failed
        }
    }

 /// 摘要字符串线程安全盒子：写方在 main queue，读方是 SwiftUI（main）；
 /// 仍用锁兜底，避免意外的调度顺序造成数据竞争。
    private static let lastText = LockedText()

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func write(_ newValue: String?) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }

        func read() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
