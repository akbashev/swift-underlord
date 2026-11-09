// A growable byte buffer that owns its memory. It has exactly one owner and moves instead of being copied, so an
// append is a capacity check and a copy: no copy-on-write check, no reference count, and the memory goes when the
// owner does. What reads it borrows a `Span`, whose lifetime the compiler ties to the borrow.

/// A growable byte buffer. An empty one holds no memory.
///
/// Where `[UInt8]` checks that its storage is unique on every mutation and calls a generic, non-inlined
/// `append(contentsOf:)`, a `ByteBuffer` append is a capacity check and a `memcpy`.
///
/// ```swift
/// var out = ByteBuffer(capacity: 8 * 1024)
/// out.append("HTTP/1.1 200 OK\r\n")
/// out.append(maximum: 64) { span in span.append(0x7B) }
/// send(out.span)
/// ```
public struct ByteBuffer: ~Copyable {
    @usableFromInline var base: UnsafeMutablePointer<UInt8>?
    @usableFromInline var _count = 0
    @usableFromInline var _capacity = 0

    /// An empty buffer, holding no memory.
    @inlinable public init() {}

    /// An empty buffer with room for `capacity` bytes.
    @inlinable public init(capacity: Int) {
        if capacity > 0 {
            base = .allocate(capacity: capacity)
            _capacity = capacity
        }
    }

    @inlinable deinit {
        base?.deallocate()
    }

    /// The bytes in the buffer.
    @inlinable public var count: Int { _count }
    /// The bytes it can hold before it grows.
    @inlinable public var capacity: Int { _capacity }
    @inlinable public var isEmpty: Bool { _count == 0 }

    /// Room for `n` more bytes; the end of the bytes, where they go.
    @inlinable @inline(__always) mutating func reserve(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        if _count + n > _capacity { grow(to: _count + n) }
        return base.unsafelyUnwrapped + _count
    }

    /// Room for `n` more bytes past the end; for none, an empty buffer (a buffer that never allocated has no end to
    /// point at).
    @inlinable @inline(__always) mutating func room(_ n: Int) -> UnsafeMutableRawBufferPointer {
        n > 0 ? UnsafeMutableRawBufferPointer(start: reserve(n), count: n) : UnsafeMutableRawBufferPointer(start: nil, count: 0)
    }

    @usableFromInline @inline(never) mutating func grow(to needed: Int) {
        let next = Swift.max(needed, _capacity * 2, 64)
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        if let base {
            fresh.update(from: base, count: _count)
            base.deallocate()
        }
        base = fresh
        _capacity = next
    }

    /// Makes room for `n` more bytes now, so the next appends don't grow the buffer.
    @inlinable public mutating func reserveCapacity(forAppending n: Int) {
        if _count + n > _capacity { grow(to: _count + n) }
    }

    @inlinable @inline(__always) public mutating func append(_ byte: UInt8) {
        reserve(1).pointee = byte
        _count += 1
    }

    @inlinable @inline(__always) public mutating func append(_ raw: UnsafeRawBufferPointer) {
        guard let source = raw.baseAddress, raw.count > 0 else { return }
        UnsafeMutableRawPointer(reserve(raw.count)).copyMemory(from: source, byteCount: raw.count)
        _count += raw.count
    }

    @inlinable @inline(__always) public mutating func append(_ literal: StaticString) {
        append(UnsafeRawBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
    }

    @inlinable @inline(__always) public mutating func append(_ span: Span<UInt8>) {
        span.withUnsafeBytes { append($0) }
    }

    @inlinable @inline(__always) public mutating func append(_ bytes: borrowing [UInt8]) {
        bytes.withUnsafeBytes { append($0) }
    }

    @inlinable @inline(__always) public mutating func append(repeating byte: UInt8, count n: Int) {
        guard n > 0 else { return }
        reserve(n).update(repeating: byte, count: n)
        _count += n
    }

    /// Lets `body` fill up to `maximum` bytes past the end (a socket read straight into the buffer); returns what
    /// `body` returned, and keeps that many bytes if it is positive.
    @inlinable @inline(__always)
    public mutating func appendSpare(maximum: Int, _ body: (UnsafeMutableRawBufferPointer) -> Int) -> Int {
        let spare = room(maximum)
        let n = body(spare)
        if n > 0 { _count += n }
        return n
    }

    /// Lets `body` write up to `maximum` bytes past the end through an `OutputRawSpan` over that room (whose appends
    /// check the room left), and keeps what it wrote: a whole response in one reservation.
    @inlinable @inline(__always)
    public mutating func append(maximum: Int, _ body: (inout OutputRawSpan) -> Void) {
        let room = room(maximum)
        var output = OutputRawSpan(buffer: room, initializedCount: 0)
        body(&output)
        _count += output.finalize(for: room)
    }

    @inlinable @inline(__always) public subscript(i: Int) -> UInt8 {
        get {
            precondition(i >= 0 && i < _count, "ByteBuffer index out of range")
            return base.unsafelyUnwrapped[i]
        }
        set {
            precondition(i >= 0 && i < _count, "ByteBuffer index out of range")
            base.unsafelyUnwrapped[i] = newValue
        }
    }

    /// Writes `span` over the bytes at `offset` (the buffer already holds them).
    @inlinable public mutating func store(_ span: Span<UInt8>, at offset: Int) {
        precondition(offset >= 0 && offset + span.count <= _count, "ByteBuffer store out of range")
        span.withUnsafeBytes { source in
            guard let start = source.baseAddress else { return }
            UnsafeMutableRawPointer(base.unsafelyUnwrapped + offset).copyMemory(from: start, byteCount: source.count)
        }
    }

    /// Moves the `n` bytes at `from` down to `to`, over the ones in between.
    @inlinable public mutating func moveDown(from: Int, to: Int, count n: Int) {
        precondition(to >= 0 && to <= from && from + n <= _count, "ByteBuffer move out of range")
        (base.unsafelyUnwrapped + to).update(from: base.unsafelyUnwrapped + from, count: n)
    }

    /// Empties the buffer, keeping its memory.
    @inlinable public mutating func removeAll() {
        _count = 0
    }

    /// Empties the buffer and frees its memory.
    @inlinable public mutating func release() {
        base?.deallocate()
        base = nil
        _count = 0
        _capacity = 0
    }

    /// Keeps the first `n` bytes.
    @inlinable public mutating func truncate(_ n: Int) {
        if n < _count { _count = Swift.max(n, 0) }
    }

    /// Drops the first `n` bytes, moving the rest down.
    @inlinable public mutating func removeFirst(_ n: Int) {
        precondition(n >= 0 && n <= _count, "ByteBuffer removeFirst out of range")
        if n < _count { base.unsafelyUnwrapped.update(from: base.unsafelyUnwrapped + n, count: _count - n) }
        _count -= n
    }

    /// The bytes, borrowed for as long as the buffer is.
    @inlinable public var span: Span<UInt8> {
        @_lifetime(borrow self) borrowing get {
            let span = Span(_unsafeElements: UnsafeBufferPointer(start: base, count: _count))
            return _overrideLifetime(span, borrowing: self)
        }
    }

    @inlinable public func withUnsafeBytes<R, E: Error>(_ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
        try body(UnsafeRawBufferPointer(start: base, count: _count))
    }
}
