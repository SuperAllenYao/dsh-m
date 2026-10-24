import SwiftUI

@main
struct DSHmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
 // r7-inverted 取证：DSHM_ROTATION_PROBE=1 时替换 root（几何语义实验，用后即删）。
            if ProcessInfo.processInfo.environment["DSHM_ROTATION_PROBE"] == "1" {
                RotationProbeView()
            } else {
                RootView()
                    .environmentObject(appModel)
            }
        }
    }
}
