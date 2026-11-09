// Every output decompressed by the test's own inflater (CRC and length checked), on feed-like JSON and on inputs that
// stress the matcher and the CRC folds' boundaries.
import Gzip
import Testing

private func roundTrip(_ input: [UInt8], _ gzip: inout Gzip) throws -> Int {
    var out = [UInt8](repeating: 0, count: Gzip.bound(input.count))
    let n = input.withUnsafeBytes { src in out.withUnsafeMutableBytes { gzip.compress(src, into: $0) } }
    #expect(try Inflate.gunzip(Array(out[0..<n])) == input)
    return n
}

/// A feed like the ones the server sends: 20 posts of short bodies, as JSON.
private func feed(_ seed: Int) -> [UInt8] {
    var rng = seed
    func next() -> Int {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(UInt(bitPattern: rng) >> 33)
    }
    var s = "{\"posts\":["
    for k in 0..<20 {
        let name = "user\(next() % 50_000)"
        let stamp = "2026-11-09T07:\(10 + next() % 50):\(10 + next() % 50).\(100 + next() % 900)Z"
        if k > 0 { s += "," }
        s += "{\"id\":\(20_000_000 + seed * 20 + k),\"body\":\"\(name) says hi at \(stamp) (VU \(next() % 1_400_000), iter \(next() % 40))\","
        s += "\"created_at\":\"\(stamp)\",\"author\":\"\(name)\",\"like_count\":\(next() % 3)}"
    }
    return Array((s + "]}").utf8)
}

@Test func feeds() throws {
    var gzip = Gzip()
    var total = 0, compressed = 0
    for seed in 0..<200 {
        let f = feed(seed)
        total += f.count
        compressed += try roundTrip(f, &gzip)
    }
    #expect(compressed * 2 < total)
}

@Test func edgeCases() throws {
    var gzip = Gzip()
    var rng = SystemRandomNumberGenerator()
    var inputs: [[UInt8]] = [[0x78], [0x61, 0x62], Array(0...255), Array(repeating: 0, count: 70_000),
                             Array("é中😀 ".utf8) + Array(repeating: 0x20, count: 3), Array(repeating: 0x61, count: 1_000)]
    for n in [1, 3, 4, 8, 9, 15, 16, 17, 63, 64, 65, 127, 128, 129, 255, 256, 257, 271, 272, 511, 512, 4103] {
        inputs.append((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
        inputs.append(Array(Array("abcabcabd".utf8).prefix(n)) + (0..<max(0, n - 9)).map { UInt8(truncatingIfNeeded: $0 % 7 + 97) })
    }
    for n in [257, 258, 259, 260, 1000, 33_000, 70_000] {
        inputs.append(Array(String(repeating: "abc", count: 30_000).utf8.prefix(n)))
    }
    for input in inputs { _ = try roundTrip(input, &gzip) }
}

