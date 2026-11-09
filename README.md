# swift-underlord

Swift *under load*: what I learned making Swift servers fast on Linux, with no C and no dependencies, and the modules
that came out of it.
It comes from building Swift entries for three server benchmarks: many cores against Postgres, a million keep-alive
connections against Postgres, and a single $12 vCPU with SQLite. Every point below was measured, on GitHub's x86
runners as well as locally, and the [docs](docs) have the numbers.

## Findings

**Measuring**

1. **Measure the build you ship.** Microbenchmarks must be built whole-module (`-wmo`), as SwiftPM's release build is;
   non-WMO numbers pointed the wrong way more than once. Then read the disassembly and count the calls into the
   runtime: `swift_retain`/`release`, `swift_isUniquelyReferenced`, `swift_once`, generic standard-library functions.
   [measuring](docs/measuring.md)
2. **Profile per thread, on the target CPU.** Laptop numbers swung ±30%; per-thread `perf` tables on x86 runners are
   what explained the remaining gaps, function by function. [measuring](docs/measuring.md)
3. **Compare with the code that actually runs.** A library's portable C reference is often not what executes on x86.
   [gzip case](docs/case-gzip.md)

**The standard library on hot paths**

4. **`[UInt8]` is a slow growable buffer.** Every `append(contentsOf:)` is a generic, un-inlined call with a
   uniqueness check. A `~Copyable` buffer that owns its memory makes it a capacity check and a `memcpy`.
   [standard library](docs/stdlib.md)
5. **`Dictionary` always hashes with SipHash, and `sort()` calls its comparison through a closure.** An
   open-addressing table with a multiply hash, an in-place sort with the comparison inlined, and sorting on integer
   keys read out first all measured. [standard library](docs/stdlib.md)
6. **Globals cost a check per access.** A file-scope `let` used in a hot loop costs a `swift_once` check each time;
   keep constants local, or in instance storage. [standard library](docs/stdlib.md)
7. **Borrow, don't copy.** `Span`, `RawSpan`, `OutputSpan` and `InlineArray` take copies and allocations out (a
   `Span` can even be lent through an actor call); aim for no allocations per request. [standard library](docs/stdlib.md)

**Concurrency**

8. **One actor per thread, on its own executor.** An epoll + eventfd `SerialExecutor`, a synchronous `main`: no
   global executor, no libdispatch threads. Shared state every thread touches briefly belongs behind a `Mutex`;
   batching hand-offs per tick mattered more than the mechanism. For a one-thread server, MainActor isolation proves
   single-threadedness at compile time. [concurrency](docs/concurrency.md)

**Reaching the hardware without C**

9. **`@_extern(c)`** declares any libc or kernel entry point in Swift: epoll, `syscall(2)` for io_uring (with
   `Atomic` over the mapped rings), even SQLite's internal B-tree functions. [hardware](docs/hardware.md)
10. **`import Builtin`** (the compiler's hidden `-enable-builtin-module`) reaches CPU instructions: SHA-NI,
    PCLMULQDQ, AVX-512 VPCLMULQDQ. Put each in a module of its own built with the feature enabled, behind an
    `@inline(never)` entry, chosen by CPUID and a self-check at start-up. [hardware](docs/hardware.md)

**Flags and traps**

11. **`-Ounchecked` drops a `precondition`'s condition entirely, side effects included.**
    [traps](docs/traps.md)
12. **Build for the machine:** `-target-cpu` from `clang -march=native -###`, and `--static-swift-stdlib` for direct
    calls into the runtime. [traps](docs/traps.md)

**From a server on one CPU**

13. **Link Swift and C together.** SwiftPM's full LTO (native build system, `lld`) inlines C helpers into Swift
    callers; compiling the C differently without it gained nothing. [hardware](docs/hardware.md)
14. **Views over C memory cost nothing.** A `~Escapable` view with `RawSpan` fields and `Span` bytes, borrowed from
    its owner, compiles to the same instructions as raw pointers under `-Ounchecked`. [hardware](docs/hardware.md)
15. **Test layout and SIMD code on x86.** `OutputRawSpan.append(_:as:)` writes an aligned vector store: fine on Apple
    silicon, a crash on x86. [traps](docs/traps.md)
16. **`nonisolated async` hops off the actor** unless it is `nonisolated(nonsending)`; in an executor that made a
    lost wake-up. [concurrency](docs/concurrency.md)
17. **Measure where it fails.** Loopback hides the receiving side's cost, and tails (a checkpoint's write hold) show
    only at saturation. [measuring](docs/measuring.md)

**Above all**

18. **Algorithms and batching beat micro-optimizations.** Group commit, bigger read batches and fuller bcrypt sets
    moved the numbers most; a gzip that compressed better used four times the CPU for bytes that didn't save a packet.
    [gzip case](docs/case-gzip.md)

The lessons are general; the specific numbers in the docs (a 2 ms turn, 64 writes to a group, read windows) were right
for those workloads and are there as examples, not settings to copy.

## Modules

| module | what it is |
|---|---|
| `Gzip` | gzip for in-memory bodies at ISA-L level 0's speed: ISA-L's default Huffman table and its level-0 loop, in Swift. Output about 40% larger than zlib's level 1 at about a sixth of its time: right for HTTP responses, not for archives |
| `CRC32` | CRC-32 as gzip and zlib use it, one-shot or incremental, on PCLMULQDQ or AVX-512 VPCLMULQDQ where the CPU has them (`CRCExtensions`, `CRCExtensions512`) |
| `SHA256` | SHA-256 (one-shot or incremental) and HMAC-SHA256 (pad states precomputed), on SHA-NI where the CPU has it (`SHAExtensions`) |
| `CPUFeatures` | what the CPU can do, from CPUID through glibc, without reading `/proc` |
| `Bcrypt` | bcrypt (`$2b$`): one hash, or several in lockstep so their S-box loads overlap; the lane count is calibrated on first use |
| `EventLoop` | an executor for actors on a thread of its own, sleeping in `epoll_wait`; an actor on it can wait on its sockets in the same call (Linux) |
| `IORing` | io_uring over its system calls: rings, typed requests, completions, registered files, provided buffers (Linux) |
| `Buffers` | noncopyable buffers that own their memory: `ByteBuffer` (appends are a capacity check and a `memcpy`; a whole response written through an `OutputRawSpan` in one reservation), `UniqueArray` of noncopyable elements, `Fifo` |
| `JSON` | JSON read without building anything (the members you name, as places in the bytes) and written 32 bytes at a time |
| `HTTP` | HTTP/1.1 requests parsed in place, pipelined, chunked, `Expect: 100-continue`; response heads |
| `JWT` | HS256 tokens verified in place (signature first, in constant time; `exp`, `nbf`, `iat` against your clock), strict base64url |
| `FastCollections` | a hash index into your own array of keys, a multiply hasher, and an unstable sort in place with the comparison inlined |

Each module declares the system calls it uses itself (`@_extern(c)`), so any one can be copied out alone.

The documentation, with every module's API and these notes, is at
[akbashev.github.io/swift-underlord](https://akbashev.github.io/swift-underlord/) (built by `scripts/build-docs.sh`).

**Installing Swift on a small server.** `scripts/install-swift.sh` installs a release toolchain on Ubuntu 22.04 or
24.04 (x86-64 or arm64): unpacked as it downloads, its signature checked on the way, and without the debugger, editor
and documentation tools, so it needs about 2.6 GB of disk instead of a 4.8 GB peak.

**Using them.** Swift 6.2 or later (tested with 6.4.2), on Linux x86-64 and arm64, and macOS 27. The `X86Extensions`
trait (on by default) builds the x86 paths, whose modules use unsafe flags (`-Xcc -msha` and the like); turn it off for
portable Swift only:

```swift
.package(url: "https://github.com/akbashev/swift-underlord", from: "0.1.0", traits: [])   // portable only
```

`swift test` runs the tests, also with `--disable-default-traits`; the gzip ones check every output with a small
inflater of their own.

## License

MIT. `Sources/Gzip/Gzip.swift` carries a deflate block header from ISA-L 2.31.1 under Intel's BSD license, with its
notice.
