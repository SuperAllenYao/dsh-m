import Combine
import UIKit
import UserNotifications

/// Remote-notification lifecycle: permission -> APNs registration -> device token
/// -> link plugin `POST /devices/push-token`. Simulator cannot receive real APNs
/// pushes; it still compiles the same path and reports the limitation in Settings.
@MainActor
final class PushManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case simulatorUnavailable
        case denied
        case requesting
        case registered
        case failed(String)

        var label: String {
            switch self {
            case .idle: return L10n.t("未请求")
            case .simulatorUnavailable: return L10n.t("模拟器不可用（仅真机）")
            case .denied: return L10n.t("未授权")
            case .requesting: return L10n.t("请求中…")
            case .registered: return L10n.t("已注册")
            case .failed(let reason): return L10n.f("失败：%@", reason)
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var deviceTokenHex: String?
 /// Last successful link-plugin registration (mode/topic/fingerprint only;
 /// the full token never leaves the device in logs/UI).
    @Published private(set) var registration: LinkService.PushTokenRegistration?

 /// Called whenever a device token is available (AppModel forwards it to the link).
    var onToken: ((String) -> Void)?

 /// Development builds register sandbox tokens; TestFlight/App Store builds
 /// register production tokens (plugin contract PAIRING §5.3).
    var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .dshmPushTokenReceived)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if let hex = notification.object as? String, !hex.isEmpty {
                    self.deviceTokenHex = hex
                    self.status = .registered
                    self.onToken?(hex)
                } else {
                    let reason = notification.userInfo?["error"] as? String ?? "registration failed"
                    self.status = .failed(reason)
                }
            }
            .store(in: &cancellables)
    }

 /// Call on launch and after pairing succeeds.
    func bootstrap() {
 // E2E scaffolding: a fake 64-hex token lets the simulator exercise the
 // real POST /devices/push-token path (APNs delivery itself needs a device).
        if let fake = ProcessInfo.processInfo.environment["DSHM_FAKE_APNS_TOKEN"],
           fake.count >= 64, fake.allSatisfy({ $0.isHexDigit }) {
            deviceTokenHex = fake
            onToken?(fake)
            return
        }
        #if targetEnvironment(simulator)
 // Simulators cannot receive real APNs, but `xcrun simctl push` delivers
 // simulated notifications — banners and taps still require authorization,
 // so the push deep-link E2E
 // opts in explicitly. No product behavior is enabled by default.
        if ProcessInfo.processInfo.environment["DSHM_REQUEST_NOTIFICATIONS"] == "1" {
            requestAuthorization(allowSimulator: true)
            return
        }
        status = .simulatorUnavailable
        #else
        requestAuthorization()
        #endif
    }

    func markRegistered(_ registration: LinkService.PushTokenRegistration) {
        self.registration = registration
        status = .registered
    }

    func markRegistrationFailed(_ reason: String) {
        status = .failed(reason)
    }

    func requestAuthorization(allowSimulator: Bool = false) {
        #if targetEnvironment(simulator)
        guard allowSimulator else {
            status = .simulatorUnavailable
            return
        }
        #endif
        guard status != .requesting else { return }
        status = .requesting
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                if granted {
                    #if targetEnvironment(simulator)
 // Simulators have no APNs token; authorization alone is enough
 // for `xcrun simctl push` deliveries.
                    self.status = .registered
                    #else
                    UIApplication.shared.registerForRemoteNotifications()
                    #endif
                } else {
                    self.status = .denied
                }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

 /// Re-send the last token to the link plugin (e.g. after reconnect/pairing).
    func reRegister() {
        guard let deviceTokenHex else { return }
        onToken?(deviceTokenHex)
    }
}
