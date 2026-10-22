import Foundation

/// Turns a `session/follow` frame decode failure into one actionable line.
///
/// Before this, a malformed frame surfaced as the generic
/// `The data couldn't be read because it isn't in the correct format.` — no
/// frame type, no field name, nothing a user could report or we could act on
/// .
/// `DecodingError` carries the coding path and the expected type; keep both,
/// bounded so the banner stays readable.
enum FrameDecodeFailure {
 /// Longest detail fragment rendered in the error banner.
    static let maxDetailLength = 160

 /// Localized one-line cause for `error`, tagged with the frame's `type`.
    static func describe(_ error: Error, frame: JSONValue?) -> String {
        let frameType = frame?["type"]?.stringValue ?? "?"
        let detail: String
        switch error {
        case let DecodingError.keyNotFound(key, context):
            detail = "缺少字段 " + path(context.codingPath + [key])
        case let DecodingError.valueNotFound(type, context):
            detail = "字段 " + path(context.codingPath) + " 为空（期望 " + shortName(type) + "）"
        case let DecodingError.typeMismatch(type, context):
            detail = "字段 " + path(context.codingPath) + " 类型不符（期望 " + shortName(type) + "）"
        case let DecodingError.dataCorrupted(context):
            detail = "字段 " + path(context.codingPath) + " 数据损坏：" + context.debugDescription
        default:
            detail = error.localizedDescription
        }
        return "[" + frameType + "] " + truncate(detail)
    }

 /// `records[3].event.seq` style coding path (`<root>` when empty).
    static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else if result.isEmpty {
                result = key.stringValue
            } else {
                result += "." + key.stringValue
            }
        }
        return result
    }

    private static func shortName(_ type: Any.Type) -> String {
        String(describing: type)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxDetailLength else { return text }
        return String(text.prefix(maxDetailLength)) + "…"
    }
}
