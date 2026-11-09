/// A growable array of noncopyable elements, reached in place: a subscript lends an element through
/// `unsafeAddress`, never copying it. A table of connections, each owning its buffers, fits here where `Array`
/// can't hold them at all.
///
/// ```swift
/// var connections = UniqueArray<Connection>(capacity: 1024)
/// connections.append(Connection())
/// connections[0].output.append("hello")    // in place
/// ```
public struct UniqueArray<Element: ~Copyable>: ~Copyable {
    @usableFromInline var base: UnsafeMutablePointer<Element>
    @usableFromInline var _count = 0
    @usableFromInline var _capacity: Int

    /// An empty array with room for `capacity` elements (at least one).
    @inlinable public init(capacity: Int = 0) {
        _capacity = Swift.max(capacity, 1)
        base = .allocate(capacity: _capacity)
    }

    @inlinable deinit {
        base.deinitialize(count: _count)
        base.deallocate()
    }

    @inlinable public var count: Int { _count }
    @inlinable public var isEmpty: Bool { _count == 0 }

    /// Element `i`, in place.
    @inlinable @inline(__always) public subscript(i: Int) -> Element {
        unsafeAddress {
            precondition(i >= 0 && i < _count, "UniqueArray index out of range")
            return UnsafePointer(base + i)
        }
        unsafeMutableAddress {
            precondition(i >= 0 && i < _count, "UniqueArray index out of range")
            return base + i
        }
    }

    @inlinable @inline(__always) public mutating func append(_ element: consuming Element) {
        if _count == _capacity { grow(to: _count + 1) }
        (base + _count).initialize(to: element)
        _count += 1
    }

    /// The last element, moved out.
    @inlinable @inline(__always) public mutating func popLast() -> Element? {
        guard _count > 0 else { return nil }
        _count -= 1
        return (base + _count).move()
    }

    /// Ends every element, keeping the memory.
    @inlinable public mutating func removeAll() {
        base.deinitialize(count: _count)
        _count = 0
    }

    @usableFromInline @inline(never) mutating func grow(to needed: Int) {
        let next = Swift.max(needed, _capacity * 2)
        let fresh = UnsafeMutablePointer<Element>.allocate(capacity: next)
        fresh.moveInitialize(from: base, count: _count)
        base.deallocate()
        base = fresh
        _capacity = next
    }
}
