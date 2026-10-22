import CryptoKit
import Foundation

/// RFC 8785 (JCS) subset used by the link plugin to sign the pairing payload.
///
/// The payload only contains strings, integers, arrays and plain objects, so the
/// canonical form is: keys sorted (UTF-16 code units; all payload keys are ASCII,
/// where Swift's ordering matches), no whitespace, JSON.stringify-compatible
/// string escaping, integers in decimal.
enum CanonicalJSON {
    enum CanonicalError: Error, LocalizedError {
        case unsupported(String)
        case nonIntegerNumber
        case nonFiniteNumber

        var errorDescription: String? {
            switch self {
            case .unsupported(let detail): return "canonical JSON 不支持: \(detail)"
            case .nonIntegerNumber: return "canonical JSON 只允许整数"
            case .nonFiniteNumber: return "canonical JSON 不允许非有限数"
            }
        }
    }

    static func encode(_ value: JSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double:
            throw CanonicalError.nonIntegerNumber
        case .string(let text):
            return encodeString(text)
        case .array(let items):
            return "[" + (try items.map { try encode($0) }.joined(separator: ",")) + "]"
        case .object(let object):
            let keys = object.keys.sorted()
            let pairs = try keys.map { key -> String in
                let encoded = try encode(object[key] ?? .null)
                return encodeString(key) + ":" + encoded
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private static let quote = String(UnicodeScalar(0x22)!)
    private static let backslash = String(UnicodeScalar(0x5C)!)

    /// JSON.stringify-compatible escaping for the payload's value domain.
    static func encodeString(_ text: String) -> String {
        var output = quote
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output += backslash + quote
            case 0x5C:
                output += backslash + backslash
            case 0x08:
                output += backslash + "b"
            case 0x09:
                output += backslash + "t"
            case 0x0A:
                output += backslash + "n"
            case 0x0C:
                output += backslash + "f"
            case 0x0D:
                output += backslash + "r"
            case 0x00..<0x20:
                output += backslash + "u" + String(format: "%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += quote
        return output
    }
}

/// Ed25519 verification of the signed QR pairing payload (host key in payload.host.key).
enum HostSignature {
    static func verify(payloadText: String) -> Bool {
        guard let data = payloadText.data(using: .utf8),
              var value = try? JSONDecoder().decode(JSONValue.self, from: data),
              var object = value.objectValue,
              let signatureText = object["sig"]?.stringValue,
              let signature = Data(base64URL: signatureText),
              let host = object["host"]?.objectValue,
              let keyText = host["key"]?.stringValue,
              let keyData = Data(base64URL: keyText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        object.removeValue(forKey: "sig")
        value = .object(object)
        guard let canonical = try? CanonicalJSON.encode(value) else { return false }
        return publicKey.isValidSignature(signature, for: Data(canonical.utf8))
    }
}
