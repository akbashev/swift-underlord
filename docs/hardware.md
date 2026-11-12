# Reaching the hardware without C

## Functions: @_extern(c)

Glibc's Swift module leaves out a lot (epoll, eventfd, `accept4`, `unshare`, `getrandom`). Declare them in Swift;
each is the C function itself, so a call is a direct call:

```swift
@_extern(c, "epoll_wait") public func sys_epoll_wait(_ epfd: Int32, _ events: UnsafeMutableRawPointer,
                                                     _ max: Int32, _ timeout: Int32) -> Int32
```

(`.enableExperimentalFeature("Extern")` on the target.) The same works for:

- **io_uring** (the [`IORing`](../Sources/IORing/IORing.swift) module): `syscall(2)` with numbers 425, 426 and 427
  (the same on x86-64 and arm64). Map the rings with `mmap`, move their heads and tails through `Atomic<UInt32>` over
  the mapped memory, and write the entries at the kernel's offsets (check them once with a C program). Kernel 6.8 and 7.0 lay out the provided-buffer registration's reserved
  words differently, so test on both.
- **SQLite's B-tree:** build the unmodified amalgamation with `SQLITE_PRIVATE` defined empty, and its internal
  functions (`sqlite3BtreeCursor`, `sqlite3BtreeIndexMoveto`, `sqlite3VdbeRecordUnpack`, ...) become callable with
  `@_extern(c)` and opaque pointers. Call `sqlite3BtreePayloadSize` before `sqlite3BtreePayloadFetch`: the first
  parses the cell, the second only reads what it left.

## Instructions: import Builtin

Swift has no counterpart to C's `<immintrin.h>`, but the compiler's `Builtin` module exposes LLVM's target
intrinsics. With the hidden `-enable-builtin-module` flag, a file can `import Builtin` and call, for example,
`llvm.x86.sha256rnds2` on a `SIMD4<UInt32>`'s storage:

```swift
#if arch(x86_64)
import Builtin

@inline(__always) private func rounds2(_ cdgh: SIMD4<UInt32>, _ abef: SIMD4<UInt32>, _ wk: SIMD4<UInt32>) -> SIMD4<UInt32> {
    var r = SIMD4<UInt32>()
    r._storage._value = Builtin.int_x86_sha256rnds2(cdgh._storage._value, abef._storage._value, wk._storage._value)
    return r
}
#endif
```

`-parse-stdlib` works too, but parses the whole file as the standard library; `-enable-builtin-module` changes
nothing else. Both are hidden flags, so pin the toolchain: a change would break the build, not the output.

What makes it safe:

1. **A module of its own, with the feature enabled for it alone.** Without the feature LLVM aborts ("Cannot select:
   intrinsic"); with it enabled for a whole app, the compiler may use those instructions anywhere. In `Package.swift`:
   `.unsafeFlags(["-enable-builtin-module", "-Xcc", "-msha", "-Xcc", "-mssse3", "-Xcc", "-msse4.1"])`, chosen by
   `#if arch(x86_64)`. AVX-512 code needs a module separate from 128-bit code for the same reason.
2. **An `@inline(never)` entry point**, so no optimization carries those instructions into a module built without
   them.
3. **CPUID, not `/proc/cpuinfo`.** glibc's `__x86_get_cpuid_feature_leaf` (`<sys/platform/x86.h>`) reports a feature
   *usable* (the CPU has it and the kernel enables it), and reads nothing outside the process. See `CPUFeatures`.
4. **A self-check at start-up** against the portable code, on inputs that take every path, before using it.
5. **Selector immediates must be constants.** `pclmulqdq`'s selector is an `immarg`. Passed through a
   `@_transparent` wrapper, it becomes a literal only once the optimizer runs: an unoptimized build fails with
   "immarg operand has non-immediate parameter". Build such modules with `-O` even in debug builds.

Results: SHA-NI took about 1 µs per request off token checks. PCLMULQDQ folding made the gzip CRC about four times
faster than eight-byte tables, and VPCLMULQDQ widened it to 256 bytes per step on AVX-512 CPUs. The fold follows
Intel's "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ Instruction" (2009), with the constants Linux's
crc32-pclmul uses. Folding a lane D bits forward multiplies its halves by x^(D+32) and x^(D−32) mod P, bit-reflected;
that formula regenerates every constant, which is how to get the ones for new distances.

## What's still out of reach

No inline assembly. bcrypt's key schedule (the [`Bcrypt`](../Sources/Bcrypt/Bcrypt.swift) module), written out per
lane count and interleaved so the compiler only has registers to choose, still runs at 25 ms per cost-10 login on
x86 against 20 for hand-written assembly: LLVM spills registers at four or five lanes.

## Link-time optimization across Swift and C

A Swift module calling into a C target can't inline it: they are compiled apart. SwiftPM can optimize them together:

```sh
swift build -c release --build-system native --experimental-lto-mode=full \
  -Xswiftc -use-ld=lld -Xlinker --lto-O3 --static-swift-stdlib
```

The native build system is needed (the newer one expects object files where LTO writes bitcode), and so is the
toolchain's `lld`. Plain `-Xswiftc -lto=llvm-full` breaks both build systems the same way. With it, calls from the
Swift B-tree reader into SQLite's small functions (`PayloadSize`, `PayloadFetch`, `Eof`) went from 13, 13 and 2 call
sites to none. Compiling SQLite inside one C file with its internals `static`, as C projects do, gained nothing
measurable without LTO, and nothing reliable with it.

## Reading C structs from Swift: a borrowed view

Where C exposes no function for a field, read it through a view whose lifetime the compiler ties to the owner:

```swift
struct Page: ~Escapable {
    let fields: RawSpan          // the C struct, its size in bytes
    let bytes: Span<UInt8>       // the memory it describes
    var cellCount: Int { Int(fields.unsafeLoadUnaligned(fromByteOffset: Layout.pageCellCount, as: UInt16.self)) }
}

var page: Page {                 // on the cursor that owns it
    @_lifetime(borrow self) borrowing get { _overrideLifetime(Page(...), borrowing: self) }
}
```

The offsets are the pinned C version's; check them at startup against what the C library itself returns (where a
cell is, a count taken both ways) and fall back if they don't match. Span's bounds checks are preconditions, which
`-Ounchecked` removes: the disassembly of the hot loop had no trap instruction left. With the checks on (plain `-O`)
they stay; what that costs a whole server is unmeasured here, since the one box run of a build with them on scored the
same as a build that only took work out, on the same day (see [measuring](measuring.md)).

## SQLite drops a connection's cache when another one commits

At the start of each transaction, a WAL connection that sees a commit from another connection empties its whole page
cache. A checkpointer on its own connection that commits (to start the WAL over, say) costs the main connection its
cache every time. Let the checkpointer only copy, and let the main connection's own next write start the WAL over.

## A checkpoint that doesn't finish leaves its sync for later

SQLite syncs the database file only when a checkpoint has copied every frame of the WAL. Under steady writes a PASSIVE
checkpoint rarely gets there: it copies most of the WAL, writes those pages, and returns without syncing them. The copy
that does finish, the one that holds writes so it can catch up, then syncs everything the earlier copies wrote while
the writes wait. On a slow disk the hold ran out before the sync did, the WAL kept growing, and p99 passed a second.

What fixed it, on the checkpointer's own thread: copy while writes go on until at most 128 frames are left, sync the
database file yourself (`fdatasync`), copy once more, and sync again. The copy that holds writes then has a few dozen
frames to copy and little to sync. Two more things helped. Grow the file 64 MiB at a time (`SQLITE_FCNTL_CHUNK_SIZE`,
with `HAVE_POSIX_FALLOCATE` so it is one `posix_fallocate`), so a finished copy's truncate and sync don't also wait on
the file system's journal. And run the checkpointer at nice 5: at nice 19, near saturation, it got so little of the one
CPU that holds ran out.

On a runner with the server's disk capped at 30 MB/s and 1,000 writes a second, near saturation: p99 went from 1.4 s
to 250 ms, the WAL from 310 MB to 50 MB, the memory peak from 821 MB to 406 MB, and the holds that ran out from most to
about one in five.
