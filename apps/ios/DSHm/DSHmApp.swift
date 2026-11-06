import SwiftUI

@main
struct DSHmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
 /// netlog T-02：前后台切换写 `app.lifecycle`，进后台把写者队列排空一次。
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
 // r7-inverted 取证：DSHM_ROTATION_PROBE=1 时替换 root（几何语义实验）。
                if ProcessInfo.processInfo.environment["DSHM_ROTATION_PROBE"] == "1" {
                    RotationProbeView()
                } else {
                    RootView()
                        .environmentObject(appModel)
                }
                #else
                RootView()
                    .environmentObject(appModel)
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    NetlogLifecycle.record("foreground")
                case .background:
 // 进后台：先记生命周期，再同步排空写者队列（flush 在写者队列上阻塞到
 // 已入队事件落盘），最后交给 AppDelegate 的短后台任务收尾。
                    NetlogLifecycle.record("background")
                    NetworkLog.flush()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}
