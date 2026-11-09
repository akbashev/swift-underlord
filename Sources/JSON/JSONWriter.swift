// Writing JSON: strings escaped 32 bytes at a time (one AVX2 compare where the CPU has it), copied whole when nothing
// in a chunk needs escaping, and integers two digits at a time. Into a `ByteBuffer`, or into an `OutputRawSpan` over
// room reserved for a whole response (`ByteBuffer.append(maximum:)`), whose appends check the room left.
public import Buffers

extension JSON {
    /// Whether 16 bytes need no escaping.
    @inlinable @inline(__always) static func clean16(_ v: SIMD16<UInt8>) -> Bool {
        let special = (v .== SIMD16(repeating: 0x22)) .| (v .== SIMD16(repeating: 0x5C)) .| (v .< SIMD16(repeating: 0x20))
        return !any(special)
    }

    /// Whether 32 bytes need no escaping.
    @inlinable @inline(__always) static func clean32(_ v: SIMD32<UInt8>) -> Bool {
        let special = (v .== SIMD32(repeating: 0x22)) .| (v .== SIMD32(repeating: 0x5C)) .| (v .< SIMD32(repeating: 0x20))
        return !any(special)
    }

    @usableFromInline static let hexDigits: StaticString = "0123456789abcdef"

    /// `src` as a JSON string, quotes included, appended to `dst`. At most `6 * src.count + 2` bytes.
    @inlinable public static func writeString(_ dst: inout ByteBuffer, _ src: Span<UInt8>) {
        dst.append(maximum: 6 * src.count + 2) { out in
            out.append(0x22)
            out.appendJSONStringContents(src)
            out.append(0x22)
        }
    }

    /// `value` in decimal, appended to `dst`.
    @inlinable public static func writeInteger(_ dst: inout ByteBuffer, _ value: Int64) {
        dst.append(maximum: 20) { $0.appendDecimal(value) }
    }
}

extension OutputRawSpan {
    /// `text` as a JSON string's contents, quotes not included; at most 6 bytes per byte: `\"`, `\\`, `\n`, `\r`,
    /// `\t`, and `\u00xx` for the other control characters.
    @inlinable @inline(__always) @_lifetime(self: copy self)
    public mutating func appendJSONStringContents(_ text: Span<UInt8>) {
        let bytes = text.bytes
        let n = text.count
        var i = 0
        while i + 32 <= n {
            let v = bytes.unsafeLoadUnaligned(fromByteOffset: i, as: SIMD32<UInt8>.self)
            if JSON.clean32(v) { appendBytes(of: v) } else { appendEscaping(text.extracting(i..<(i + 32))) }
            i += 32
        }
        if i + 16 <= n {
            let v = bytes.unsafeLoadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
            if JSON.clean16(v) { appendBytes(of: v) } else { appendEscaping(text.extracting(i..<(i + 16))) }
            i += 16
        }
        if i < n { appendEscaping(text.extracting(i..<n)) }
    }

    @inlinable @inline(__always) @_lifetime(self: copy self)
    mutating func appendEscaping(_ chunk: Span<UInt8>) {
        for j in 0..<chunk.count {
            let c = chunk[j]
            if c >= 0x20 && c != 0x22 && c != 0x5C {
                append(c)
            } else {
                appendEscape(c)
            }
        }
    }

    @usableFromInline @inline(never) @_lifetime(self: copy self)
    mutating func appendEscape(_ c: UInt8) {
        switch c {
        case 0x22: appendLiteral("\\\"")
        case 0x5C: appendLiteral("\\\\")
        case 0x0A: appendLiteral("\\n")
        case 0x0D: appendLiteral("\\r")
        case 0x09: appendLiteral("\\t")
        default:
            appendLiteral("\\u00")
            append(JSON.hexDigits.utf8Start[Int(c >> 4)])
            append(JSON.hexDigits.utf8Start[Int(c & 0x0F)])
        }
    }
}
