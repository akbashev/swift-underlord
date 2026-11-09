// Appends to an `OutputRawSpan` over reserved room (`ByteBuffer.append(maximum:)`): literals, any value's bytes at any
// alignment, and decimal integers. Each append checks the room left, which `-Ounchecked` builds leave out.

@usableFromInline enum OutputRawSpanDigits {
    @usableFromInline static let pairs: StaticString = """
        00010203040506070809101112131415161718192021222324252627282930313233343536373839\
        40414243444546474849505152535455565758596061626364656667686970717273747576777879\
        8081828384858687888990919293949596979899
        """
}

extension OutputRawSpan {
    /// A literal's bytes.
    @inlinable @inline(__always) @_lifetime(self: copy self)
    public mutating func appendLiteral(_ literal: StaticString) {
        let n = literal.utf8CodeUnitCount
        withUnsafeMutableBytes { buffer, initialized in
            precondition(n <= buffer.count - initialized, "OutputRawSpan: no room for the literal")
            (buffer.baseAddress! + initialized).copyMemory(from: literal.utf8Start, byteCount: n)
            initialized += n
        }
    }

    /// `value`'s bytes, wherever the output has got to: `storeBytes` needs no alignment, where `append(_:as:)`
    /// initializes the memory as `T` and so assumes it (a vector store that faults on x86 when it isn't aligned).
    @inlinable @inline(__always) @_lifetime(self: copy self)
    public mutating func appendBytes<T: BitwiseCopyable>(of value: T) {
        let n = MemoryLayout<T>.size
        withUnsafeMutableBytes { buffer, initialized in
            precondition(n <= buffer.count - initialized, "OutputRawSpan: no room for the value")
            buffer.baseAddress!.storeBytes(of: value, toByteOffset: initialized, as: T.self)
            initialized += n
        }
    }

    /// `value` in decimal, at most 20 bytes, two digits per step.
    @inlinable @inline(__always) @_lifetime(self: copy self)
    public mutating func appendDecimal(_ value: Int64) {
        if value < 0 { append(0x2D) }
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var pos = 20
        var n = value.magnitude
        let pairs = OutputRawSpanDigits.pairs.utf8Start
        while n >= 100 {
            let rem = Int((n % 100) * 2)
            n /= 100
            pos -= 2
            digits[pos] = pairs[rem]
            digits[pos + 1] = pairs[rem + 1]
        }
        if n < 10 {
            pos -= 1
            digits[pos] = 0x30 + UInt8(n)
        } else {
            let rem = Int(n * 2)
            pos -= 2
            digits[pos] = pairs[rem]
            digits[pos + 1] = pairs[rem + 1]
        }
        for k in pos..<20 { append(digits[k]) }
    }
}
