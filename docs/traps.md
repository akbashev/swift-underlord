# Traps

## -Ounchecked skips a precondition's condition, side effects included

```swift
precondition(r.take(1) == 1 && r.take(2) == 2)   // under -Ounchecked, neither take() runs
```

A decoder that read its first three bits inside a `precondition` started three bits late in the release build only.
Read into `let`s first, then check them.

## Lazy globals in hot loops

A file-scope or `static let` costs a `swift_once` check on every access. See [standard library](stdlib.md).

## Unsafe flags in a dependency

`.unsafeFlags` (needed for `-Xcc -msha` and the like) used to be refused in a package depended on by version.
SwiftPM 6.4.2 accepted it in a test with a versioned git dependency, but to be safe, keep such modules behind a
package trait, so a consumer can build without them (`traits: []`).

## The build machine picks the flags

`#if arch(x86_64)` in `Package.swift` is evaluated on the machine running SwiftPM. That is right when the server is
built on the box it runs on, and wrong when cross-compiling.

## Availability on macOS

`InlineArray` needs macOS 26, and `RawSpan.load(fromByteOffset:as:_:)` with a byte order needs macOS 27. Linux has no
such floor.

## Emulators don't have every instruction

Rosetta on Apple silicon has PCLMULQDQ but neither SHA-NI nor AVX-512, and Docker's x86 emulation lists no `sha_ni`.
Test those paths on x86 hardware (GitHub's runners have them).

## Leaving parts of SQLite out

`SQLITE_OMIT_UTF16` also removes `PRAGMA encoding`; a check that used it failed silently and fell back to a slow path.
Read the text encoding with SQL instead (`SELECT length(CAST('ab' AS BLOB))`).

## Disk on small boxes

The Swift 6.4.2 toolchain is a 1.1 GB tarball that unpacks to 3.7 GB. Stream it into `tar`, checking the SHA-256 on
the way through a FIFO, and leave out what a release build doesn't use (LLDB, SourceKit-LSP, clangd, DocC,
swift-format): 2.6 GB on disk, no tarball stored.

## Build for the machine

- `-target-cpu` from `clang -march=native -### -c -x c /dev/null` (Swift has no `native`).
- `--static-swift-stdlib`, so calls into the runtime are direct rather than through the PLT.
- `-enforce-exclusivity=unchecked` once the design guarantees exclusivity (actor state touched by its own thread).

## `OutputRawSpan.append(_:as:)` assumes alignment

```swift
out.append(chunk, as: SIMD32<UInt8>.self)   // initializeMemory(as:): an aligned 32-byte store
```

The generic `append(_:as:)` initializes the memory *as* the type, so the compiler may use an aligned store. Apple
silicon tolerates an unaligned vector store; x86 faults on it (`vmovdqa` to an address that isn't 16- or 32-byte
aligned), so a server that passed every test on a Mac crashed on its first response on an x86 runner. For bytes at
any offset, use `storeBytes(of:toByteOffset:as:)`, which needs no alignment, through `withUnsafeMutableBytes`. And
test code that touches SIMD or memory layout on x86 before it ships.

## Docker blocks io_uring

Docker's default seccomp profile refuses `io_uring_setup` (`EPERM`). Run an io_uring server in a container with
`--security-opt seccomp=unconfined`. Under Rosetta's x86 emulation it is `ENOSYS` either way.

## An empty actor method may not hop at all

```swift
func ping() {}               // on an actor
await actor.ping()           // release: inlined, and the hops to the actor and back removed as redundant
```

The optimizer drops a hop when nothing between it and the next hop needs the actor. A test that sent an empty message
to wake an executor passed in debug and hung in every release run: no job ever reached the executor. A message meant
to reach the actor's executor has to touch the actor's state.
