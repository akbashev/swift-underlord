// SHA-256 (FIPS 180-4), one-shot or incremental, and HMAC-SHA256 (RFC 2104). The compression runs on the CPU's SHA extensions where it has them
// (SHAExtensions: x86 SHA-NI through Swift's `Builtin`), chosen once at start: CPUID says they are usable, and they
// hash test messages of every padding case as the portable Swift function here does. Everything works on `Span`s and
// fixed-size `InlineArray`s, so hashing allocates nothing.
import CPUFeatures
#if X86Extensions && arch(x86_64)
import SHAExtensions
#endif

public enum SHA256 {
    public typealias Digest = InlineArray<32, UInt8>
    public typealias State = InlineArray<8, UInt32>

    /// The digest of `data`.
    public static func hash(_ data: Span<UInt8>) -> Digest {
        bytes(hash(from: initialState, priorBytes: 0, data))
    }

    /// Whether the compression runs on the CPU's SHA extensions. Decided once.
    public static let usesExtensions: Bool = {
        #if X86Extensions && arch(x86_64)
        guard CPU.hasSHA else { return false }
        for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 300] {
            let message = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
            let fast = hash(from: initialState, priorBytes: 0, message.span, extensions: true)
            let portable = hash(from: initialState, priorBytes: 0, message.span, extensions: false)
            for i in 0..<8 where fast[i] != portable[i] { return false }
        }
        return true
        #else
        return false
        #endif
    }()

    static let initialState: State = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    private static let roundConstants: InlineArray<64, UInt32> = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }

    @inline(__always) static func compressWords(_ state: inout State, _ words: InlineArray<16, UInt32>) {
        var w = words
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            if i >= 16 {
                let w15 = w[(i + 1) & 15]
                let w2 = w[(i + 14) & 15]
                let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
                let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
                w[i & 15] = w[i & 15] &+ s0 &+ w[(i + 9) & 15] &+ s1
            }
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ roundConstants[i] &+ w[i & 15]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    /// Compresses the 64-byte block at `offset` of `data`.
    @inline(__always) static func compressBlock(_ state: inout State, _ data: RawSpan, at offset: Int = 0) {
        var w = InlineArray<16, UInt32>(repeating: 0)
        for i in 0..<16 { w[i] = data.load(fromByteOffset: offset + 4 * i, as: UInt32.self, .bigEndian) }
        compressWords(&state, w)
    }

    /// Compresses the `blocks` 64-byte blocks of `data`, on the CPU's SHA extensions if `extensions`.
    @inline(__always) static func compress(_ state: inout State, _ data: RawSpan, blocks: Int, extensions: Bool) {
        #if X86Extensions && arch(x86_64)
        if extensions {
            data.withUnsafeBytes { raw in
                withUnsafeMutableBytes(of: &state) {
                    SHAExtensions.compress($0.baseAddress!.assumingMemoryBound(to: UInt32.self), raw.baseAddress!, blocks: blocks)
                }
            }
            return
        }
        #endif
        for i in 0..<blocks { compressBlock(&state, data, at: 64 * i) }
    }

    /// The state after `data`, from `initial` with `priorBytes` already hashed into it, padding included.
    static func hash(from initial: State, priorBytes: UInt64, _ data: Span<UInt8>, extensions: Bool = usesExtensions) -> State {
        var state = initial
        let full = data.count / 64
        if full > 0 { compress(&state, data.bytes, blocks: full, extensions: extensions) }
        // The rest, 0x80, zeros and the length in bits: one block, or two when the rest leaves no room for the length.
        let rem = data.count - 64 * full
        let blocks = rem >= 56 ? 2 : 1
        let totalBits = (priorBytes + UInt64(data.count)) * 8
        var tail = InlineArray<128, UInt8>(repeating: 0)
        for i in 0..<rem { tail[i] = data[64 * full + i] }
        tail[rem] = 0x80
        for i in 0..<8 { tail[64 * blocks - 8 + i] = UInt8(truncatingIfNeeded: totalBits >> (56 - 8 * UInt64(i))) }
        compress(&state, tail.span.bytes, blocks: blocks, extensions: extensions)
        return state
    }

    @inline(__always) static func bytes(_ state: State) -> Digest {
        Digest { i in UInt8(truncatingIfNeeded: state[i >> 2] >> (24 - 8 * UInt32(i & 3))) }
    }
}

extension SHA256 {
    /// SHA-256 of data that arrives in pieces: `update` with each, then `finalize`. Whole blocks are compressed as they
    /// come; at most 63 bytes wait for the next piece.
    public struct Hasher: Sendable {
        private var state = SHA256.initialState
        /// Bytes compressed into `state` so far: whole blocks.
        private var compressed: UInt64 = 0
        private var pending = InlineArray<64, UInt8>(repeating: 0)
        private var pendingCount = 0
        /// `SHA256.usesExtensions`, kept here for the hot path.
        private let extensions = SHA256.usesExtensions

        public init() {}

        public mutating func update(_ data: Span<UInt8>) {
            var start = 0
            if pendingCount > 0 {
                let take = min(64 - pendingCount, data.count)
                for i in 0..<take { pending[pendingCount + i] = data[i] }
                pendingCount += take
                start = take
                guard pendingCount == 64 else { return }
                let block = pending
                SHA256.compress(&state, block.span.bytes, blocks: 1, extensions: extensions)
                compressed += 64
                pendingCount = 0
            }
            let full = (data.count - start) / 64
            if full > 0 {
                SHA256.compress(&state, data.extracting(start..<start + 64 * full).bytes, blocks: full, extensions: extensions)
                compressed += UInt64(64 * full)
                start += 64 * full
            }
            for i in start..<data.count {
                pending[pendingCount] = data[i]
                pendingCount += 1
            }
        }

        /// The digest of everything passed to `update`.
        public consuming func finalize() -> Digest {
            let rest = pending
            return SHA256.bytes(SHA256.hash(from: state, priorBytes: compressed, rest.span.extracting(0..<pendingCount),
                                            extensions: extensions))
        }
    }
}

/// HMAC-SHA256 with the key's inner and outer pad states computed once: each tag costs the message's blocks plus one.
public struct HMACSHA256: Sendable {
    private var innerState: SHA256.State
    private var outerState: SHA256.State
    /// `SHA256.usesExtensions`, kept here for the hot path.
    private let extensions = SHA256.usesExtensions

    public init(key: Span<UInt8>) {
        var block = InlineArray<64, UInt8>(repeating: 0)
        if key.count > 64 {
            let hashed = SHA256.hash(key)
            for i in 0..<32 { block[i] = hashed[i] }
        } else {
            for i in 0..<key.count { block[i] = key[i] }
        }
        let ipad = InlineArray<64, UInt8> { 0x36 ^ block[$0] }
        let opad = InlineArray<64, UInt8> { 0x5C ^ block[$0] }
        innerState = SHA256.initialState
        outerState = SHA256.initialState
        SHA256.compressBlock(&innerState, ipad.span.bytes)
        SHA256.compressBlock(&outerState, opad.span.bytes)
    }

    /// The tag of `data`.
    public func authenticate(_ data: Span<UInt8>) -> SHA256.Digest {
        let inner = SHA256.hash(from: innerState, priorBytes: 64, data, extensions: extensions)
        var outer = outerState
        if extensions {
            // The outer block as bytes: the inner digest, 0x80, and the length (64 + 32 bytes, 768 bits).
            var block = InlineArray<64, UInt8>(repeating: 0)
            let digest = SHA256.bytes(inner)
            for i in 0..<32 { block[i] = digest[i] }
            block[32] = 0x80
            block[62] = 0x03
            SHA256.compress(&outer, block.span.bytes, blocks: 1, extensions: true)
        } else {
            let words: InlineArray<16, UInt32> = [
                inner[0], inner[1], inner[2], inner[3], inner[4], inner[5], inner[6], inner[7],
                0x8000_0000, 0, 0, 0, 0, 0, 0, 768,
            ]
            SHA256.compressWords(&outer, words)
        }
        return SHA256.bytes(outer)
    }
}
