import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?

    init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var observedLeafPin: String?

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
}

/// Incremental HTTP/1.1 response parser (headers + content-length / chunked /
/// until-close bodies). Sufficient for the DSH Remote API and link plugin, which
/// always answer a single HTTP/1.1 response per connection.
///
/// Implemented over a byte array on purpose: Data index arithmetic after
/// append/remove operations is a common source of out-of-range traps.
final class HTTPResponseParser {
    private enum State {
        case head
        case fixed(Int)
        case chunkSize
        case chunkData(Int)
        case chunkTerminator
        case chunkTrailer
        case untilClose
        case done
    }

    private var buffer: [UInt8] = []
    private var state: State = .head
    private var status = 0
    private var headers: [String: String] = [:]
    private var body = Data()
    private var result: HTTPResponse?

 /// Protocol version from the status line ("HTTP/1.1" / "HTTP/1.0").
    private(set) var protocolVersion = "HTTP/1.1"
 /// True when the response body was terminated by EOF instead of a declared
 /// length or chunked framing (M2b keep-alive: such a connection cannot be
 /// reused).
    private(set) var bodyEndedByClose = false

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)
        parse()
    }

 /// True when bytes of the *next* (unsolicited) message are already buffered;
 /// without pipelining that makes the connection unsafe to reuse.
    var hasBufferedBytes: Bool { !buffer.isEmpty }

 /// Prepares the parser for the next response on a reused connection.
    func reset() {
        buffer.removeAll()
        state = .head
        status = 0
        headers = [:]
        body = Data()
        result = nil
        protocolVersion = "HTTP/1.1"
        bodyEndedByClose = false
    }

 /// Signals EOF: only relevant for responses without a declared body length.
    @discardableResult
    func finishOnClose() -> HTTPResponse? {
        if case .untilClose = state {
            body.append(contentsOf: buffer)
            buffer.removeAll()
            state = .done
            bodyEndedByClose = true
            result = HTTPResponse(status: status, headers: headers, body: body, observedLeafPin: nil)
        }
        return result
    }

    var completed: HTTPResponse? { result }

    private func parse() {
        var progressed = true
        while progressed, result == nil {
            progressed = false
            switch state {
            case .head:
                guard let headerEnd = Self.findHeaderEnd(buffer) else { return }
                let headerBytes = Array(buffer[0..<(headerEnd - 4)])
                buffer.removeFirst(headerEnd)
                guard parseHead(headerBytes) else {
                    state = .done
                    return
                }
                let transferEncoding = headers["transfer-encoding"]?.lowercased() ?? ""
                if let lengthString = headers["content-length"], let length = Int(lengthString) {
                    state = length == 0 ? .done : .fixed(length)
                } else if transferEncoding.contains("chunked") {
                    state = .chunkSize
                } else if status == 204 || status == 304 || (100...199).contains(status) {
                    state = .done
                } else {
                    state = .untilClose
                }
                progressed = true
            case .fixed(let remaining):
                if buffer.isEmpty { return }
                let take = min(remaining, buffer.count)
                body.append(contentsOf: buffer[0..<take])
                buffer.removeFirst(take)
                state = remaining - take == 0 ? .done : .fixed(remaining - take)
                progressed = true
            case .chunkSize:
                guard let line = Self.findCRLF(buffer) else { return }
                let sizeText = String(bytes: buffer[0..<line.start], encoding: .utf8) ?? ""
                buffer.removeFirst(line.end)
                let value = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
                guard let size = Int(value.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    state = .done
                    return
                }
                state = size == 0 ? .chunkTrailer : .chunkData(size)
                progressed = true
            case .chunkData(let remaining):
                if buffer.isEmpty { return }
                let take = min(remaining, buffer.count)
                body.append(contentsOf: buffer[0..<take])
                buffer.removeFirst(take)
                state = remaining - take == 0 ? .chunkTerminator : .chunkData(remaining - take)
                progressed = true
            case .chunkTerminator:
                guard buffer.count >= 2 else { return }
                buffer.removeFirst(2)
                state = .chunkSize
                progressed = true
            case .chunkTrailer:
                if buffer.count >= 2, buffer[0] == 13, buffer[1] == 10 {
                    buffer.removeFirst(2)
                    state = .done
                    progressed = true
                } else if let headerEnd = Self.findHeaderEnd(buffer) {
                    buffer.removeFirst(headerEnd)
                    state = .done
                    progressed = true
                } else {
                    return
                }
            case .untilClose:
                body.append(contentsOf: buffer)
                buffer.removeAll()
                return
            case .done:
                result = HTTPResponse(status: status, headers: headers, body: body, observedLeafPin: nil)
                return
            }
        }
        if case .done = state, result == nil {
            result = HTTPResponse(status: status, headers: headers, body: body, observedLeafPin: nil)
        }
    }

    private func parseHead(_ bytes: [UInt8]) -> Bool {
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return false }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        status = code
        protocolVersion = String(parts[0]).uppercased()
        headers = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return true
    }

 /// Returns the index just past the CRLFCRLF terminator.
    private static func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = 0
        let limit = bytes.count - 3
        while index < limit {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    private static func findCRLF(_ bytes: [UInt8]) -> (start: Int, end: Int)? {
        guard bytes.count >= 2 else { return nil }
        var index = 0
        let limit = bytes.count - 1
        while index < limit {
            if bytes[index] == 13, bytes[index + 1] == 10 {
                return (index, index + 2)
            }
            index += 1
        }
        return nil
    }
}
