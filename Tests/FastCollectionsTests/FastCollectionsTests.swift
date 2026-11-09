@testable import FastCollections
import Testing

@Test func sortsLikeTheStandardLibrary() {
    var generator = SystemRandomNumberGenerator()
    for count in [0, 1, 2, 3, 15, 16, 17, 33, 100, 1_000, 10_000] {
        for range in [3, 1_000_000] {
            let values = (0..<count).map { _ in Int.random(in: 0..<range, using: &generator) }
            var sorted = values
            sorted.sortUnstable()
            #expect(sorted == values.sorted(), "\(count) values below \(range)")
            var descending = values
            descending.sortUnstable(by: >)
            #expect(descending == values.sorted(by: >))
        }
    }
}

@Test func sortsTheShapesThatHurtQuicksort() {
    let n = 5_000
    let shapes: [[Int]] = [
        Array(0..<n), Array((0..<n).reversed()), [Int](repeating: 7, count: n),
        (0..<n).map { $0 < n / 2 ? $0 : n - $0 },  // organ pipe
        (0..<n).map { $0 % 2 == 0 ? $0 : n - $0 },  // interleaved
    ]
    for shape in shapes {
        var sorted = shape
        sorted.sortUnstable()
        #expect(sorted == shape.sorted())
    }
}

@Test func sortsASpanInPlace() {
    var values = [9, 4, 7, 1, 8, 2, 6, 3, 5, 0] + Array((10..<40).reversed())
    let expected = values.sorted(by: >)
    var span = values.mutableSpan
    span.sortUnstable(by: >)
    _ = consume span
    #expect(values == expected)
}

@Test func heapsortAlone() {
    // The fallback for ranges that keep splitting badly, which random input never reaches.
    var generator = SystemRandomNumberGenerator()
    for count in [0, 1, 2, 5, 64, 1_001] {
        var values = (0..<count).map { _ in Int.random(in: 0..<50, using: &generator) }
        let expected = values.sorted()
        values.withUnsafeMutableBufferPointer { buffer in
            if let p = buffer.baseAddress { Sorting.heapsort(p, buffer.count, by: <) }
        }
        #expect(values == expected)
    }
}

@Test func indexTableFindsEveryKey() {
    var keys: [[UInt8]] = []
    var table = IndexTable()
    func hash(_ key: [UInt8]) -> UInt64 {
        var hasher = FastHasher()
        hasher.write(bytes: key.span)
        return hasher.finish()
    }
    for i in 0..<20_000 {
        let key = Array("key-\(i)".utf8)
        #expect(table.find(hash(key), { keys[Int($0)] == key }) == nil)
        keys.append(key)
        table.insert(hash(key), UInt32(keys.count - 1))
    }
    #expect(table.count == 20_000)
    for (i, key) in keys.enumerated() {
        #expect(table.find(hash(key), { keys[Int($0)] == key }) == UInt32(i))
    }
    #expect(table.find(hash(Array("missing".utf8)), { keys[Int($0)] == Array("missing".utf8) }) == nil)
    table.removeAll()
    #expect(table.count == 0 && table.find(hash(keys[0]), { _ in true }) == nil)
}

@Test func indexTableSeparatesCollidingKeys() {
    // Every key under the same hash: the caller's comparison tells them apart.
    let keys: [Int64] = Array(0..<100)
    var table = IndexTable()
    for i in keys.indices { table.insert(42, UInt32(i)) }
    for (i, key) in keys.enumerated() {
        #expect(table.find(42, { keys[Int($0)] == key }) == UInt32(i))
    }
}

@Test func hasherSeparatesLengthsAndOrder() {
    func hash(_ bytes: [UInt8]) -> UInt64 {
        var hasher = FastHasher()
        hasher.write(bytes: bytes.span)
        return hasher.finish()
    }
    #expect(hash([0x61]) != hash([0x61, 0]))
    #expect(hash([]) != hash([0]))
    #expect(hash(Array("abcdefgh12".utf8)) == hash(Array("abcdefgh12".utf8)))
    #expect(Int64(1).fastHash != Int64(2).fastHash)
    var ab = FastHasher(), ba = FastHasher()
    ab.write(UInt64(1)); ab.write(UInt64(2))
    ba.write(UInt64(2)); ba.write(UInt64(1))
    #expect(ab.finish() != ba.finish())
}
