// swift-tools-version:6.2
import PackageDescription

// The modules that use x86 instructions plain Swift can't name (SHA-NI, PCLMULQDQ, AVX-512's VPCLMULQDQ) reach them
// through Swift's `Builtin` module and are built with those instructions enabled for themselves alone. The flags are
// picked by the architecture building the package, which is the one running it unless you cross-compile; elsewhere
// those modules are empty and their callers use portable Swift.
// They are always optimized (-O, after SwiftPM's -Onone in a debug build): an instruction's selector must reach LLVM
// as a constant, and only the optimizer folds it into one.
#if arch(x86_64)
let shaFlags = ["-enable-builtin-module", "-Xcc", "-msha", "-Xcc", "-mssse3", "-Xcc", "-msse4.1", "-O"]
let crcFlags = ["-enable-builtin-module", "-Xcc", "-mpclmul", "-Xcc", "-msse4.1", "-O"]
let crc512Flags = ["-enable-builtin-module", "-Xcc", "-mavx512f", "-Xcc", "-mvpclmulqdq", "-Xcc", "-mpclmul", "-O"]
#else
let shaFlags: [String] = []
let crcFlags: [String] = []
let crc512Flags: [String] = []
#endif

let package = Package(
    name: "swift-underlord",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SHA256", targets: ["SHA256"]),
        .library(name: "Gzip", targets: ["Gzip"]),
        .library(name: "CRC32", targets: ["CRC32"]),
        .library(name: "CPUFeatures", targets: ["CPUFeatures"]),
        .library(name: "Bcrypt", targets: ["Bcrypt"]),
        .library(name: "EventLoop", targets: ["EventLoop"]),
        .library(name: "IORing", targets: ["IORing"]),
        .library(name: "Buffers", targets: ["Buffers"]),
        .library(name: "JSON", targets: ["JSON"]),
        .library(name: "HTTP", targets: ["HTTP"]),
        .library(name: "JWT", targets: ["JWT"]),
        .library(name: "FastCollections", targets: ["FastCollections"]),
    ],
    traits: [
        .trait(
            name: "X86Extensions",
            description: "SHA-NI, PCLMULQDQ and AVX-512 VPCLMULQDQ paths on x86-64, through Swift's Builtin module in "
                + "modules built with those instructions enabled. Off: portable Swift only, no unsafe flags used."
        ),
        .default(enabledTraits: ["X86Extensions"]),
    ],
    targets: [
        // What the CPU can do, from CPUID through glibc's x86 feature table (Linux x86-64); nothing elsewhere.
        .target(name: "CPUFeatures", swiftSettings: [.enableExperimentalFeature("Extern")]),
        // SHA-256's compression function on the x86 SHA extensions.
        .target(name: "SHAExtensions", swiftSettings: [.unsafeFlags(shaFlags)]),
        // SHA-256 and HMAC-SHA256, on the SHA extensions where the CPU has them.
        .target(name: "SHA256", dependencies: [
            "CPUFeatures", .target(name: "SHAExtensions", condition: .when(traits: ["X86Extensions"])),
        ]),
        // CRC-32 on PCLMULQDQ, and on AVX-512's VPCLMULQDQ (a module of its own: AVX-512 may be used anywhere in it).
        .target(name: "CRCExtensions", swiftSettings: [.unsafeFlags(crcFlags)]),
        .target(name: "CRCExtensions512", swiftSettings: [.unsafeFlags(crc512Flags)]),
        // CRC-32 (gzip's and zlib's), on the carry-less multiply where the CPU has it.
        .target(name: "CRC32", dependencies: [
            "CPUFeatures",
            .target(name: "CRCExtensions", condition: .when(traits: ["X86Extensions"])),
            .target(name: "CRCExtensions512", condition: .when(traits: ["X86Extensions"])),
        ]),
        // gzip at ISA-L level 0's speed, in Swift.
        .target(name: "Gzip", dependencies: ["CRC32"]),
        // bcrypt, several hashes in lockstep, its key schedule written out per lane count (scripts/ generates it).
        .target(name: "Bcrypt"),
        // An executor for actors on a thread of its own, sleeping in epoll_wait; actors can wait on sockets in it (Linux).
        .target(name: "EventLoop", swiftSettings: [.enableExperimentalFeature("Extern")]),
        // io_uring over its system calls: rings, requests, completions, registered files, provided buffers (Linux).
        .target(name: "IORing", swiftSettings: [.enableExperimentalFeature("Extern")]),
        // Noncopyable buffers that own their memory: bytes, an array of noncopyable elements, a queue.
        .target(name: "Buffers", swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
        // JSON read without building anything, and written 32 bytes at a time.
        .target(name: "JSON", dependencies: ["Buffers"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
        // HTTP/1.1 requests parsed in place (pipelined, chunked, Expect: 100-continue), and response heads.
        .target(name: "HTTP", dependencies: ["Buffers"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
        // HS256 JSON Web Tokens verified in place, and strict base64url.
        .target(name: "JWT", dependencies: ["SHA256", "JSON", "Buffers"],
                swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
        // A hash index into the caller's own array of keys, its multiply hasher, and an unstable sort in place.
        .target(name: "FastCollections"),
        .testTarget(name: "SHA256Tests", dependencies: ["SHA256"]),
        .testTarget(name: "BuffersTests", dependencies: ["Buffers"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON", "Buffers"]),
        .testTarget(name: "HTTPTests", dependencies: ["HTTP", "Buffers"]),
        .testTarget(name: "JWTTests", dependencies: ["JWT", "Buffers"]),
        .testTarget(name: "FastCollectionsTests", dependencies: ["FastCollections"]),
        .testTarget(name: "BcryptTests", dependencies: ["Bcrypt"]),
        .testTarget(name: "GzipTests", dependencies: ["Gzip"]),
        .testTarget(name: "CRC32Tests", dependencies: ["CRC32"]),
        .testTarget(name: "EventLoopTests", dependencies: ["EventLoop"]),
        .testTarget(name: "IORingTests", dependencies: ["IORing"]),
    ]
)
