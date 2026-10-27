import Foundation

/// 巨型过程组的**渲染/默认展示策略**。
///
/// 背景：样本会话里存在 291/243/98 步的过程组。旧实现（.full）把整组步骤放进
/// 同步 VStack，一次物化就要在一帧内布局几百个步骤行 → 主线程长任务（fast fling
/// 实测 >100ms 掉帧，用户感知为「快速滑动必卡死」）。
///
/// 设计决策：
/// - 巨型组（> 阈值，默认 40 步）**默认折叠**，只渲染组头；
/// - 展开巨型组时首屏只渲染前 ~40 步，其余用「展开其余 N 步」按钮继续追加；
/// (追加拍板：**单次操作最多展开 40 步**——首展 40、每点一次
/// 「展开其余」再追加 ≤40 步，逐批展开完，把每次操作的数据压力压到与
/// 「≤40 步普通组」同量级；此前首屏/批量均为 60 步，>40 步组连续展开
/// 会触发整页卡死。）
/// - 巨型组的展开/收起**不做逐帧高度动画**：同帧切态 + offset 补偿（组头钉住）；
/// - 普通组（≤ 阈值）完全保持现状：默认展开 + easeOutCubic 280ms 动画。
///
/// 纯性能开关（不改视觉规格）：
/// - DSHM_PGROUP_STRATEGY=full → 回到旧行为（巨型组也默认展开、全量平铺），
/// 仅用于 before/after 取证与回退；
/// - DSHM_PGROUP_STRATEGY=window → 巨型组展开态用既有固定高度窗口（实验）；
/// - DSHM_PGROUP_STRATEGY=default → 设计决策的新行为（默认）；
/// - DSHM_PGROUP_GIANT_THRESHOLD=<int> → 巨型组步数阈值（默认 40）；
/// - DSHM_PGROUP_INITIAL_STEPS=<int> → 巨型组展开时首屏渲染步数（默认 40）；
/// - DSHM_PGROUP_REVEAL_CHUNK=<int> → 每次「展开其余」追加步数（默认 40）。
enum ProcessGroupStepsLayoutPolicy {
    enum Strategy: String {
 /// 设计决策的新行为：巨型组默认折叠 + 首屏限量渲染 + 无逐帧动画。
        case collapsedProgressive = "default"
 /// 旧行为（回退/取证用）。
        case full
 /// 巨型组展开态用固定高度窗口（实验，不影响普通组）。
        case window
    }

 /// 生产默认：设计决策的新行为。
    static let defaultStrategy: Strategy = .collapsedProgressive
 /// 巨型组阈值（超过该步骤数视为巨型组）。
    static let defaultGiantThreshold: Int = 40
 /// 巨型组展开时首屏渲染的步骤数（设计决策：单次最多展开 40 步）。
    static let defaultInitialSteps: Int = 40
 /// 每次「展开其余 N 步」追加的步骤数（与首屏同批 40，逐次点按展开完）。
    static let defaultRevealChunk: Int = 40
 /// 「展开其余 N 步」按钮行高度（折叠/展开 Δ 计算用）。
    static let revealRowHeight: CGFloat = 32
 /// DEBUG 探针模式下暴露一个隐藏 AX 标记（process-giant-rendered = 已渲染/总步数），
 /// 供真机 E2E 断言「巨型组首屏限量渲染」而不依赖 AX 树里离屏步骤行。
    static let probeAXEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DSHM_HITCHDBG"] == "1"
        #else
        return false
        #endif
    }()

 // MARK: - 生效配置（env 覆盖 > 默认；启动后缓存，避免每帧读 ProcessInfo）

    private static let configuredStrategy: Strategy = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DSHM_PGROUP_STRATEGY"],
           let value = Strategy(rawValue: raw) {
            return value
        }
        #endif
        return defaultStrategy
    }()

    private static let configuredThreshold: Int = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DSHM_PGROUP_GIANT_THRESHOLD"],
           let value = Int(raw), value > 0 {
            return value
        }
        #endif
        return defaultGiantThreshold
    }()

    private static let configuredInitialSteps: Int = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DSHM_PGROUP_INITIAL_STEPS"],
           let value = Int(raw), value > 0 {
            return value
        }
        #endif
        return defaultInitialSteps
    }()

    private static let configuredRevealChunk: Int = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DSHM_PGROUP_REVEAL_CHUNK"],
           let value = Int(raw), value > 0 {
            return value
        }
        #endif
        return defaultRevealChunk
    }()

    static var strategy: Strategy { configuredStrategy }
    static var giantThreshold: Int { configuredThreshold }
    static var initialSteps: Int { max(1, configuredInitialSteps) }
    static var revealChunk: Int { max(1, configuredRevealChunk) }

 /// 该步骤数是否按巨型组处理（旧行为.full 下不降载）。
    static func isGiant(_ stepCount: Int) -> Bool {
        guard strategy != .full else { return false }
        return stepCount > giantThreshold
    }

 /// 巨型组是否默认折叠（设计决策：是；.full 旧行为下为否）。
    static func giantCollapsedByDefault(_ stepCount: Int) -> Bool {
        isGiant(stepCount)
    }

 /// 巨型组展开态是否使用固定高度窗口（实验策略）。
    static func giantUsesWindow(_ stepCount: Int) -> Bool {
        strategy == .window && isGiant(stepCount)
    }
}
