// The standard check value, a bitwise reference at every length up to 9 KB (and offsets that misalign the folds), and
// updates split anywhere giving the same CRC.
@testable import CRC32
import Testing

private func reference(_ bytes: some Collection<UInt8>) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        c ^= UInt32(b)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
    return ~c
}

@Test func checkValue() {
    #expect(CRC32.checksum(Array("123456789".utf8).span) == 0xCBF4_3926)
    #expect(CRC32.checksum([UInt8]().span) == 0)
}

@Test func everyLengthAndOffset() {
    var rng = SystemRandomNumberGenerator()
    let data = (0..<9300).map { _ in UInt8.random(in: 0...255, using: &rng) }
    for offset in [0, 1, 7, 15] {
        for n in Array(0...300) + Array(stride(from: 301, through: 9200, by: 37)) {
            let slice = data[offset..<(offset + n)]
            #expect(slice.withUnsafeBytes { raw in var c = CRC32(); c.update(raw); return c.value } == reference(slice),
                    "offset \(offset), length \(n), on \(CRC32.instructions)")
        }
    }
}

@Test func splitUpdates() {
    let data = (0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 3) }
    let whole = CRC32.checksum(data.span)
    for cut in [1, 15, 16, 127, 128, 255, 256, 1000, 4999] {
        let head = Array(data[..<cut])
        let tail = Array(data[cut...])
        var c = CRC32()
        c.update(head.span)
        c.update(tail.span)
        #expect(c.value == whole, "split at \(cut)")
    }
}

@Test func instructionsAreNamed() {
    print("CRC32 runs on \(CRC32.instructions)")
    #expect(["tables", "PCLMULQDQ", "VPCLMULQDQ"].contains(CRC32.instructions))
}
