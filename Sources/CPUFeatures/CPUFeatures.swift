// What the CPU can do, for choosing a code path at start-up. On Linux x86-64 it comes from CPUID through glibc's x86
// feature table (<sys/platform/x86.h>, glibc 2.33+), which reports a feature usable only when the CPU has it and the
// kernel lets it be used (AVX-512's registers, for one); nothing outside the process is read. Elsewhere every answer
// is false, and callers take their portable paths.
#if os(Linux) && arch(x86_64)
/// glibc's table: for CPUID leaf `index`, eight words, the four registers as CPUID reported them and then as usable.
@_extern(c, "__x86_get_cpuid_feature_leaf") private func featureLeaf(_ index: UInt32) -> UnsafePointer<UInt32>?
#endif

public enum CPU {
    /// SHA-NI: CPUID leaf 7, EBX bit 29.
    public static var hasSHA: Bool { usable(leaf: 7, register: .ebx, bit: 29) }
    /// PCLMULQDQ and SSE4.1: CPUID leaf 1, ECX bits 1 and 19.
    public static var hasPCLMULQDQ: Bool { usable(leaf: 1, register: .ecx, bit: 1) && usable(leaf: 1, register: .ecx, bit: 19) }
    /// AVX-512F and VPCLMULQDQ (leaf 7, EBX bit 16 and ECX bit 10), on top of PCLMULQDQ.
    public static var hasVPCLMULQDQ512: Bool {
        hasPCLMULQDQ && usable(leaf: 7, register: .ebx, bit: 16) && usable(leaf: 7, register: .ecx, bit: 10)
    }

    public enum Register: Int {
        case eax, ebx, ecx, edx
    }

    /// Whether CPUID leaf `leaf` (1 or 7) reports `bit` of `register` usable.
    public static func usable(leaf: UInt32, register: Register, bit: Int) -> Bool {
        #if os(Linux) && arch(x86_64)
        // glibc's indices: CPUID_INDEX_1 is 0 and CPUID_INDEX_7 is 1; the usable registers are words 4...7.
        let index: UInt32
        switch leaf {
        case 1: index = 0
        case 7: index = 1
        default: return false
        }
        guard let words = featureLeaf(index) else { return false }
        return words[4 + register.rawValue] >> UInt32(bit) & 1 != 0
        #else
        return false
        #endif
    }
}
