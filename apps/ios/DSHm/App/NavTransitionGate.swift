import QuartzCore
import UIKit

/// 导航转场串行闸门（P0：subagent 大会话快速滑动后返回手势崩溃）。
///
/// 崩溃现场（两步真机 ips 完全一致）：
/// SwiftUI NavigationStackCoordinator.update → _viewControllers(forEntering:)
/// → UINavigationController.setViewControllers: → NSException → SIGABRT
/// 触发链：UpdateGroup.dispatchImmediately 里 SwiftUI 再次向导航控制器
/// setViewControllers —— 当时 UIKit 正在跑 interactive pop 转场。
///
/// 这个类型只做两件事（不接管任何导航、不替换 delegate）：
/// 1. 记录当前导航控制器（SystemEdgePopBridge 在视图上链时登记，弱引用）；
/// 2. 暴露 isTransitioning，让 AppModel 把「用户 pop 回写模型」排到转场结束之后。
@MainActor
final class NavTransitionGate {
    static let shared = NavTransitionGate()

    weak var navigationController: UINavigationController?

    private init() {}

 /// 兜底转场锁：SwiftUI 部分导航动画不暴露 transitionCoordinator，用短锁覆盖。
    private var lockedUntil: CFTimeInterval = 0

 /// 手势/转场开始（edge pan 允许 begin 时调用）。
    func noteTransitionStarted(duration: CFTimeInterval = 0.35) {
        lockedUntil = max(lockedUntil, CACurrentMediaTime() + duration)
    }

 /// 是否正处在 push/pop 转场中（含 interactive pop 进行中）。
    var isTransitioning: Bool {
        if CACurrentMediaTime() < lockedUntil { return true }
        guard let nav = navigationController else { return false }
        if nav.transitionCoordinator != nil { return true }
        if let top = nav.topViewController, top.transitionCoordinator != nil { return true }
        return false
    }
}
