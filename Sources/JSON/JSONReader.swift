// Reading JSON without building anything: one validating pass over the bytes (RFC 8259, strings checked as UTF-8,
// nesting at most 64 deep) that notes where the members you ask for are, as places in the document. A string is
// decoded only when it is read, and only if it has escapes.
public import Buffers

public enum JSON {
    /// What a value is.
    public enum Kind: Sendable {
        case string, number, object, array, `true`, `false`, null
    }

    /// A member of an object, as places in the document: its key's text and, for a string value, its text (both
    /// without the quotes), or the whole value otherwise.
    public struct Member: Sendable {
        @usableFromInline let keyStart: UInt32
        @usableFromInline let keyEnd: UInt32
        @usableFromInline let valueStart: UInt32
        @usableFromInline let valueEnd: UInt32
        public let kind: Kind
        /// The key's text has escapes (`withString`-style decoding needed to compare it).
        public let keyEscaped: Bool
        /// A string value's text has escapes: `JSON.withString` decodes it.
        public let valueEscaped: Bool

        @usableFromInline init(key: Range<Int>, keyEscaped: Bool, value: Range<Int>, kind: Kind, valueEscaped: Bool) {
            keyStart = UInt32(truncatingIfNeeded: key.lowerBound)
            keyEnd = UInt32(truncatingIfNeeded: key.upperBound)
            valueStart = UInt32(truncatingIfNeeded: value.lowerBound)
            valueEnd = UInt32(truncatingIfNeeded: value.upperBound)
            self.kind = kind
            self.keyEscaped = keyEscaped
            self.valueEscaped = valueEscaped
        }

        /// Where the key's text is in the document.
        @inlinable public var key: Range<Int> { Int(keyStart)..<Int(keyEnd) }
        /// Where the value is: a string's text without its quotes, or the whole value.
        @inlinable public var value: Range<Int> { Int(valueStart)..<Int(valueEnd) }

        @usableFromInline static let none = Member(key: 0..<0, keyEscaped: false, value: 0..<0, kind: .null, valueEscaped: false)
    }

    /// What `scan` found: whether the document is an object, the last member of its top-level object named by each
    /// key asked for (by the key's position), and whether some string decodes to one with a NUL (`\u0000`).
    public struct Found<let n: Int> {
        @usableFromInline var members = InlineArray<n, Member>(repeating: .none)
        @usableFromInline var present: UInt64 = 0
        public internal(set) var isObject = false
        public internal(set) var hasNul = false

        @usableFromInline init() {}

        /// The member named by the `i`th key, if the object has one.
        @inlinable public subscript(i: Int) -> Member? { present & (1 << UInt64(i)) != 0 ? members[i] : nil }
    }

    /// Checks that `src` is one JSON value and, when it is an object, finds its members named by `keys` (at most 64;
    /// a later duplicate wins, as in JavaScript's `JSON.parse`). Builds and keeps nothing else; nil if the document
    /// isn't valid JSON.
    ///
    /// ```swift
    /// guard let fields = JSON.scan(body, keys: ["body", "tags"]), fields.isObject,
    ///       let text = fields[0], text.kind == .string else { return .badRequest }
    /// JSON.withString(body, text) { store($0) }
    /// ```
    public static func scan<let n: Int>(_ src: Span<UInt8>, keys: InlineArray<n, StaticString>) -> Found<n>? {
        precondition(n <= 64, "JSON.scan finds at most 64 keys")
        var scanner = Scanner(src)
        var found = Found<n>()
        scanner.skipWhitespace()
        if scanner.pos < src.count && src[scanner.pos] == 0x7B {
            found.isObject = true
            guard scanner.object(depth: 1, keys: keys, found: &found) else { return nil }
        } else {
            guard scanner.value(depth: 0) != nil else { return nil }
        }
        scanner.skipWhitespace()
        found.hasNul = scanner.sawNul
        return scanner.pos == src.count ? found : nil
    }

    /// Whether `src` is one valid JSON value.
    public static func isValid(_ src: Span<UInt8>) -> Bool {
        scan(src, keys: []) != nil
    }

    /// Calls `body` with a string member's text: in place, or decoded when it has escapes.
    public static func withString<R>(_ src: Span<UInt8>, _ member: Member, _ body: (Span<UInt8>) -> R) -> R {
        if !member.valueEscaped { return body(src.extracting(member.value)) }
        let decoded = unescape(src.extracting(member.value))
        return body(decoded.span)
    }

    /// A number member's value as an integer, if it is written as one that fits in an `Int64`.
    public static func integer(_ src: Span<UInt8>, _ member: Member) -> Int64? {
        guard member.kind == .number else { return nil }
        let text = src.extracting(member.value)
        var i = text.count > 0 && text[0] == 0x2D ? 1 : 0
        let negative = i == 1
        guard i < text.count else { return nil }
        var value: Int64 = 0
        while i < text.count {
            let c = text[i]
            guard (0x30...0x39).contains(c) else { return nil }
            let digit = Int64(c - 0x30)
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (v, o2) = negative ? m.subtractingReportingOverflow(digit) : m.addingReportingOverflow(digit)
            if o1 || o2 { return nil }
            value = v
            i += 1
        }
        return value
    }

    /// A number member's value.
    public static func number(_ src: Span<UInt8>, _ member: Member) -> Double? {
        guard member.kind == .number else { return nil }
        if let integer = integer(src, member) { return Double(integer) }
        let text = src.extracting(member.value)
        guard let string = Bytes.string(text), let double = Double(string), double.isFinite else { return nil }
        return double
    }

    /// A valid string's text with its escapes decoded.
    public static func unescape(_ text: Span<UInt8>) -> ByteBuffer {
        var out = ByteBuffer(capacity: text.count)
        var i = 0
        while i < text.count {
            let c = text[i]
            if c != 0x5C {
                out.append(c)
                i += 1
                continue
            }
            let e = text[i + 1]
            i += 2
            switch e {
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                var code = UInt32(hex4(text, i))
                i += 4
                if (0xD800...0xDBFF).contains(code) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (UInt32(hex4(text, i + 2)) - 0xDC00)
                    i += 6
                }
                for byte in UTF8.encode(Unicode.Scalar(code)!)! { out.append(byte) }
            default: out.append(e)
            }
        }
        return out
    }

    /// Whether a member's key is `key`: lengths and first bytes first, which rule out nearly every other key cheaply.
    @inline(__always) static func keyMatches(_ text: Span<UInt8>, escaped: Bool, _ key: StaticString) -> Bool {
        if escaped { return Bytes.equal(unescape(text).span, key) }
        let n = key.utf8CodeUnitCount
        guard text.count == n else { return false }
        if n == 0 { return true }
        let k = key.utf8Start
        guard text[0] == k[0] else { return false }
        for i in 1..<n where text[i] != k[i] { return false }
        return true
    }

    @inline(__always) static func hexValue(_ b: UInt8) -> UInt16? {
        switch b {
        case 0x30...0x39: UInt16(b - 0x30)
        case 0x61...0x66: UInt16(b - 0x61 + 10)
        case 0x41...0x46: UInt16(b - 0x41 + 10)
        default: nil
        }
    }

    /// Four hex digits at `at` (already checked).
    @inline(__always) static func hex4(_ text: Span<UInt8>, _ at: Int) -> UInt16 {
        var value: UInt16 = 0
        for k in 0..<4 { value = value << 4 | hexValue(text[at + k])! }
        return value
    }

    /// The validating pass over a borrowed document: it can't outlive the bytes it reads.
    struct Scanner: ~Escapable {
        let src: Span<UInt8>
        var pos = 0
        var sawNul = false

        @_lifetime(copy src)
        init(_ src: Span<UInt8>) {
            self.src = src
        }

        @inline(__always) mutating func skipWhitespace() {
            while pos < src.count {
                switch src[pos] {
                case 0x20, 0x09, 0x0D, 0x0A: pos += 1
                default: return
                }
            }
        }

        private mutating func literal(_ text: StaticString) -> Bool {
            let n = text.utf8CodeUnitCount
            guard pos + n <= src.count, Bytes.equal(src.extracting(pos..<(pos + n)), text) else { return false }
            pos += n
            return true
        }

        /// The value at `pos`, passed over: its kind and, for a string, whether it has escapes; nil if invalid.
        mutating func value(depth: Int) -> (kind: Kind, escaped: Bool)? {
            guard depth <= 64, pos < src.count else { return nil }
            switch src[pos] {
            case 0x22:
                guard let escaped = string() else { return nil }
                return (.string, escaped)
            case 0x7B:
                // `depth` counts the containers around this value; this one would be the next level, at most 64.
                guard depth < 64 else { return nil }
                var none = Found<0>()
                return object(depth: depth + 1, keys: [], found: &none) ? (.object, false) : nil
            case 0x5B:
                guard depth < 64 else { return nil }
                return array(depth: depth + 1) ? (.array, false) : nil
            case 0x74: return literal("true") ? (.true, false) : nil
            case 0x66: return literal("false") ? (.false, false) : nil
            case 0x6E: return literal("null") ? (.null, false) : nil
            case 0x2D, 0x30...0x39: return number() ? (.number, false) : nil
            default: return nil
            }
        }

        /// The string whose opening quote is at `pos`, passed over: whether it has escapes; nil if invalid.
        mutating func string() -> Bool? {
            pos += 1
            let start = pos
            var escaped = false
            var ascii = true
            while pos < src.count {
                let c = src[pos]
                if c == 0x22 {
                    // Escapes are ASCII, so the text with them is valid UTF-8 exactly when its other bytes are;
                    // all-ASCII text needs no further check.
                    guard ascii || Bytes.isValidUTF8(src.extracting(start..<pos)) else { return nil }
                    pos += 1
                    return escaped
                }
                if c >= 0x80 { ascii = false }
                if c < 0x20 { return nil }
                if c == 0x5C {
                    escaped = true
                    guard pos + 1 < src.count else { return nil }
                    switch src[pos + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        pos += 2
                    case 0x75:
                        guard let unit = hex4(at: pos + 2) else { return nil }
                        if unit == 0 { sawNul = true }
                        pos += 6
                        if (0xDC00...0xDFFF).contains(unit) { return nil }
                        if (0xD800...0xDBFF).contains(unit) {
                            guard pos + 1 < src.count, src[pos] == 0x5C, src[pos + 1] == 0x75,
                                  let low = hex4(at: pos + 2), (0xDC00...0xDFFF).contains(low) else { return nil }
                            pos += 6
                        }
                    default:
                        return nil
                    }
                    continue
                }
                pos += 1
            }
            return nil
        }

        private func hex4(at: Int) -> UInt16? {
            guard at + 4 <= src.count else { return nil }
            var value: UInt16 = 0
            for k in 0..<4 {
                guard let d = JSON.hexValue(src[at + k]) else { return nil }
                value = value << 4 | d
            }
            return value
        }

        private mutating func digits() -> Bool {
            let start = pos
            while pos < src.count, (0x30...0x39).contains(src[pos]) { pos += 1 }
            return pos > start
        }

        mutating func number() -> Bool {
            if src[pos] == 0x2D { pos += 1 }
            guard pos < src.count else { return false }
            if src[pos] == 0x30 {
                pos += 1
            } else if !digits() {
                return false
            }
            if pos < src.count && src[pos] == 0x2E {
                pos += 1
                guard digits() else { return false }
            }
            if pos < src.count && (src[pos] == 0x65 || src[pos] == 0x45) {
                pos += 1
                if pos < src.count && (src[pos] == 0x2B || src[pos] == 0x2D) { pos += 1 }
                guard digits() else { return false }
            }
            return true
        }

        /// The object whose brace is at `pos`, passed over; its members named by `keys` noted in `found`.
        mutating func object<let n: Int>(depth: Int, keys: InlineArray<n, StaticString>, found: inout Found<n>) -> Bool {
            pos += 1
            skipWhitespace()
            if pos < src.count && src[pos] == 0x7D {
                pos += 1
                return true
            }
            while true {
                skipWhitespace()
                guard pos < src.count, src[pos] == 0x22 else { return false }
                let keyStart = pos + 1
                guard let keyEscaped = string() else { return false }
                let key = keyStart..<(pos - 1)
                skipWhitespace()
                guard pos < src.count, src[pos] == 0x3A else { return false }
                pos += 1
                skipWhitespace()
                let valueStart = pos
                guard let (kind, valueEscaped) = value(depth: depth) else { return false }
                for k in 0..<n where JSON.keyMatches(src.extracting(key), escaped: keyEscaped, keys[k]) {
                    let range = kind == .string ? (valueStart + 1)..<(pos - 1) : valueStart..<pos
                    found.members[k] = Member(key: key, keyEscaped: keyEscaped, value: range, kind: kind, valueEscaped: valueEscaped)
                    found.present |= 1 << UInt64(k)
                }
                skipWhitespace()
                guard pos < src.count else { return false }
                if src[pos] == 0x2C {
                    pos += 1
                } else if src[pos] == 0x7D {
                    pos += 1
                    return true
                } else {
                    return false
                }
            }
        }

        mutating func array(depth: Int) -> Bool {
            pos += 1
            skipWhitespace()
            if pos < src.count && src[pos] == 0x5D {
                pos += 1
                return true
            }
            while true {
                skipWhitespace()
                guard value(depth: depth) != nil else { return false }
                skipWhitespace()
                guard pos < src.count else { return false }
                if src[pos] == 0x2C {
                    pos += 1
                } else if src[pos] == 0x5D {
                    pos += 1
                    return true
                } else {
                    return false
                }
            }
        }
    }
}

/// Byte helpers the reader and writer share.
enum Bytes {
    /// Whether `bytes` is valid UTF-8, by the standard library's validator.
    @inline(__always) static func isValidUTF8(_ bytes: Span<UInt8>) -> Bool {
        (try? UTF8Span(validating: bytes)) != nil
    }

    /// The bytes as a `String`, if they are valid UTF-8.
    static func string(_ bytes: Span<UInt8>) -> String? {
        var array = [UInt8]()
        array.reserveCapacity(bytes.count)
        for i in 0..<bytes.count { array.append(bytes[i]) }
        return String(validating: array, as: UTF8.self)
    }

    @inline(__always) static func equal(_ a: Span<UInt8>, _ b: StaticString) -> Bool {
        guard a.count == b.utf8CodeUnitCount else { return false }
        let p = b.utf8Start
        for i in 0..<a.count where a[i] != p[i] { return false }
        return true
    }
}
