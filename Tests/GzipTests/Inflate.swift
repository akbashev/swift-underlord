// A small, slow, standalone gunzip (RFC 1952 around RFC 1951, after Mark Adler's puff), so the tests can check every
// output without zlib: stored, fixed and dynamic blocks, then the CRC-32 and length in the trailer.
enum Inflate {
    struct Failure: Error { let reason: String }

    static func gunzip(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8, data[3] == 0 else {
            throw Failure(reason: "not a plain gzip member")
        }
        var r = Reader(data: data, position: 10 * 8)
        var out: [UInt8] = []
        var last = false
        while !last {
            last = try r.bits(1) == 1
            switch try r.bits(2) {
            case 0:
                r.position = (r.position + 7) & ~7
                let length = try r.bits(16)
                guard try r.bits(16) == length ^ 0xFFFF else { throw Failure(reason: "stored length") }
                for _ in 0..<length { out.append(UInt8(try r.bits(8))) }
            case 1:
                let lit = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
                try codes(&r, &out, lit, Huffman(lengths: [Int](repeating: 5, count: 30)))
            case 2:
                let (lit, dist) = try dynamicCodes(&r)
                try codes(&r, &out, lit, dist)
            default:
                throw Failure(reason: "block type 3")
            }
        }
        r.position = (r.position + 7) & ~7
        let crc = try r.bits(32)
        let size = try r.bits(32)
        guard UInt32(crc) == crc32(out) else { throw Failure(reason: "CRC") }
        guard size == out.count & 0xFFFF_FFFF else { throw Failure(reason: "length") }
        return out
    }

    struct Reader {
        let data: [UInt8]
        var position: Int

        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for k in 0..<n {
                guard position / 8 < data.count else { throw Failure(reason: "ran out of input") }
                v |= Int(data[position / 8] >> UInt8(position % 8) & 1) << k
                position += 1
            }
            return v
        }
    }

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            for l in 1..<16 { for (s, length) in lengths.enumerated() where length == l { symbols.append(s) } }
        }

        func decode(_ r: inout Reader) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= try r.bits(1)
                let count = counts[length]
                if code - count < first { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Failure(reason: "no such code")
        }
    }

    static func dynamicCodes(_ r: inout Reader) throws -> (Huffman, Huffman) {
        let literals = try r.bits(5) + 257
        let distances = try r.bits(5) + 1
        let codeLengths = try r.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var cl = [Int](repeating: 0, count: 19)
        for k in 0..<codeLengths { cl[order[k]] = try r.bits(3) }
        let clCode = Huffman(lengths: cl)
        var lengths: [Int] = []
        while lengths.count < literals + distances {
            let s = try clCode.decode(&r)
            switch s {
            case 0..<16: lengths.append(s)
            case 16:
                guard let previous = lengths.last else { throw Failure(reason: "repeat with nothing before") }
                lengths += [Int](repeating: previous, count: 3 + (try r.bits(2)))
            case 17: lengths += [Int](repeating: 0, count: 3 + (try r.bits(3)))
            default: lengths += [Int](repeating: 0, count: 11 + (try r.bits(7)))
            }
        }
        return (Huffman(lengths: Array(lengths[0..<literals])), Huffman(lengths: Array(lengths[literals...])))
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                               3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func codes(_ r: inout Reader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let s = try lit.decode(&r)
            if s < 256 { out.append(UInt8(s)); continue }
            if s == 256 { return }
            guard s - 257 < 29 else { throw Failure(reason: "length symbol") }
            let length = lengthBase[s - 257] + (try r.bits(lengthExtra[s - 257]))
            let d = try dist.decode(&r)
            guard d < 30 else { throw Failure(reason: "distance symbol") }
            let distance = distanceBase[d] + (try r.bits(distanceExtra[d]))
            guard distance <= out.count else { throw Failure(reason: "distance too far back") }
            for _ in 0..<length { out.append(out[out.count - distance]) }
        }
    }

    /// CRC-32 (gzip's), a bit at a time.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
}
