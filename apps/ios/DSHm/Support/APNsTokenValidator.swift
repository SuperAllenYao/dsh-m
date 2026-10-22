import Foundation

/// APNs device-token validation (nonisolated: usable from tests and any thread).
enum APNsTokenValidator {
 /// APNs device tokens are 64–256 hex chars (dsh-m-link contract §5.3).
    static func isValidHex(_ raw: String) -> Bool {
        let hex = raw.replacingOccurrences(of: " ", with: "")
        return (64...256).contains(hex.count) && hex.allSatisfy { $0.isHexDigit }
    }
}
