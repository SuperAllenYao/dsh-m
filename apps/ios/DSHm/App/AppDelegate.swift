import UIKit
import UserNotifications

extension Notification.Name {
 /// object = device token hex string; userInfo["error"] on failure.
    static let dshmPushTokenReceived = Notification.Name("com.dshm.pushTokenReceived")
 /// object = sessionId (String?) from the tapped notification.
    static let dshmPushNotificationTapped = Notification.Name("com.dshm.pushNotificationTapped")
 /// object = `PushApprovalRoute` (allow/deny decision or invalid-payload
 /// fallback) from an approval notification action (M4 §3).
    static let dshmPushApprovalAction = Notification.Name("com.dshm.pushApprovalAction")
 /// object = `SilentPushEnvelope`; userInfo carries reason/sessionId (M4 §4).
    static let dshmSilentPushReceived = Notification.Name("com.dshm.silentPushReceived")
}

/// UIKit delegate needed for remote-notification registration callbacks. SwiftUI
/// `App` receives it through `@UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
 // M4 §3: register the approval category before any notification arrives.
 // Both actions require the device to be unlocked before iOS hands the
 // response to the app.
        UNUserNotificationCenter.current().setNotificationCategories([PushActionRouter.makeApprovalCategory()])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(
            name: .dshmPushTokenReceived,
            object: PushTokenFormatter.hex(deviceToken)
        )
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(
            name: .dshmPushTokenReceived,
            object: nil,
            userInfo: ["error": error.localizedDescription]
        )
    }

 // Foreground presentation: keep the notification visible while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
 // AC-13/AC-14：前台收到推送（提问/审批/状态变化）时广播一次
 // 「列表可刷新」提示。`$events` 之外的这条通道保证用户**停在列表页**时，
 // 卡片状态也能在推送到达后立即收敛，而不是等下一次 15s 兜底快照。
        NotificationCenter.default.post(
            name: .dshmPushPresentedInForeground,
            object: nil,
            userInfo: notification.request.content.userInfo
        )
        completionHandler([.banner, .list, .sound])
    }

 // Notification response: default tap deep-links to the session; the approval
 // actions are routed to AppModel, which answers `$events/result` with a
 // bounded retry and falls back to opening the session (M4 §3).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let route = PushActionRouter.route(userInfo: userInfo, actionIdentifier: response.actionIdentifier)
        switch route {
        case .approval, .fallback:
 // UIKit can deliver this response before SwiftUI builds AppModel
 // (app launched from a locked-screen action); park the route so the
 // cold-launch path is not lost, then post it for the normal path.
            PushActionInbox.shared.store(route)
            NotificationCenter.default.post(name: .dshmPushApprovalAction, object: route)
        case .deepLink(let sessionId):
 // Cold launch: AppModel may not exist yet, so park the id for
 // `AppModel.init` to drain; the NotificationCenter post remains the
 // primary path when the app is already running.
            PushDeepLinkInbox.shared.store(sessionId)
            NotificationCenter.default.post(name: .dshmPushNotificationTapped, object: sessionId)
        case .ignored:
            break
        }
        completionHandler()
    }

 // M4 §4: silent (content-available) pushes only pre-warm data; they never
 // approve or answer anything. Alert pushes report `.noData`.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let envelope = SilentPushEnvelope(userInfo: userInfo)
        guard envelope.isSilent else {
            completionHandler(.noData)
            return
        }
        NotificationCenter.default.post(
            name: .dshmSilentPushReceived,
            object: envelope,
            userInfo: envelope.notificationUserInfo
        )
        completionHandler(.newData)
    }
}

extension Notification.Name {
 /// 前台展示了推送横幅：列表页据此静默刷新一次卡片状态（AC-13/AC-14）。
    static let dshmPushPresentedInForeground = Notification.Name("dshmPushPresentedInForeground")
}
