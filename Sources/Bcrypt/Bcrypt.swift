// bcrypt (Provos and Mazières, "A Future-Adaptable Password Scheme", 1999) as OpenBSD defines it: `$2b$` hashes,
// `$2a$` and `$2y$` read too, passwords up to 72 bytes. Several hashes can run in lockstep, one round of each lane after
// another, so their S-box loads overlap: verifying several logins at once costs less per login than one at a time.
// The key schedule's inner loop is written out per lane count (BcryptKernels.swift, generated), so the compiler has
// only registers left to choose; a calibration on first use picks the lane count and kernel family that are fastest
// per hash on this CPU.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Bcrypt {
    public typealias Salt = InlineArray<16, UInt8>

    /// 16 random bytes.
    public static func makeSalt() -> Salt {
        var rng = SystemRandomNumberGenerator()
        return Salt { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    /// The `$2b$` hash of `password` (its first 72 bytes) at `cost` (4...31): 60 bytes of ASCII.
    public static func hash(_ password: Span<UInt8>, cost: Int = 10, salt: Salt = makeSalt()) -> [UInt8] {
        precondition((4...31).contains(cost), "bcrypt's cost is 4...31")
        let lane = InlineArray<1, KeyMaterial>(repeating: KeyMaterial(password: password, salt: salt))
        return format(cost: cost, salt: salt, digest: hashLanes(lane, cost: cost, kernel: calibration.kernel)[0])
    }

    /// Whether `password` hashes to `encoded` (a `$2a$`, `$2b$` or `$2y$` hash); compared in constant time.
    public static func verify(_ password: Span<UInt8>, _ encoded: Span<UInt8>) -> Bool {
        guard let parsed = parse(encoded) else { return false }
        let lane = InlineArray<1, KeyMaterial>(repeating: KeyMaterial(password: password, salt: parsed.salt))
        return digestsEqual(hashLanes(lane, cost: parsed.cost, kernel: calibration.kernel)[0], parsed.digest)
    }

    /// `passwords` hashed at `cost`, `calibration.lanes` at a time in lockstep, each with a new salt.
    public static func hash(_ passwords: [[UInt8]], cost: Int = 10) -> [[UInt8]] {
        precondition((4...31).contains(cost), "bcrypt's cost is 4...31")
        let salts = passwords.map { _ in makeSalt() }
        let mats = passwords.indices.map { i in
            let password = passwords[i]
            return KeyMaterial(password: password.span, salt: salts[i])
        }
        let digests = lockstep(mats, cost: cost)
        return passwords.indices.map { format(cost: cost, salt: salts[$0], digest: digests[$0]) }
    }

    /// Whether each password hashes to its encoded hash; hashes of one cost run `calibration.lanes` at a time in
    /// lockstep. A hash that doesn't parse is `false`.
    public static func verify(_ pairs: [(password: [UInt8], encoded: [UInt8])]) -> [Bool] {
        var result = [Bool](repeating: false, count: pairs.count)
        let parsed = pairs.map { parse($0.encoded.span) }
        for cost in Set(parsed.compactMap { $0?.cost }) {
            let members = pairs.indices.filter { parsed[$0]?.cost == cost }
            let mats = members.map { i in
                let password = pairs[i].password
                return KeyMaterial(password: password.span, salt: parsed[i]!.salt)
            }
            let digests = lockstep(mats, cost: cost)
            for (k, i) in members.enumerated() { result[i] = digestsEqual(digests[k], parsed[i]!.digest) }
        }
        return result
    }

    /// What the calibration chose on this CPU, measured on first use (a few hundred milliseconds).
    public struct Calibration: Sendable {
        /// How many hashes run in lockstep.
        public let lanes: Int
        /// The kernel family: "constant", or "shrx" (x86-64).
        public let kernelName: String
        /// Microseconds per cost-10 hash when `lanes` run together.
        public let microsecondsPerHash: Int
        let kernel: Kernel
    }

    public static let calibration: Calibration = calibrate()

    /// The digests of `mats` at `cost`, in groups of the calibrated width.
    static func lockstep(_ mats: [KeyMaterial], cost: Int) -> [Digest] {
        var out: [Digest] = []
        out.reserveCapacity(mats.count)
        let kernel = calibration.kernel
        var i = 0
        func run<let n: Int>(_: InlineArray<n, KeyMaterial>.Type) {
            let digests = hashLanes(InlineArray<n, KeyMaterial> { mats[i + $0] }, cost: cost, kernel: kernel)
            for k in 0..<n { out.append(digests[k]) }
            i += n
        }
        while i < mats.count {
            switch min(calibration.lanes, mats.count - i) {
            case 1: run(InlineArray<1, KeyMaterial>.self)
            case 2: run(InlineArray<2, KeyMaterial>.self)
            case 3: run(InlineArray<3, KeyMaterial>.self)
            case 4: run(InlineArray<4, KeyMaterial>.self)
            case 5: run(InlineArray<5, KeyMaterial>.self)
            default: run(InlineArray<6, KeyMaterial>.self)
            }
        }
        return out
    }

    /// One Blowfish state, the P-array and the four S-boxes (box b's entry i at s[256 * b + i]), 4,168 bytes.
    struct State: BitwiseCopyable {
        var p: InlineArray<18, UInt32>
        var s: InlineArray<1024, UInt32>

        static let initial = State(p: initialP, s: initialS)
    }

    typealias Digest = InlineArray<23, UInt8>

    /// F of lane `k`'s state, its S-boxes read in place: passing `st[k].s` as an argument would copy all 4 KB of them
    /// on every call (a `borrowing` parameter of a copyable value read through a subscript is still a copy).
    @inline(__always) private static func feistel<let n: Int>(_ st: borrowing InlineArray<n, State>, _ k: Int, _ x: UInt32) -> UInt32 {
        let a = st[k].s[Int(x >> 24)]
        let b = st[k].s[256 + Int(x >> 16 & 0xFF)]
        let c = st[k].s[512 + Int(x >> 8 & 0xFF)]
        let d = st[k].s[768 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    /// 16-round Blowfish in each of `n` states, interleaved round by round so their S-box loads overlap.
    @inline(__always) private static func encipherLanes<let n: Int>(_ st: borrowing InlineArray<n, State>,
                                                                    _ l: inout InlineArray<n, UInt32>, _ r: inout InlineArray<n, UInt32>) {
        for pair in 0..<8 {
            for k in 0..<n {
                l[k] ^= st[k].p[2 * pair]
                r[k] ^= feistel(st, k, l[k])
            }
            for k in 0..<n {
                r[k] ^= st[k].p[2 * pair + 1]
                l[k] ^= feistel(st, k, r[k])
            }
        }
        for k in 0..<n {
            let nl = r[k] ^ st[k].p[17]
            let nr = l[k] ^ st[k].p[16]
            l[k] = nl
            r[k] = nr
        }
    }

    /// The 32-bit words a key (the password and its NUL) and a salt contribute.
    struct KeyMaterial: BitwiseCopyable {
        var keyP: InlineArray<18, UInt32>
        var salt4: InlineArray<4, UInt32>
        var salt18: InlineArray<18, UInt32>

        init(password: Span<UInt8>, salt: Salt) {
            // The key is the password (at most 72 bytes) and its NUL, cycled through 18 words.
            let length = min(password.count, 72) + 1
            keyP = InlineArray(repeating: 0)
            var cursor = 0
            for i in 0..<18 {
                var w: UInt32 = 0
                for _ in 0..<4 {
                    if cursor >= length { cursor = 0 }
                    w = w << 8 | UInt32(cursor < length - 1 ? password[cursor] : 0)
                    cursor += 1
                }
                keyP[i] = w
            }
            salt4 = InlineArray(repeating: 0)
            for i in 0..<4 {
                salt4[i] = UInt32(salt[4 * i]) << 24 | UInt32(salt[4 * i + 1]) << 16 | UInt32(salt[4 * i + 2]) << 8 | UInt32(salt[4 * i + 3])
            }
            salt18 = InlineArray(repeating: 0)
            for i in 0..<18 { salt18[i] = salt4[i & 3] }
        }
    }

    @inline(__always) private static func eksExpand<let n: Int>(_ st: inout InlineArray<n, State>, _ mats: borrowing InlineArray<n, KeyMaterial>,
                                                                withSalt: Bool, saltAsKey: Bool) {
        for k in 0..<n {
            for i in 0..<18 { st[k].p[i] ^= saltAsKey ? mats[k].salt18[i] : mats[k].keyP[i] }
        }
        var l = InlineArray<n, UInt32>(repeating: 0)
        var r = InlineArray<n, UInt32>(repeating: 0)
        var sIdx = 0
        for i in 0..<9 {
            if withSalt {
                for k in 0..<n {
                    l[k] ^= mats[k].salt4[sIdx & 3]
                    r[k] ^= mats[k].salt4[(sIdx + 1) & 3]
                }
                sIdx += 2
            }
            encipherLanes(st, &l, &r)
            for k in 0..<n {
                st[k].p[2 * i] = l[k]
                st[k].p[2 * i + 1] = r[k]
            }
        }
        for pair in 0..<512 {
            if withSalt {
                for k in 0..<n {
                    l[k] ^= mats[k].salt4[sIdx & 3]
                    r[k] ^= mats[k].salt4[(sIdx + 1) & 3]
                }
                sIdx += 2
            }
            encipherLanes(st, &l, &r)
            for k in 0..<n {
                st[k].s[2 * pair] = l[k]
                st[k].s[2 * pair + 1] = r[k]
            }
        }
    }

    /// Which family of the generated key-only expansion kernels runs (BcryptKernels.swift); calibration picks the
    /// faster on this CPU.
    enum Kernel: Sendable, CustomStringConvertible {
        /// Bytes extracted with constant shifts: the compiler picks the instructions (BMI1's bextr on AMD, ubfx on arm64).
        case constant
        #if arch(x86_64)
        /// The shifts by 24 and 16 take their count from a register: BMI2's shrx, which keeps its input, so no copy
        /// before each shift (faster on Intel). Slower without BMI2; x86-64 only, since elsewhere there
        /// is no copy to save (arm64's ubfx extracts a constant field in one instruction).
        case shrx
        #endif

        /// Every family this architecture has.
        static var all: [Kernel] {
            #if arch(x86_64)
            [.constant, .shrx]
            #else
            [.constant]
            #endif
        }

        init?(name: String) {
            guard let kernel = Self.all.first(where: { $0.description == name }) else { return nil }
            self = kernel
        }

        var description: String {
            switch self {
            case .constant: "constant"
            #if arch(x86_64)
            case .shrx: "shrx"
            #endif
            }
        }
    }

    /// `n` bcrypt digests at one cost, in lockstep. Every lane runs all 2^cost rounds.
    static func hashLanes<let n: Int>(_ mats: borrowing InlineArray<n, KeyMaterial>, cost: Int,
                                      kernel: Kernel) -> InlineArray<n, Digest> {
        var st = InlineArray<n, State>(repeating: .initial)
        eksExpand(&st, mats, withSalt: true, saltAsKey: false)
        // The cost loop: the key and then the salt XORed into P, each followed by a key-only expansion, the kernel
        // written out for n lanes (BcryptKernels.swift); one loop, so it is inlined once.
        for half in 0..<(2 << cost) {
            let saltAsKey = half & 1 == 1
            for k in 0..<n {
                for i in 0..<18 { st[k].p[i] ^= saltAsKey ? mats[k].salt18[i] : mats[k].keyP[i] }
            }
            expand0(&st, kernel)
        }
        let magic: InlineArray<6, UInt32> = [0x4f72_7068, 0x6561_6e42, 0x6568_6f6c, 0x6465_7253, 0x6372_7944, 0x6f75_6274]
        var ctext = InlineArray<n, InlineArray<6, UInt32>>(repeating: magic)
        for _ in 0..<64 {
            for blk in 0..<3 {
                var l = InlineArray<n, UInt32> { ctext[$0][2 * blk] }
                var r = InlineArray<n, UInt32> { ctext[$0][2 * blk + 1] }
                encipherLanes(st, &l, &r)
                for k in 0..<n {
                    ctext[k][2 * blk] = l[k]
                    ctext[k][2 * blk + 1] = r[k]
                }
            }
        }
        return InlineArray<n, Digest> { k in
            Digest { i in UInt8(truncatingIfNeeded: ctext[k][i >> 2] >> (24 - 8 * UInt32(i & 3))) }
        }
    }

    /// The L1 data cache in KB (32 if unknown): sysconf on Linux (glibc reads it from CPUID), sysctl on Darwin.
    static func l1DataCacheKB() -> Int {
        #if canImport(Glibc)
        let bytes = sysconf(Int32(_SC_LEVEL1_DCACHE_SIZE))
        return bytes >= 16 * 1024 && bytes <= 512 * 1024 ? bytes / 1024 : 32
        #elseif canImport(Darwin)
        var bytes = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname("hw.l1dcachesize", &bytes, &size, nil, 0) == 0 else { return 32 }
        return bytes >= 16 * 1024 && bytes <= 512 * 1024 ? bytes / 1024 : 32
        #else
        return 32
        #endif
    }

    private typealias Probe = (lanes: Int, kernel: Kernel, us10: Int, perHash: Int)

    /// The cost the probes run at: 7, scaled to 10 (4 in a debug build, whose unoptimized hashing is far slower).
    #if DEBUG
    private static let probeCost = 4
    #else
    private static let probeCost = 7
    #endif

    /// `n` lanes with `kernel` at `probeCost`, the faster of two runs, scaled to cost 10.
    private static func probe<let n: Int>(_: InlineArray<n, KeyMaterial>.Type, _ kernel: Kernel) -> Probe {
        let pw = Array("calibrate-benchmark-pw".utf8)
        let mats = InlineArray<n, KeyMaterial> { k in
            KeyMaterial(password: pw.span, salt: Salt(repeating: UInt8(truncatingIfNeeded: k &* 17 &+ 3)))
        }
        let clock = ContinuousClock()
        var us = Int.max
        for _ in 0..<2 {
            let start = clock.now
            let digests = hashLanes(mats, cost: probeCost, kernel: kernel)
            let elapsed = (clock.now - start).components
            us = min(us, Int(elapsed.seconds) * 1_000_000 + Int(elapsed.attoseconds / 1_000_000_000_000))
            withExtendedLifetime(digests) {}
        }
        let us10 = max(us << (10 - probeCost), 1000)
        return (n, kernel, us10, us10 / n)
    }

    /// Times every kernel family at 2 to 6 lanes and keeps the fastest per hash whose states fit the L1 data cache.
    static func calibrate() -> Calibration {
        let l1d = l1DataCacheKB()
        let warm = InlineArray<1, KeyMaterial>(repeating: KeyMaterial(password: Array("calibrate-warmup".utf8).span, salt: Salt(repeating: 0x5A)))
        for kernel in Kernel.all { withExtendedLifetime(hashLanes(warm, cost: 5, kernel: kernel)) {} }
        var candidates: [Probe] = []
        for kernel in Kernel.all {
            candidates += [probe(InlineArray<2, KeyMaterial>.self, kernel), probe(InlineArray<3, KeyMaterial>.self, kernel),
                           probe(InlineArray<4, KeyMaterial>.self, kernel), probe(InlineArray<5, KeyMaterial>.self, kernel),
                           probe(InlineArray<6, KeyMaterial>.self, kernel)]
        }
        var best = candidates[0]
        for cand in candidates.dropFirst() {
            let stateKB = cand.lanes * MemoryLayout<State>.size / 1024
            if stateKB <= l1d && cand.perHash * 103 < best.perHash * 100 { best = cand }
        }
        return Calibration(lanes: best.lanes, kernelName: best.kernel.description, microsecondsPerHash: best.perHash, kernel: best.kernel)
    }

    private static let alphabet: StaticString = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    @inline(__always) private static func alphabetValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x2E, 0x2F: c - 0x2E
        case 0x41...0x5A: c - 0x41 + 2
        case 0x61...0x7A: c - 0x61 + 28
        case 0x30...0x39: c - 0x30 + 54
        default: nil
        }
    }

    private static func encode64(_ src: Span<UInt8>, into dst: inout [UInt8]) {
        let enc = alphabet.utf8Start
        var i = 0
        while i < src.count {
            let b0 = src[i]
            i += 1
            dst.append(enc[Int(b0 >> 2)])
            var v = (b0 & 0x03) << 4
            guard i < src.count else {
                dst.append(enc[Int(v)])
                break
            }
            let b1 = src[i]
            i += 1
            v |= b1 >> 4
            dst.append(enc[Int(v)])
            v = (b1 & 0x0F) << 2
            guard i < src.count else {
                dst.append(enc[Int(v)])
                break
            }
            let b2 = src[i]
            i += 1
            v |= b2 >> 6
            dst.append(enc[Int(v)])
            dst.append(enc[Int(b2 & 0x3F)])
        }
    }

    /// `count` bytes of bcrypt's base64, generic over the output's size.
    private static func decode64<let count: Int>(_ src: Span<UInt8>) -> InlineArray<count, UInt8>? {
        var out = InlineArray<count, UInt8>(repeating: 0)
        var o = 0
        var i = 0
        while o < count {
            guard i + 1 < src.count, let c1 = alphabetValue(src[i]), let c2 = alphabetValue(src[i + 1]) else { return nil }
            out[o] = c1 << 2 | (c2 & 0x30) >> 4
            o += 1
            if o >= count { break }
            guard i + 2 < src.count, let c3 = alphabetValue(src[i + 2]) else { return nil }
            out[o] = (c2 & 0x0F) << 4 | (c3 & 0x3C) >> 2
            o += 1
            if o >= count { break }
            guard i + 3 < src.count, let c4 = alphabetValue(src[i + 3]) else { return nil }
            out[o] = (c3 & 0x03) << 6 | c4
            o += 1
            i += 4
        }
        return out
    }

    struct Parsed {
        let cost: Int
        let salt: Salt
        let digest: Digest
    }

    static func parse(_ encoded: Span<UInt8>) -> Parsed? {
        guard encoded.count == 60, encoded[0] == 0x24, encoded[1] == 0x32, encoded[3] == 0x24, encoded[6] == 0x24,
              encoded[2] == 0x61 || encoded[2] == 0x62 || encoded[2] == 0x79,
              (0x30...0x39).contains(encoded[4]), (0x30...0x39).contains(encoded[5]) else { return nil }
        let cost = Int(encoded[4] - 0x30) * 10 + Int(encoded[5] - 0x30)
        guard (4...31).contains(cost),
              let salt = decode64(encoded.extracting(7..<29)) as Salt?,
              let digest = decode64(encoded.extracting(29..<60)) as Digest? else { return nil }
        return Parsed(cost: cost, salt: salt, digest: digest)
    }

    static func format(cost: Int, salt: Salt, digest: Digest) -> [UInt8] {
        var out: [UInt8] = [0x24, 0x32, 0x62, 0x24, 0x30 + UInt8(cost / 10), 0x30 + UInt8(cost % 10), 0x24]
        out.reserveCapacity(60)
        encode64(salt.span, into: &out)
        encode64(digest.span, into: &out)
        return out
    }

    @inline(__always) static func digestsEqual(_ a: Digest, _ b: Digest) -> Bool {
        var diff: UInt8 = 0
        for i in 0..<23 { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
