import CoreGraphics
import Foundation

/// 过程组「展开 / 收起」动画的纯逻辑（可单测，不依赖 UI）。
///
/// 用户口径：
/// - 现在的展开/收起是**线性**动画、且有卡顿感 → 改成**明显非线性**（easeOut 起步快、
/// 收尾慢，观感接近 spring 落位）并且时长 250–300ms；
/// - 组头（▣ N 步）在整个动画过程中必须**逐帧定住**（行高与 contentOffset 用同一条
/// 曲线、同一次状态提交插值）。
///
/// 曲线选择：easeOutCubic（1 - (1-p)^3）。
/// - 单调整形、无过冲：展开高度/offset 不会越过终值再回落（过冲会触发 ScrollView
/// 的边界 clamp，反而制造回弹卡顿）；
/// - 前 1/4 时间走完约 58% 行程、后 1/4 只走 9%，视觉上「快速展开、柔和收尾」，
/// 与线性/对称 smoothstep 有明确区分度。
enum GroupToggleAnimation {
 /// 展开/收起时长（秒）。用户口径 250–300ms，取 280ms。
    static let duration: Double = 0.28
 /// Reduce Motion 下的驱动时长：≈2 帧，仍有「高度 + offset 同帧生效」的语义，
 /// 但肉眼视为瞬时切换（终态与常规动画一致）。
    static let reducedMotionDuration: Double = 0.033

 /// 线性进度 → 非线性（easeOutCubic）进度。入参越界会被 clamp 到 0...1。
    static func eased(_ linear: Double) -> Double {
        let p = min(1, max(0, linear))
        let inverse = 1 - p
        return 1 - inverse * inverse * inverse
    }

 /// 同一条曲线的标量插值（行高 / offset 共用，保证组头逐帧定住）。
    static func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        guard start.isFinite, end.isFinite else { return end }
        let p = min(1, max(0, progress))
        return start + (end - start) * p
    }

 /// 动画总帧成本汇总（DEBUG 探针用）：逐帧主线程成本累计。
    struct FrameCost {
        var frames: Int = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0

        mutating func add(_ milliseconds: Double) {
            frames += 1
            totalMilliseconds += milliseconds
            if milliseconds > maxMilliseconds { maxMilliseconds = milliseconds }
        }
    }
}
