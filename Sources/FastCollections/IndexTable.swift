// A hash index for keys kept in the caller's own array, and the hasher it is built for. Swift's `Dictionary` always
// hashes with SipHash, which guards against flooding with chosen keys and costs a few rounds per word; a server's
// per-batch key sets don't need that guard, and one multiply per word does.

/// A multiply-xor hasher in the style of FxHash (rustc-hash): each word xor-ed into the state and multiplied by the
/// golden ratio's 64-bit constant, then SplitMix64's finisher (Steele, Lea and Flood, 2014) mixes the high bits down,
/// since the table indexes by the low ones. Not for keys an attacker chooses.
public struct FastHasher: Sendable {
    @usableFromInline var state: UInt64 = 0x517C_C1B7_2722_0A95

    @inlinable public init() {}

    @inlinable @inline(__always) public mutating func write(_ value: UInt64) {
        state = (state ^ value) &* 0x9E37_79B9_7F4A_7C15
    }

    @inlinable @inline(__always) public mutating func write(_ value: Int64) {
        write(UInt64(bitPattern: value))
    }

    /// `bytes` eight at a time, the last word zero-padded, after their count (so "a" and "a\0" differ).
    @inlinable @inline(__always) public mutating func write(bytes: Span<UInt8>) {
        write(UInt64(bytes.count))
        let raw = bytes.bytes
        let n = raw.byteCount
        var i = 0
        while i + 8 <= n {
            write(UInt64(littleEndian: raw.unsafeLoadUnaligned(fromByteOffset: i, as: UInt64.self)))
            i += 8
        }
        if i < n {
            var tail: UInt64 = 0
            for k in 0..<(n - i) { tail |= UInt64(bytes[i + k]) << (8 * k) }
            write(tail)
        }
    }

    @inlinable @inline(__always) public func finish() -> UInt64 {
        var x = state &* 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        return x ^ (x >> 27)
    }
}

/// A key `FastHasher` can hash: it writes its fields to the hasher.
public protocol FastHashable: Equatable {
    func feed(_ hasher: inout FastHasher)
}

extension FastHashable {
    @inlinable @inline(__always) public var fastHash: UInt64 {
        var hasher = FastHasher()
        feed(&hasher)
        return hasher.finish()
    }
}

extension Int64: FastHashable {
    @inlinable @inline(__always) public func feed(_ hasher: inout FastHasher) { hasher.write(self) }
}

extension UInt64: FastHashable {
    @inlinable @inline(__always) public func feed(_ hasher: inout FastHasher) { hasher.write(self) }
}

extension Int: FastHashable {
    @inlinable @inline(__always) public func feed(_ hasher: inout FastHasher) { hasher.write(Int64(self)) }
}

/// From a key's hash to its ordinal in an array of keys the caller keeps: a set or map without a second copy of the
/// keys. Linear probing over a power-of-two table at most half full; a slot holds the hash's low half and the ordinal
/// plus one (0 is a free slot), so a probe asks the caller to compare keys only when the hashes' halves agree.
///
/// ```swift
/// var keys: [Int64] = []
/// var index = IndexTable()
/// func ordinal(of key: Int64) -> UInt32 {
///     let hash = key.fastHash
///     if let found = index.find(hash, { keys[Int($0)] == key }) { return found }
///     keys.append(key)
///     index.insert(hash, UInt32(keys.count - 1))
///     return UInt32(keys.count - 1)
/// }
/// ```
public struct IndexTable: Sendable {
    @usableFromInline var slots: [UInt64] = []
    @usableFromInline var _count = 0

    /// How many ordinals the table holds.
    @inlinable public var count: Int { _count }

    @inlinable public init() {}

    /// The ordinal stored under `hash` whose key `isKey` accepts; nil if none is.
    @inlinable @inline(__always) public func find(_ hash: UInt64, _ isKey: (UInt32) -> Bool) -> UInt32? {
        if _count == 0 { return nil }
        let mask = slots.count - 1
        let tag = hash & 0xFFFF_FFFF
        var i = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slots[i]
            if slot == 0 { return nil }
            if slot >> 32 == tag {
                let ordinal = UInt32(truncatingIfNeeded: slot) &- 1
                if isKey(ordinal) { return ordinal }
            }
            i = (i &+ 1) & mask
        }
    }

    /// Adds `ordinal` (below `UInt32.max`), not in the table yet, under `hash`.
    @inlinable @inline(__always) public mutating func insert(_ hash: UInt64, _ ordinal: UInt32) {
        precondition(ordinal < UInt32.max, "IndexTable: ordinal out of range")
        if (_count + 1) * 2 > slots.count { grow() }
        place((hash & 0xFFFF_FFFF) << 32 | UInt64(ordinal &+ 1))
        _count += 1
    }

    @inlinable @inline(__always) mutating func place(_ entry: UInt64) {
        let mask = slots.count - 1
        var i = Int(truncatingIfNeeded: entry >> 32) & mask
        while slots[i] != 0 { i = (i &+ 1) & mask }
        slots[i] = entry
    }

    @usableFromInline @inline(never) mutating func grow() {
        let old = slots
        slots = [UInt64](repeating: 0, count: Swift.max(16, old.count * 2))
        for slot in old where slot != 0 { place(slot) }
    }

    /// Empties the table, keeping its memory.
    public mutating func removeAll() {
        guard _count > 0 else { return }
        slots.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        _count = 0
    }
}
