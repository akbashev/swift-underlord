// CRC-32 as gzip, zlib and PNG use it (bit-reflected, polynomial 0xEDB88320). Whole 16-byte blocks run on the CPU's
// carry-less multiply where it has one: 256 bytes per step with AVX-512's VPCLMULQDQ (CRCExtensions512), 128 with
// PCLMULQDQ (CRCExtensions); the rest, and every byte elsewhere, eight bytes per step from tables. The path is chosen
// once: CPUID says the instructions are usable, and they agree with the tables on test data that takes every part of
// their fold.
import CPUFeatures
#if X86Extensions && arch(x86_64)
import CRCExtensions
import CRCExtensions512
#endif

public struct CRC32: Sendable {
    /// The register (not complemented).
    private var register: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// The CRC of all the bytes passed to `update` so far.
    public var value: UInt32 { ~register }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let p = bytes.baseAddress, bytes.count > 0 else { return }
        register = Self.update(register, p.assumingMemoryBound(to: UInt8.self), bytes.count, Self.path)
    }

    public mutating func update(_ bytes: Span<UInt8>) {
        bytes.withUnsafeBytes { update($0) }
    }

    /// The CRC of `bytes`.
    public static func checksum(_ bytes: Span<UInt8>) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    /// The instructions the CRC runs on: "VPCLMULQDQ", "PCLMULQDQ" or "tables".
    public static var instructions: String {
        switch path {
        case .tables: "tables"
        case .carryless: "PCLMULQDQ"
        case .carryless512: "VPCLMULQDQ"
        }
    }

    enum Path: Sendable {
        case tables, carryless, carryless512
    }

    static let path: Path = {
        #if X86Extensions && arch(x86_64)
        let sample = (0..<4103).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 >> 5) }
        var chosen = Path.tables
        for (candidate, usable) in [(Path.carryless, CPU.hasPCLMULQDQ), (Path.carryless512, CPU.hasVPCLMULQDQ512)] where usable {
            let agrees = sample.withUnsafeBufferPointer { p in
                [128, 144, 256, 272, 1000, 4103].allSatisfy { n in
                    update(0xFFFF_FFFF, p.baseAddress!, n, candidate) == update(0xFFFF_FFFF, p.baseAddress!, n, .tables)
                }
            }
            guard agrees else { break }
            chosen = candidate
        }
        return chosen
        #else
        return .tables
        #endif
    }()

    /// Eight 256-entry tables: the CRC of a byte, then of a byte followed by one to seven zero bytes.
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[n] = c
        }
        for n in 0..<256 {
            var c = t[n]
            for k in 1..<8 {
                c = t[Int(c & 0xFF)] ^ (c >> 8)
                t[k * 256 + n] = c
            }
        }
        return t
    }()

    /// The register after `n` bytes at `p`, starting from `crc`, on `path`.
    static func update(_ crc: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int, _ path: Path) -> UInt32 {
        var c = crc
        var i = 0
        #if X86Extensions && arch(x86_64)
        if path == .carryless512 && n >= 256 {
            i = n & ~15
            c = crc32Fold512(c, p, count: i)
        } else if path != .tables && n >= 128 {
            i = n & ~15
            c = crc32Fold(c, p, count: i)
        }
        #endif
        return tables.withUnsafeBufferPointer { t in
            while i + 8 <= n {
                let lo = UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self).littleEndian ^ c
                let hi = UnsafeRawPointer(p + i + 4).loadUnaligned(as: UInt32.self).littleEndian
                c = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                    ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)]
                    ^ t[1 * 256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
                i += 8
            }
            while i < n {
                c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
            return c
        }
    }
}
