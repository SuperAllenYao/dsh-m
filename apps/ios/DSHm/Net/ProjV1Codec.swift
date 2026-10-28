import Foundation

// MARK: - 协议 v1（projV1）投影帧：wire 解码 + 行映射
//
// 契约（唯一字节级依据）：<internal-doc>
// §3 二进制编码 v0（tagged tree）、§4 分帧、§5 下游传输、§7 lazy-fetch。
//
// 一条 WS binary message 恰好一个帧流单元：
// [1B 0x02][u32 LE headerLen][header JSON UTF-8][u32 LE chunkLen][gzip(payload)]
// payload = tagged tree 编码的**该帧行数组**（行 = {s,t,y,...投影后的 data 键}）。
//
// 解码是严格模式（错配/畸形帧一律抛 `P1ProtocolError.violation`，由
// `P1Channel.violate` 走既有 fatal/fallback 语义关连接）：版本、header 形状、
// 帧长/尾随字节、tag 0…7、varint、字符串 UTF-8、f64 LE、gzip、行形状。
// 参考实现：packages/dsh-m-link/lib/proj-encode.js（decodePageFrame/decodeValue）。

/// 投影帧的 wire 常量（契约 §3/§4/§5）。
enum ProjV1Wire {
 /// binary WS 帧版本头：0x02 = 投影页帧（0x01 仍是 gzip 文本信封）。
    static let version: UInt8 = 0x02
 /// 每帧 header 的 `fmt`。
    static let headerFormat = "page-v1"
 /// 契约版本（header `v`）。
    static let protocolVersion = 1
 /// header JSON 的防御上限（真实 header ≈ 120B；防对端塞超长头）。
    static let maxHeaderBytes = 64 * 1024
}

/// 投影页一帧的 header（契约 §4）。
///
/// `f == 0` 时必带 `frames/records/hasMore/batch`（整页首部）；后续帧只需
/// `{fmt,v,rpcId,f}`。0 记录页只发一个 `frames:0, records:0, hasMore:<page.hasMore>`
/// 的 header-only 帧。
///
/// 未知键忽略（前向兼容）；形状非法 = 协议违规。
struct ProjV1FrameHeader: Equatable, Sendable {
    var fmt: String
    var v: Int
    var rpcId: String
 /// 帧下标（0 起，递减页序里的第几帧）。
    var f: Int
 /// 总帧数（仅 f == 0 必带；0 = 空页）。
    var frames: Int?
 /// 总记录数（仅 f == 0 必带）。
    var records: Int?
 /// 页面最老事件之前是否还有历史（仅 f == 0 必带）。
    var hasMore: Bool?
 /// 每帧批大小（仅 f == 0 必带，契约固定 100）。
    var batch: Int?

 /// 本帧是否是本页的最后一帧（空页按完成处理）。
    func isLastFrame(totalFrames: Int?) -> Bool {
        guard let totalFrames else { return true }
        return f >= totalFrames - 1
    }
}

extension ProjV1FrameHeader {
 /// 严格解码一帧 header JSON（未知键忽略；缺必填/类型不符/自相矛盾 = 违规）。
    static func decode(json data: Data) throws -> ProjV1FrameHeader {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProjV1Codec.violation("header 不是合法 JSON")
        }
        guard let object = value.objectValue else {
            throw ProjV1Codec.violation("header 不是 JSON 对象")
        }
        guard let fmt = object["fmt"]?.stringValue else {
            throw ProjV1Codec.violation("header.fmt 缺失")
        }
        guard fmt == ProjV1Wire.headerFormat else {
            throw ProjV1Codec.violation("header.fmt=\(fmt) 不受支持（需要 \(ProjV1Wire.headerFormat)）")
        }
        guard let v = object["v"]?.int else {
            throw ProjV1Codec.violation("header.v 缺失")
        }
        guard v == ProjV1Wire.protocolVersion else {
            throw ProjV1Codec.violation("header.v=\(v) 不受支持（需要 \(ProjV1Wire.protocolVersion)）")
        }
        guard let rpcId = object["rpcId"]?.stringValue, !rpcId.isEmpty else {
            throw ProjV1Codec.violation("header.rpcId 缺失")
        }
        guard rpcId.utf8.count <= P1ProtocolLimits.maxRPCIdLength else {
            throw ProjV1Codec.violation("header.rpcId 过长")
        }
        guard let f = object["f"]?.int, f >= 0 else {
            throw ProjV1Codec.violation("header.f 缺失或非法")
        }
        if f == 0 {
            guard let frames = object["frames"]?.int, frames >= 0 else {
                throw ProjV1Codec.violation("首帧 header.frames 缺失或非法")
            }
            guard let records = object["records"]?.int, records >= 0 else {
                throw ProjV1Codec.violation("首帧 header.records 缺失或非法")
            }
            guard let hasMore = object["hasMore"]?.boolValue else {
                throw ProjV1Codec.violation("首帧 header.hasMore 缺失或非法")
            }
            guard let batch = object["batch"]?.int, batch >= 1 else {
                throw ProjV1Codec.violation("首帧 header.batch 缺失或非法")
            }
            guard frames > 0 || records == 0 else {
                throw ProjV1Codec.violation("header.frames=0 但 records=\(records)")
            }
            return ProjV1FrameHeader(
                fmt: fmt,
                v: v,
                rpcId: rpcId,
                f: f,
                frames: frames,
                records: records,
                hasMore: hasMore,
                batch: batch
            )
        }
 // 后续帧：只校验出现的可选字段的自洽性（frames 若带必须覆盖 f）。
        let frames = object["frames"]?.int
        if let frames, frames <= f {
            throw ProjV1Codec.violation("header.frames=\(frames) 小于等于 f=\(f)")
        }
        let records = object["records"]?.int
        if let records, records < 0 {
            throw ProjV1Codec.violation("header.records 非法")
        }
        return ProjV1FrameHeader(
            fmt: fmt,
            v: v,
            rpcId: rpcId,
            f: f,
            frames: frames,
            records: records,
            hasMore: object["hasMore"]?.boolValue,
            batch: object["batch"]?.int
        )
    }
}

/// 一条已解码的投影帧（header + 该帧行数组）。
struct ProjV1Frame: Equatable {
    var header: ProjV1FrameHeader
 /// tagged tree 解码出的行（对象数组，每行带 `s`/`y`，可选 `t`）。
 /// 空页帧为 `[]`。
    var rows: [JSONValue]
 /// 线上字节数（诊断/埋点用）。
    var wireBytes: Int

    init(header: ProjV1FrameHeader, rows: [JSONValue], wireBytes: Int = 0) {
        self.header = header
        self.rows = rows
        self.wireBytes = wireBytes
    }
}

/// `0x02` 投影帧参考解码器（严格模式）。
enum ProjV1Codec {
    static func violation(_ message: String) -> P1ProtocolError {
        .violation("projV1: " + message)
    }

 /// 解码一条 WS binary message（帧流单元）。
 ///
 /// - Throws: `P1ProtocolError.violation` — 版本不符 / 长度不一致 / 尾随字节 /
 /// header 非法 / tag 越界 / varint 溢出 / 字符串非 UTF-8 / f64 非有限 /
 /// gzip 失败 / payload 尾随字节 / 行形状非法。
    static func decodeFrame(_ data: Data) throws -> ProjV1Frame {
        guard let version = data.first else {
            throw violation("空帧")
        }
        guard version == ProjV1Wire.version else {
            throw violation("线版本不支持: \(version)")
        }
        guard data.count >= 9 else {
            throw violation("帧头截断（\(data.count)B）")
        }
        let headerLength = Int(readUInt32LE(data, at: 1))
        guard headerLength <= ProjV1Wire.maxHeaderBytes else {
            throw violation("header 过大（\(headerLength)B）")
        }
        let headerStart = 5
        let headerEnd = headerStart + headerLength
        guard headerEnd + 4 <= data.count else {
            throw violation("header 截断（\(headerLength)B）")
        }
        let headerRange = (data.startIndex + headerStart)..<(data.startIndex + headerEnd)
        let header = try ProjV1FrameHeader.decode(json: data.subdata(in: headerRange))
        let chunkLength = Int(readUInt32LE(data, at: headerEnd))
        let chunkStart = headerEnd + 4
        guard chunkStart + chunkLength == data.count else {
            throw violation("chunk 长度与帧长不符（chunk=\(chunkLength)B, 剩余=\(data.count - chunkStart)B）")
        }
        if chunkLength == 0 {
 // 只允许「0 记录页」的 header-only 帧（契约 §4）。
            guard header.frames == 0 else {
                throw violation("chunk 为空但 header.frames=\(header.frames.map(String.init) ?? "-")")
            }
            return ProjV1Frame(header: header, rows: [], wireBytes: data.count)
        }
        guard (header.frames ?? 1) > 0 else {
            throw violation("header.frames=0 却带 chunk")
        }
        let chunk = data.subdata(in: (data.startIndex + chunkStart)..<data.endIndex)
        let payload: Data
        do {
            payload = try HTTPCompression.gunzip(chunk)
        } catch {
            throw violation("帧 gunzip 失败: \(error.localizedDescription)")
        }
        let rows = try decodeRows(payload)
        return ProjV1Frame(header: header, rows: rows, wireBytes: data.count)
    }

 /// 解码一帧 payload：tagged tree 行数组（尾随字节 = 违规）。
    static func decodeRows(_ payload: Data) throws -> [JSONValue] {
        var reader = ByteReader(data: payload)
        let value = try decodeValue(&reader, depth: 0)
        guard reader.remaining == 0 else {
            throw violation("payload 尾随字节 \(reader.remaining)B")
        }
        guard case .array(let rows) = value else {
            throw violation("payload 不是行数组")
        }
        for row in rows {
            try validateRow(row)
        }
        return rows
    }

 // MARK: Tagged tree

 /// 投影行形状校验（契约 §2.1：`s`/`y` 必带，`t` 可选）。
    static func validateRow(_ row: JSONValue) throws {
        guard let object = row.objectValue else {
            throw violation("行不是对象")
        }
        guard let seq = object["s"]?.int, seq >= 0 else {
            throw violation("行缺少合法的 s")
        }
        guard let type = object["y"]?.stringValue, !type.isEmpty else {
            throw violation("行缺少 y")
        }
        if let t = object["t"] {
            guard t.intValue != nil else {
                throw violation("行 t 不是整数（s=\(seq)）")
            }
        }
    }

 /// tag 0…7 自描述值解码（契约 §3）。
    static func decodeValue(_ reader: inout ByteReader, depth: Int = 0) throws -> JSONValue {
        guard depth <= 64 else {
            throw violation("嵌套过深")
        }
        let tag = try reader.readUInt8()
        switch tag {
        case 0x00:
            return .null
        case 0x01:
            return .bool(true)
        case 0x02:
            return .bool(false)
        case 0x03:
            let raw = try reader.readUvarint()
            let magnitude = Int64(bitPattern: raw >> 1)
            return .int((raw & 1) == 1 ? ~magnitude : magnitude)
        case 0x04:
            let bits = try reader.readUInt64LE()
            let value = Double(bitPattern: bits)
            guard value.isFinite else {
                throw violation("f64 不是有限数")
            }
            return .double(value)
        case 0x05:
            let length = try reader.readUvarint()
            guard length <= UInt64(reader.remaining) else {
                throw violation("字符串长度越界")
            }
            let bytes = try reader.readBytes(Int(length))
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw violation("字符串不是合法 UTF-8")
            }
            return .string(text)
        case 0x06:
            let count = try reader.readUvarint()
            guard count <= UInt64(reader.remaining) else {
                throw violation("数组长度越界")
            }
            var values: [JSONValue] = []
            values.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                values.append(try decodeValue(&reader, depth: depth + 1))
            }
            return .array(values)
        case 0x07:
            let count = try reader.readUvarint()
            guard count <= UInt64(reader.remaining) else {
                throw violation("对象键数越界")
            }
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                let keyLength = try reader.readUvarint()
                guard keyLength <= UInt64(reader.remaining) else {
                    throw violation("对象键长度越界")
                }
                let keyBytes = try reader.readBytes(Int(keyLength))
                guard let key = String(data: keyBytes, encoding: .utf8) else {
                    throw violation("对象键不是合法 UTF-8")
                }
                guard object[key] == nil else {
                    throw violation("对象键重复: \(key)")
                }
                object[key] = try decodeValue(&reader, depth: depth + 1)
            }
            return .object(object)
        default:
            throw violation("未知 tag \(tag)")
        }
    }

 // MARK: Byte helpers

 /// 帧内字节游标（不复制 payload；越界即违规）。
    struct ByteReader {
        let data: Data
        private var index: Data.Index

        init(data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        var remaining: Int { data.endIndex - index }

        mutating func readUInt8() throws -> UInt8 {
            guard index < data.endIndex else {
                throw ProjV1Codec.violation("字节流截断")
            }
            let byte = data[index]
            index = data.index(after: index)
            return byte
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else {
                throw ProjV1Codec.violation("字节流截断（需要 \(count)B，剩 \(remaining)B）")
            }
            let end = data.index(index, offsetBy: count)
            let slice = data[index..<end]
            index = end
            return Data(slice)
        }

 /// LEB128 无符号 varint（≤ 10 字节，禁止溢出）。
        mutating func readUvarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            for _ in 0..<10 {
                let byte = try readUInt8()
                let chunk = UInt64(byte & 0x7f)
                if shift >= 64 {
                    throw ProjV1Codec.violation("varint 过长")
                }
                let shifted = chunk << shift
                if (shifted >> shift) != chunk {
                    throw ProjV1Codec.violation("varint 溢出")
                }
                result |= shifted
                if (byte & 0x80) == 0 { return result }
                shift += 7
            }
            throw ProjV1Codec.violation("varint 过长")
        }

 /// 8 字节 IEEE754 little-endian（契约 §3 tag 4）。
        mutating func readUInt64LE() throws -> UInt64 {
            let bytes = try readBytes(8)
            var bits: UInt64 = 0
            for (offset, byte) in bytes.enumerated() {
                bits |= UInt64(byte) << UInt64(offset * 8)
            }
            return bits
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

// MARK: - 行 → App 模型映射

/// 投影行（契约 §2.1）与 App 既有模型之间的唯一映射点。
///
/// 投影路径与 JSON 路径必须产出**逐条等价**的 `SessionEvent`（行序不变量：
/// 不允许丢记录，只允许丢 data），这样 `SessionJournal.prepend` 的 gap-free
/// 连续性校验与 `SessionRowBuilder` 的渲染都与旧路径一致。
enum ProjV1RowMapping {
 /// 一行 → `SessionEvent`：`type=y`、`seq=s`、`time=t`、`data=行去掉 s/t/y`。
 /// 行里可能带 lazy-fetch 标记 `tr`，它随 data 保留（契约 §7）。
    static func event(from row: JSONValue) throws -> SessionEvent {
        guard let object = row.objectValue else {
            throw ProjV1Codec.violation("行不是对象")
        }
        guard let seq = object["s"]?.int, seq >= 0 else {
            throw ProjV1Codec.violation("行缺少合法的 s")
        }
        guard let type = object["y"]?.stringValue, !type.isEmpty else {
            throw ProjV1Codec.violation("行缺少 y")
        }
        let time = object["t"]?.intValue
        var data: [String: JSONValue] = [:]
        for (key, value) in object where key != "s" && key != "t" && key != "y" {
            data[key] = value
        }
        return SessionEvent(
            type: type,
            seq: seq,
            time: time,
            data: .object(data),
            surfaceOp: nil,
            sourceEventSeqs: nil
        )
    }

    static func events(from rows: [JSONValue]) throws -> [SessionEvent] {
        try rows.map(event(from:))
    }

 /// 投影行 → 旧 JSON 页信封（`{records:[{type:"event",event,seq}], hasMore}`）。
 ///
 /// 供 `LinkService.unary("session/page")` 在投影协商成功时保持既有语义
 /// （预取/兜底调用方无需知道 wire 是 0x02）。记录按 seq 升序（Host JSON 页口径）。
    static func pageValue(rows: [JSONValue], hasMore: Bool) throws -> JSONValue {
        let events = try events(from: rows).sorted { $0.seq < $1.seq }
        let records = events.map { event -> JSONValue in
            .object([
                "type": .string("event"),
                "seq": .int(Int64(event.seq)),
                "event": event.jsonValue,
            ])
        }
        return .object([
            "records": .array(records),
            "hasMore": .bool(hasMore),
        ])
    }
}

extension SessionEvent {
 /// `SessionEvent` → JSON 对象（`session/page` 记录口径）。
    var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string(type),
            "seq": .int(Int64(seq)),
        ]
        if let time { fields["time"] = .int(time) }
        if let data { fields["data"] = data }
        return .object(fields)
    }
}
