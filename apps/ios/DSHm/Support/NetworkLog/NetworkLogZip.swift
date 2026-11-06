import Foundation

/// Minimal **stored** (no compression) ZIP writer for the network-log export.
///
/// Why hand-rolled: the app must not grow a third-party dependency for one archive,
/// and the export payload is NDJSON (already close to incompressible at this size),
/// so deflate would buy little for a lot of code. The layout written here is plain
/// PKZIP 2.0 — local file headers + data, central directory, end-of-central-record —
/// with UTF-8 file names flagged in the general-purpose bit (DD-06).
///
/// Format limits (not ZIP64): each entry and the archive must stay below 4 GB, and
/// at most 65535 entries. The export is capped at 20 MB of events plus incident
/// snapshots, so both ceilings are far away.
enum NetworkLogZip {
    enum ZipError: Error {
        case tooManyEntries
        case entryTooLarge
        case nameTooLong
        case archiveTooLarge
    }

    /// Builds a ZIP archive from `(name, data)` pairs, preserving order.
    ///
    /// `name` may contain `/` separators ("events/…"); leading slashes are stripped
    /// and empty names are rejected so an entry can never escape the archive root.
    static func make(entries: [(name: String, data: Data)]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw ZipError.tooManyEntries }

        let dos = dosDateTime(from: Date())
        var output = Data()
        var central = Data()
        var written = 0

        for entry in entries {
            let name = sanitized(name: entry.name)
            guard !name.isEmpty else { continue }
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else { throw ZipError.nameTooLong }
            guard entry.data.count <= Int(UInt32.max) else { throw ZipError.entryTooLarge }
            guard output.count <= Int(UInt32.max) else { throw ZipError.archiveTooLarge }

            let offset = UInt32(output.count)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let flags: UInt16 = 0x0800 // bit 11: file name is UTF-8

            // Local file header.
            append(UInt32(0x0403_4B50), to: &output) // signature
            append(UInt16(20), to: &output) // version needed to extract (2.0)
            append(flags, to: &output)
            append(UInt16(0), to: &output) // method: stored
            append(dos.time, to: &output)
            append(dos.date, to: &output)
            append(crc, to: &output)
            append(size, to: &output) // compressed size == stored size
            append(size, to: &output)
            append(UInt16(nameData.count), to: &output)
            append(UInt16(0), to: &output) // extra field length
            output.append(nameData)
            output.append(entry.data)

            // Central directory header.
            append(UInt32(0x0201_4B50), to: &central)
            append(UInt16(20), to: &central) // version made by (MS-DOS, 2.0)
            append(UInt16(20), to: &central) // version needed
            append(flags, to: &central)
            append(UInt16(0), to: &central) // method: stored
            append(dos.time, to: &central)
            append(dos.date, to: &central)
            append(crc, to: &central)
            append(size, to: &central)
            append(size, to: &central)
            append(UInt16(nameData.count), to: &central)
            append(UInt16(0), to: &central) // extra field length
            append(UInt16(0), to: &central) // comment length
            append(UInt16(0), to: &central) // disk number start
            append(UInt16(0), to: &central) // internal attributes
            append(UInt32(0), to: &central) // external attributes
            append(offset, to: &central) // local header offset
            central.append(nameData)
            written += 1
        }

        let entryCount = UInt16(written)
        guard output.count <= Int(UInt32.max) else { throw ZipError.archiveTooLarge }
        let centralOffset = UInt32(output.count)
        guard central.count <= Int(UInt32.max) else { throw ZipError.archiveTooLarge }
        let centralSize = UInt32(central.count)
        output.append(central)

        // End of central directory record.
        append(UInt32(0x0605_4B50), to: &output)
        append(UInt16(0), to: &output) // this disk
        append(UInt16(0), to: &output) // disk with central directory
        append(entryCount, to: &output)
        append(entryCount, to: &output)
        append(centralSize, to: &output)
        append(centralOffset, to: &output)
        append(UInt16(0), to: &output) // archive comment length
        return output
    }

    // MARK: - CRC32 (IEEE 802.3, reflected, polynomial 0xEDB88320)

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    // MARK: - Helpers

    private static func sanitized(name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        return cleaned
    }

    /// Number of real entries (empty names are skipped before writing).
    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// MS-DOS packed date/time. ZIP stores local time; out-of-range years clamp to
    /// the format's 1980…2107 window instead of trapping.
    private static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        let dosDate = UInt16((year - 1980) << 9 | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (dosTime, dosDate)
    }
}
