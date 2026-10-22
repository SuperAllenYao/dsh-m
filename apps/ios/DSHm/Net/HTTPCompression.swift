import Compression
import Foundation

/// gzip response decoding via libcompression.
///
/// The plugin gzips large unary JSON responses (`Content-Encoding: gzip`, see
/// link-server.js). Apple's `COMPRESSION_ZLIB` codec is raw DEFLATE (IETF
/// RFC 1951), so the gzip container is stripped here: the 10+ byte header
/// (optional FEXTRA / FNAME / FCOMMENT / FHCRC fields are skipped) and the
/// 8-byte CRC32+ISIZE trailer. Output is inflated incrementally through a
/// fixed 8 KiB window instead of allocating a buffer sized from the (possibly
/// attacker-controlled) compressed length.
enum HTTPCompression {
 /// Hard cap for a decompressed body; a malformed/compressed bomb response
 /// fails instead of exhausting memory.
    static let maxDecompressedBytes = 64 * 1024 * 1024

    static func isGzip(_ contentEncoding: String?) -> Bool {
        guard let contentEncoding else { return false }
 // `content-encoding` may list multiple codings ("identity, gzip").
        return contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains("gzip")
    }

    enum DecodeError: Error, LocalizedError {
        case malformedHeader(String)
        case truncated
        case decoderFailure(Int32)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .malformedHeader(let detail): return "gzip 头非法：\(detail)"
            case .truncated: return "gzip 数据不完整"
            case .decoderFailure(let status): return "gzip 解压失败（compression status \(status)）"
            case .tooLarge: return "gzip 解压结果超过上限"
            }
        }
    }

 /// Incrementally inflates a complete gzip member.
    static func gunzip(_ data: Data) throws -> Data {
        let header = try parseHeader(data)
        let body = data.subdata(in: header..<data.count)
        guard body.count >= 8 else { throw DecodeError.truncated }
 // Trailer is CRC32(4) + ISIZE(4); libcompression stops at the deflate
 // end-of-stream and the caller does not need the checksum (the plugin
 // is TLS-pinned and its payload is re-validated as JSON).
        let deflate = body.subdata(in: 0..<(body.count - 8))

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw DecodeError.decoderFailure(-1)
        }
        defer { compression_stream_destroy(&stream) }

        let windowSize = 8 * 1024
        let window = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSize)
        defer { window.deallocate() }

        var output = Data()
        output.reserveCapacity(min(deflate.count * 4, maxDecompressedBytes))
        var status = COMPRESSION_STATUS_OK

        deflate.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                status = COMPRESSION_STATUS_END
                return
            }
            stream.src_ptr = base
            stream.src_size = deflate.count
            repeat {
                stream.dst_ptr = window
                stream.dst_size = windowSize
                status = compression_stream_process(&stream, 0)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = windowSize - stream.dst_size
                    if produced > 0 {
                        if output.count + produced > maxDecompressedBytes {
                            status = COMPRESSION_STATUS_ERROR
                            return
                        }
                        output.append(window, count: produced)
                    }
                default:
                    return
                }
            } while status == COMPRESSION_STATUS_OK
        }

        if status != COMPRESSION_STATUS_END {
            throw DecodeError.decoderFailure(Int32(status.rawValue))
        }
        return output
    }

 /// Returns the offset of the first deflate byte. Bounds-checked so a
 /// malformed header cannot trap.
    private static func parseHeader(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 18 else { throw DecodeError.truncated }
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else {
            throw DecodeError.malformedHeader("magic")
        }
        guard bytes[2] == 0x08 else {
            throw DecodeError.malformedHeader("compression method \(bytes[2])")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw DecodeError.truncated }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
            guard offset <= bytes.count else { throw DecodeError.truncated }
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard offset <= bytes.count else { throw DecodeError.truncated }
        return offset
    }
}
