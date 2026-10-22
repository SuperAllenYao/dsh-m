import Foundation
import Network

/// Turns Network.framework / POSIX / link errors into localized, readable text
/// while keeping the raw code for diagnostics.
///
/// This is the single display bridge used by views and view models. The enums
/// themselves (`LinkError`, `UserQuestionSubmitError`, `RemoteError`) live in
/// `Protocol/` and keep canonical zh-Hans `errorDescription` values for the
/// unit tests; localize here so English mode gets translations without touching
/// the wire models.
enum NetworkErrorInterpreter {
 /// Localized user-facing text for any error. Use this instead of
 /// `error.localizedDescription` in view models / views.
    static func message(for error: Error) -> String {
        if let linkError = error as? LinkError {
            return linkErrorMessage(linkError)
        }
        if let submitError = error as? UserQuestionSubmitError {
            return submitErrorMessage(submitError)
        }
        if let posix = error as? POSIXError {
            return message(posixCode: posix.code.rawValue, detail: posix.localizedDescription)
        }
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return message(posixCode: code.rawValue, detail: nwError.localizedDescription)
            case .dns(let code):
                return L10n.f("无法解析 Mac 地址（DNS code: %lld）", Int(code))
            case .tls(let status):
                return L10n.f("TLS 握手失败（OSStatus %lld）：请确认桌面端在线、二维码未过期，或重新配对", Int(status))
            @unknown default:
                return nwError.localizedDescription
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return message(posixCode: Int32(nsError.code), detail: nsError.localizedDescription)
        }
        return nsError.localizedDescription
    }

 // MARK: - LinkError (Protocol/RemoteModels.swift, display bridge only)

    private static func linkErrorMessage(_ error: LinkError) -> String {
        switch error {
        case .notPaired:
            return L10n.t("尚未配对")
        case .notConnected:
            return L10n.t("连接未就绪")
        case .tlsPinMismatch(let expected, let actual):
            return L10n.f("TLS 证书指纹不匹配（期望 %@…，实际 %@…）", expected, actual ?? L10n.t("无"))
        case .transport(let message):
 // Transport details are composed at the throw site and localized there.
            return message
        case .httpStatus(let status, let body):
            return L10n.f("HTTP %lld: %@", status, String(body.prefix(160)))
        case .malformedEnvelope(let message):
            return L10n.f("协议信封非法: %@", message)
        case .rpcMismatch(let expected, let actual):
            return L10n.f("rpcId 不匹配: %@ != %@", expected, actual)
        case .remote(let remoteError):
 // Host-provided business error text stays as-is (server content).
            return remoteError.message.isEmpty ? remoteError.code : "\(remoteError.code): \(remoteError.message)"
        case .cancelled:
            return L10n.t("已取消")
        case .timeout(let what):
            return L10n.f("超时: %@", what)
        }
    }

 // MARK: - UserQuestionSubmitError (Protocol/UserQuestionModels.swift)

    private static func submitErrorMessage(_ error: UserQuestionSubmitError) -> String {
        switch error {
        case .callNotFound(let callId):
            return L10n.f("该问答已不在等待队列中（callId: %@），已刷新状态", callId)
        case .noLiveRequest:
            return L10n.t("本机没有这条问答的实时等待请求（可能已在桌面端作答或等待已超时），请刷新后重试")
        case .unsupportedState(let raw):
            return L10n.f("不支持的问答状态：%@", raw.isEmpty ? L10n.t("未知") : raw)
        case .alreadySubmitting:
            return L10n.t("该问答正在提交中，请稍候")
        }
    }

 // MARK: - POSIX / Network.framework

    static func message(posixCode: Int32, detail: String) -> String {
        let readable: String
        switch posixCode {
        case 61: readable = L10n.t("无法连接 Mac（连接被拒绝：地址或端口不可达）")
        case 60: readable = L10n.t("连接 Mac 超时")
        case 65: readable = L10n.t("Mac 主机不可达，请确认 iPhone 与 Mac 在同一 Wi-Fi")
        case 51: readable = L10n.t("网络不可达，请检查 Wi-Fi 或蜂窝网络设置")
        case 54: readable = L10n.t("连接被重置，请重试")
        case 57: readable = L10n.t("网络连接已断开")
        case 50: readable = L10n.t("网络接口异常，请重试")
        default: readable = L10n.f("网络错误：%@", detail)
        }
        return L10n.f("%@（code: %lld）", readable, Int(posixCode))
    }
}
