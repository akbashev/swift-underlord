// base64url (RFC 4648 §5) without padding, as JSON Web Tokens use it. Decoding is strict: a length no encoding
// has, a byte outside the alphabet, padding, or nonzero bits past the last byte make it fail, so each byte string
// has exactly one encoding that decodes.
public import Buffers

public enum Base64URL {
    @usableFromInline static let alphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    /// A base64url character's value; 0xFF if it isn't one.
    @inline(__always) static func value(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x41...0x5A: c - 0x41
        case 0x61...0x7A: c - 0x61 + 26
        case 0x30...0x39: c - 0x30 + 52
        case 0x2D: 62
        case 0x5F: 63
        default: 0xFF
        }
    }

    /// How many bytes `count` characters decode to; nil for a length no encoding has.
    public static func decodedCount(_ count: Int) -> Int? {
        switch count % 4 {
        case 1: nil
        case 2: count / 4 * 3 + 1
        case 3: count / 4 * 3 + 2
        default: count / 4 * 3
        }
    }

    /// `text` decoded into the start of `bytes`; how many bytes it took, or nil if `text` isn't base64url or
    /// `bytes` is too short.
    public static func decode(_ text: Span<UInt8>, into bytes: inout MutableSpan<UInt8>) -> Int? {
        guard let needed = decodedCount(text.count), needed <= bytes.count else { return nil }
        var t = 0
        var b = 0
        while t + 4 <= text.count {
            let v0 = value(text[t]), v1 = value(text[t + 1]), v2 = value(text[t + 2]), v3 = value(text[t + 3])
            if (v0 | v1 | v2 | v3) & 0x80 != 0 { return nil }
            let n = UInt32(v0) << 18 | UInt32(v1) << 12 | UInt32(v2) << 6 | UInt32(v3)
            bytes[b] = UInt8(truncatingIfNeeded: n >> 16)
            bytes[b + 1] = UInt8(truncatingIfNeeded: n >> 8)
            bytes[b + 2] = UInt8(truncatingIfNeeded: n)
            t += 4
            b += 3
        }
        switch text.count - t {
        case 2:
            let v0 = value(text[t]), v1 = value(text[t + 1])
            if (v0 | v1) & 0x80 != 0 || v1 & 0x0F != 0 { return nil }
            bytes[b] = v0 << 2 | v1 >> 4
            b += 1
        case 3:
            let v0 = value(text[t]), v1 = value(text[t + 1]), v2 = value(text[t + 2])
            if (v0 | v1 | v2) & 0x80 != 0 || v2 & 0x03 != 0 { return nil }
            let n = UInt32(v0) << 18 | UInt32(v1) << 12 | UInt32(v2) << 6
            bytes[b] = UInt8(truncatingIfNeeded: n >> 16)
            bytes[b + 1] = UInt8(truncatingIfNeeded: n >> 8)
            b += 2
        default:
            break
        }
        return b
    }

    /// `text` decoded into an array of its own; nil if it isn't base64url.
    public static func decode(_ text: Span<UInt8>) -> [UInt8]? {
        guard let count = decodedCount(text.count) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        var span = bytes.mutableSpan
        return decode(text, into: &span) == nil ? nil : bytes
    }

    /// `bytes` encoded, appended to `out`: 4 characters per 3 bytes, no padding.
    public static func encode(_ bytes: Span<UInt8>, into out: inout ByteBuffer) {
        out.append(maximum: (bytes.count + 2) / 3 * 4) { text in
            let a = alphabet.utf8Start
            var i = 0
            while i + 3 <= bytes.count {
                let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
                text.append(a[Int(n >> 18)])
                text.append(a[Int(n >> 12 & 63)])
                text.append(a[Int(n >> 6 & 63)])
                text.append(a[Int(n & 63)])
                i += 3
            }
            switch bytes.count - i {
            case 1:
                let n = UInt32(bytes[i]) << 16
                text.append(a[Int(n >> 18)])
                text.append(a[Int(n >> 12 & 63)])
            case 2:
                let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
                text.append(a[Int(n >> 18)])
                text.append(a[Int(n >> 12 & 63)])
                text.append(a[Int(n >> 6 & 63)])
            default:
                break
            }
        }
    }
}
