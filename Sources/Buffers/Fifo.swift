/// A first-in, first-out queue: appends at the back and removes from the front without moving the rest, compacting
/// only once the consumed part is at least half of it (and 1,024 elements).
public struct Fifo<Element> {
    @usableFromInline var items: [Element] = []
    @usableFromInline var head = 0

    @inlinable public init() {}

    @inlinable public var count: Int { items.count - head }
    @inlinable public var isEmpty: Bool { head == items.count }

    @inlinable public mutating func append(_ item: Element) {
        items.append(item)
    }

    @inlinable public mutating func popFirst() -> Element? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024 && head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }
}

extension Fifo: Sendable where Element: Sendable {}
