import Foundation

/// RFC 6455 frame model. Client to server frames must be masked; server to
/// client frames must not be.
struct WSFrame: Equatable {
    var fin: Bool
    var opcode: UInt8
    var payload: Data
}

enum WSOpcode {
    static let continuation: UInt8 = 0x0
    static let text: UInt8 = 0x1
    static let binary: UInt8 = 0x2
    static let close: UInt8 = 0x8
    static let ping: UInt8 = 0x9
    static let pong: UInt8 = 0xA
}

enum WSFrameCodec {
    static let maxFrameBytes = 16 * 1024 * 1024

    enum CodecError: Error, LocalizedError {
        case protocolViolation(String)

        var errorDescription: String? {
            switch self {
            case .protocolViolation(let reason): return "WebSocket 协议错误: \(reason)"
            }
        }
    }

 /// Encodes a masked client frame.
    static func encodeClientFrame(fin: Bool, opcode: UInt8, payload: Data) -> Data {
        var output = Data()
        output.append((fin ? 0x80 : 0x00) | (opcode & 0x0F))
        let count = payload.count
        let maskBit: UInt8 = 0x80
        if count < 126 {
            output.append(maskBit | UInt8(count))
        } else if count <= 0xFFFF {
            output.append(maskBit | 126)
            output.append(UInt8((count >> 8) & 0xFF))
            output.append(UInt8(count & 0xFF))
        } else {
            output.append(maskBit | 127)
            let value = UInt64(count)
            for index in stride(from: 56, through: 0, by: -8) {
                output.append(UInt8((value >> UInt64(index)) & 0xFF))
            }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for index in 0..<4 { mask[index] = UInt8.random(in: 0...255) }
        output.append(contentsOf: mask)
        var masked = [UInt8](repeating: 0, count: count)
        let bytes = [UInt8](payload)
        for index in 0..<count { masked[index] = bytes[index] ^ mask[index % 4] }
        output.append(contentsOf: masked)
        return output
    }

 /// Decodes one frame from the front of `buffer`; returns nil if incomplete.
    static func decode(from buffer: inout Data) throws -> WSFrame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer)
        let first = bytes[0]
        let second = bytes[1]
        guard (first & 0x70) == 0 else {
            throw CodecError.protocolViolation("RSV bits set")
        }
        let fin = (first & 0x80) != 0
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var value: UInt64 = 0
            for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
            offset += 8
            guard value <= UInt64(maxFrameBytes) else {
                throw CodecError.protocolViolation("frame too large")
            }
            length = Int(value)
        }
        guard length <= maxFrameBytes else {
            throw CodecError.protocolViolation("frame too large")
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Data(bytes[offset..<(offset + length)])
        if masked {
            for index in 0..<length {
                payload[index] = payload[index] ^ mask[index % 4]
            }
        }
        buffer.removeFirst(offset + length)
        return WSFrame(fin: fin, opcode: opcode, payload: payload)
    }

 /// Renders masked client frames as a whole buffer (unit-test helper).
    static func encodeForTesting(_ frame: WSFrame) -> Data {
        encodeClientFrame(fin: frame.fin, opcode: frame.opcode, payload: frame.payload)
    }
}
