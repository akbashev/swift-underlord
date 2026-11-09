// HTTP/1.1 requests parsed in place, straight out of the bytes a receive delivered: nothing is copied but a chunked
// body, which is decoded into an array of its own. The request is a view of those bytes, borrowed for the length of
// the closure that handles it.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// HTTP/1.1 (and 1.0) messages.
public enum HTTP {
    /// How big a request may get: its head (request line and header lines) and its body.
    public struct Limits: Sendable {
        /// Past this many bytes without the end of the head: 431.
        public var head: Int
        /// A body longer than this: 413.
        public var body: Int

        public init(head: Int = 64 * 1024, body: Int = 1024 * 1024) {
            self.head = head
            self.body = body
        }
    }

    public enum Version: Sendable {
        case http10, http11
    }

    /// A request, its parts borrowed from the bytes it was parsed from (a chunked body from its decoded copy).
    public struct Request: ~Escapable {
        /// A token, such as `GET`.
        public let method: Span<UInt8>
        /// The request target as sent: the path and any query.
        public let target: Span<UInt8>
        public let version: Version
        /// Whether the connection stays open after the response: HTTP/1.1 unless `Connection: close`, HTTP/1.0 only
        /// with `Connection: keep-alive`.
        public let keepAlive: Bool
        /// The header lines, each ending in CRLF.
        public let headers: Span<UInt8>
        /// The body: `Content-Length` bytes, or a chunked body decoded.
        public let body: Span<UInt8>

        @_lifetime(copy method, copy target, copy headers, copy body)
        init(method: Span<UInt8>, target: Span<UInt8>, version: Version, keepAlive: Bool, headers: Span<UInt8>,
             body: Span<UInt8>) {
            self.method = method
            self.target = target
            self.version = version
            self.keepAlive = keepAlive
            self.headers = headers
            self.body = body
        }

        /// The target up to its `?`.
        public var path: Span<UInt8> {
            @_lifetime(copy self) get {
                target.extracting(0..<(Bytes.find(target, 0x3F) ?? target.count))
            }
        }

        /// The target after its `?`; nil without one.
        public var query: Span<UInt8>? {
            @_lifetime(copy self) get {
                guard let mark = Bytes.find(target, 0x3F) else { return nil }
                return target.extracting((mark + 1)..<target.count)
            }
        }

        /// The value of the first header named `name` (written in lowercase; names match in any case), without the
        /// whitespace around it; nil if there is none.
        @_lifetime(copy self)
        public func header(_ name: StaticString) -> Span<UInt8>? {
            var pos = 0
            while let end = Bytes.findCRLF(headers, from: pos) {
                let line = headers.extracting(pos..<end)
                pos = end + 2
                guard let colon = Bytes.find(line, 0x3A),
                      Bytes.equalsIgnoringCase(line.extracting(0..<colon), name) else { continue }
                return Bytes.trimOWS(line.extracting((colon + 1)..<line.count))
            }
            return nil
        }
    }

    /// What parsing the start of a connection's bytes found.
    public enum Parsed<Handled: ~Copyable>: ~Copyable {
        /// A whole request, `consumed` bytes long (the next one, pipelined, starts there), and what handling it
        /// returned.
        case complete(consumed: Int, keepAlive: Bool, Handled)
        /// Not all of it yet. `sendContinue`: the client sent `Expect: 100-continue` and waits for a
        /// `100 Continue` (`HTTP.continueResponse`) before sending the body.
        case incomplete(sendContinue: Bool)
        /// Not a request this parser takes, to be answered with `status` and the connection closed: 400 malformed,
        /// 413 body too large, 431 head too large, 501 a transfer coding other than chunked.
        case rejected(status: UInt16)
    }

    /// Parses the request at the start of `bytes` and, when it is all there, hands it to `handle`.
    ///
    /// Checks the request line (a token method, a target without spaces or control bytes, HTTP/1.1 or 1.0) and every
    /// header line's name; reads `Content-Length` (repeats must agree), `Transfer-Encoding: chunked` (not with a
    /// `Content-Length`), `Connection` and `Expect`. Other headers are left in `Request.headers`, unread.
    public static func parse<Handled: ~Copyable, E: Error>(
        _ bytes: Span<UInt8>, limits: Limits = Limits(), _ handle: (borrowing Request) throws(E) -> Handled
    ) throws(E) -> Parsed<Handled> {
        guard let lineEnd = Bytes.findCRLF(bytes) else {
            return bytes.count > limits.head ? .rejected(status: 431) : .incomplete(sendContinue: false)
        }
        let requestLine = bytes.extracting(0..<lineEnd)
        guard let space1 = Bytes.find(requestLine, 0x20) else { return .rejected(status: 400) }
        let method = requestLine.extracting(0..<space1)
        guard Bytes.isToken(method), let space2 = Bytes.find(requestLine, 0x20, from: space1 + 1) else {
            return .rejected(status: 400)
        }
        let target = requestLine.extracting((space1 + 1)..<space2)
        guard target.count > 0 else { return .rejected(status: 400) }
        for i in 0..<target.count where target[i] <= 0x20 || target[i] == 0x7F { return .rejected(status: 400) }
        let versionText = requestLine.extracting((space2 + 1)..<requestLine.count)
        let version: Version
        if Bytes.equal(versionText, "HTTP/1.1") {
            version = .http11
        } else if Bytes.equal(versionText, "HTTP/1.0") {
            version = .http10
        } else {
            return .rejected(status: 400)
        }

        var contentLength: Int?
        var chunked = false
        var keepAlive = version == .http11
        var expectContinue = false
        let headersStart = lineEnd + 2
        var pos = headersStart
        var headEnd = 0
        while true {
            guard let end = Bytes.findCRLF(bytes, from: pos) else {
                return bytes.count > limits.head ? .rejected(status: 431) : .incomplete(sendContinue: false)
            }
            if end + 2 > limits.head { return .rejected(status: 431) }
            if end == pos {
                headEnd = pos + 2
                break
            }
            let line = bytes.extracting(pos..<end)
            pos = end + 2
            guard let colon = Bytes.find(line, 0x3A) else { return .rejected(status: 400) }
            let name = line.extracting(0..<colon)
            guard Bytes.isToken(name) else { return .rejected(status: 400) }
            let value = Bytes.trimOWS(line.extracting((colon + 1)..<line.count))
            switch name.count {
            case 14 where Bytes.equalsIgnoringCase(name, "content-length"):
                guard let n = Bytes.decimal(value) else { return .rejected(status: 400) }
                if let previous = contentLength, previous != n { return .rejected(status: 400) }
                contentLength = n
            case 10 where Bytes.equalsIgnoringCase(name, "connection"):
                if Bytes.equalsIgnoringCase(value, "close") {
                    keepAlive = false
                } else if Bytes.equalsIgnoringCase(value, "keep-alive") {
                    keepAlive = true
                }
            case 17 where Bytes.equalsIgnoringCase(name, "transfer-encoding"):
                guard Bytes.equalsIgnoringCase(value, "chunked") else { return .rejected(status: 501) }
                chunked = true
            case 6 where Bytes.equalsIgnoringCase(name, "expect"):
                expectContinue = Bytes.equalsIgnoringCase(value, "100-continue")
            default:
                break
            }
        }
        let headers = bytes.extracting(headersStart..<(headEnd - 2))

        if chunked {
            guard contentLength == nil else { return .rejected(status: 400) }
            switch decodeChunked(bytes.extracting(headEnd..<bytes.count), limit: limits.body) {
            case .complete(let decoded, let used):
                let request = Request(method: method, target: target, version: version, keepAlive: keepAlive,
                                      headers: headers, body: decoded.span)
                return .complete(consumed: headEnd + used, keepAlive: keepAlive, try handle(request))
            case .incomplete:
                // Room for the chunks' size lines and trailers past the body itself, then no more.
                if bytes.count - headEnd > limits.body + limits.head { return .rejected(status: 413) }
                return .incomplete(sendContinue: expectContinue)
            case .tooLarge:
                return .rejected(status: 413)
            case .malformed:
                return .rejected(status: 400)
            }
        }
        let length = contentLength ?? 0
        if length > limits.body { return .rejected(status: 413) }
        if bytes.count < headEnd + length { return .incomplete(sendContinue: expectContinue) }
        let request = Request(method: method, target: target, version: version, keepAlive: keepAlive,
                              headers: headers, body: bytes.extracting(headEnd..<(headEnd + length)))
        return .complete(consumed: headEnd + length, keepAlive: keepAlive, try handle(request))
    }

    private enum Chunked {
        /// The body, and how many bytes its chunks and trailers took.
        case complete([UInt8], Int)
        case incomplete
        case tooLarge
        case malformed
    }

    /// A chunked body: chunks of hexadecimal size (at most 8 digits, extensions after `;` ignored), then a zero-size
    /// chunk and any trailer lines, which are skipped.
    private static func decodeChunked(_ bytes: Span<UInt8>, limit: Int) -> Chunked {
        var body: [UInt8] = []
        var pos = 0
        while true {
            guard let end = Bytes.findCRLF(bytes, from: pos) else { return .incomplete }
            let line = bytes.extracting(pos..<end)
            let digits = Bytes.trimOWS(line.extracting(0..<(Bytes.find(line, 0x3B) ?? line.count)))
            guard digits.count > 0, digits.count <= 8 else { return .malformed }
            var size = 0
            for i in 0..<digits.count {
                let b = digits[i]
                switch b {
                case 0x30...0x39: size = size << 4 | Int(b - 0x30)
                case 0x61...0x66: size = size << 4 | Int(b - 0x61 + 10)
                case 0x41...0x46: size = size << 4 | Int(b - 0x41 + 10)
                default: return .malformed
                }
            }
            pos = end + 2
            if size == 0 {
                while true {
                    guard let trailerEnd = Bytes.findCRLF(bytes, from: pos) else { return .incomplete }
                    let last = trailerEnd == pos
                    pos = trailerEnd + 2
                    if last { return .complete(body, pos) }
                }
            }
            if body.count + size > limit { return .tooLarge }
            if bytes.count < pos + size + 2 { return .incomplete }
            bytes.extracting(pos..<(pos + size)).withUnsafeBufferPointer { body.append(contentsOf: $0) }
            if bytes[pos + size] != 0x0D || bytes[pos + size + 1] != 0x0A { return .malformed }
            pos += size + 2
        }
    }
}

extension HTTP.Parsed: Copyable where Handled: Copyable {}

/// The byte searches and comparisons parsing uses.
enum Bytes {
    /// The first `needle` in `hay[from..<end]` (memchr: the C library's vectorized search).
    @inline(__always) static func find(_ hay: Span<UInt8>, _ needle: UInt8, from: Int = 0, end: Int? = nil) -> Int? {
        let end = end ?? hay.count
        guard from < end else { return nil }
        return hay.withUnsafeBufferPointer { buffer -> Int? in
            guard let hit = memchr(buffer.baseAddress! + from, Int32(needle), end - from) else { return nil }
            return UnsafeRawPointer(buffer.baseAddress!).distance(to: UnsafeRawPointer(hit))
        }
    }

    /// The index of the first CRLF at or after `from`.
    @inline(__always) static func findCRLF(_ hay: Span<UInt8>, from: Int = 0) -> Int? {
        guard hay.count >= 2 else { return nil }
        let last = hay.count - 1
        var pos = from
        while pos < last {
            guard let cr = find(hay, 0x0D, from: pos, end: last) else { return nil }
            if hay[cr + 1] == 0x0A { return cr }
            pos = cr + 1
        }
        return nil
    }

    @inline(__always) static func equal(_ bytes: Span<UInt8>, _ text: StaticString) -> Bool {
        guard bytes.count == text.utf8CodeUnitCount else { return false }
        let t = text.utf8Start
        for i in 0..<bytes.count where bytes[i] != t[i] { return false }
        return true
    }

    /// Whether `bytes` spell `lower` (lowercase ASCII), in any case.
    @inline(__always) static func equalsIgnoringCase(_ bytes: Span<UInt8>, _ lower: StaticString) -> Bool {
        guard bytes.count == lower.utf8CodeUnitCount else { return false }
        let l = lower.utf8Start
        for i in 0..<bytes.count {
            var c = bytes[i]
            if c >= 0x41 && c <= 0x5A { c |= 0x20 }
            if c != l[i] { return false }
        }
        return true
    }

    /// Without the spaces and tabs at either end.
    @inline(__always) static func trimOWS(_ bytes: Span<UInt8>) -> Span<UInt8> {
        var a = 0
        var b = bytes.count
        while a < b && (bytes[a] == 0x20 || bytes[a] == 0x09) { a += 1 }
        while b > a && (bytes[b - 1] == 0x20 || bytes[b - 1] == 0x09) { b -= 1 }
        return bytes.extracting(a..<b)
    }

    /// A non-negative decimal integer; nil if empty, not all digits, or past `Int.max`.
    @inline(__always) static func decimal(_ bytes: Span<UInt8>) -> Int? {
        guard bytes.count > 0 else { return nil }
        var value = 0
        for i in 0..<bytes.count {
            let b = bytes[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let (times10, o1) = value.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times10.addingReportingOverflow(Int(b - 0x30))
            if o1 || o2 { return nil }
            value = sum
        }
        return value
    }

    /// An RFC 9110 token: visible ASCII without delimiters.
    @inline(__always) static func isToken(_ bytes: Span<UInt8>) -> Bool {
        guard bytes.count > 0 else { return false }
        for i in 0..<bytes.count {
            let b = bytes[i]
            if b <= 0x20 || b >= 0x7F { return false }
            switch b {
            case 0x28, 0x29, 0x3C, 0x3E, 0x40, 0x2C, 0x3B, 0x3A, 0x5C, 0x22, 0x2F, 0x5B, 0x5D, 0x3F, 0x3D, 0x7B, 0x7D:
                return false
            default:
                continue
            }
        }
        return true
    }
}
