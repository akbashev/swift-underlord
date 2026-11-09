import Buffers
import Testing

private func bytes(_ buffer: borrowing ByteBuffer) -> [UInt8] {
    buffer.withUnsafeBytes { Array($0) }
}

@Test func byteBufferAppendsAndGrows() {
    var buffer = ByteBuffer()
    #expect(buffer.isEmpty && buffer.capacity == 0)
    buffer.append("HTTP/1.1 ")
    buffer.append(0x32)
    buffer.append([0x30, 0x30] as [UInt8])
    buffer.append(repeating: 0x20, count: 2)
    for _ in 0..<100 { buffer.append(0x41) }
    let expected = Array("HTTP/1.1 200  ".utf8) + [UInt8](repeating: 0x41, count: 100)
    #expect(bytes(buffer) == expected)
    #expect(buffer.capacity >= buffer.count)
}

@Test func byteBufferEditsInPlace() {
    var buffer = ByteBuffer(capacity: 4)
    buffer.append("0123456789")
    buffer.removeFirst(3)
    #expect(bytes(buffer) == Array("3456789".utf8))
    let ab: [UInt8] = Array("ab".utf8)
    buffer.store(ab.span, at: 1)
    #expect(bytes(buffer) == Array("3ab6789".utf8))
    buffer.moveDown(from: 3, to: 1, count: 4)
    buffer.truncate(5)
    #expect(bytes(buffer) == Array("36789".utf8))
    buffer[0] = 0x5A
    #expect(buffer[0] == 0x5A && buffer.span.count == 5)
    buffer.removeAll()
    #expect(buffer.isEmpty && buffer.capacity > 0)
    buffer.release()
    #expect(buffer.capacity == 0)
}

@Test func byteBufferWritesThroughOutputRawSpan() {
    var buffer = ByteBuffer()
    buffer.append("<")
    buffer.append(maximum: 16) { out in
        out.append(0x61)
        out.append(0x62)
    }
    buffer.append(">")
    #expect(bytes(buffer) == Array("<ab>".utf8))
    let read = buffer.appendSpare(maximum: 8) { spare in
        spare[0] = 0x21
        return 1
    }
    #expect(read == 1 && bytes(buffer) == Array("<ab>!".utf8))
}

@Test func noRoomOnAnEmptyBuffer() {
    // Nothing allocated yet, so there is no end to point at: asking for no room must not need one.
    var buffer = ByteBuffer()
    buffer.append(maximum: 0) { _ in }
    let read = buffer.appendSpare(maximum: 0) { $0.count }
    #expect(read == 0 && buffer.isEmpty && buffer.capacity == 0)
}

/// Counts how many are alive, to check that `UniqueArray` ends each element exactly once.
private final class Census {
    var alive = 0
}

private struct Tracked: ~Copyable {
    let census: Census
    let value: Int
    init(_ census: Census, _ value: Int) {
        self.census = census
        self.value = value
        census.alive += 1
    }
    deinit { census.alive -= 1 }
}

@Test func uniqueArrayHoldsNoncopyableElements() {
    let census = Census()
    do {
        var array = UniqueArray<Tracked>(capacity: 1)
        for i in 0..<100 { array.append(Tracked(census, i)) }
        #expect(array.count == 100 && census.alive == 100)
        #expect(array[42].value == 42)
        if let last = array.popLast() {
            let value = last.value
            #expect(value == 99 && census.alive == 100)
        }
        #expect(census.alive == 99)
        array.removeAll()
        #expect(array.isEmpty && census.alive == 0)
        array.append(Tracked(census, 7))
    }
    #expect(census.alive == 0)
}

@Test func fifoKeepsOrderAcrossCompaction() {
    var queue = Fifo<Int>()
    var next = 0
    var expected = 0
    for round in 0..<10 {
        for _ in 0..<1_500 {
            queue.append(next)
            next += 1
        }
        for _ in 0..<(round % 2 == 0 ? 1_200 : 1_700) {
            guard let value = queue.popFirst() else { break }
            #expect(value == expected)
            expected += 1
        }
    }
    #expect(queue.count == next - expected)
    while let value = queue.popFirst() {
        #expect(value == expected)
        expected += 1
    }
    #expect(queue.isEmpty && expected == next)
}
