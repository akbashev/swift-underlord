# The standard library on hot paths

## A buffer that owns its memory

`[UInt8]` as a growing output buffer costs more than it looks. `append(contentsOf:)` takes any `Sequence`; the
specialized version is still too big to inline, and every mutation checks that the array is uniquely referenced. A
JSON writer appends a literal per field, so this adds up.

A `~Copyable` struct holding a pointer, a count and a capacity has one owner by construction, so it needs no
uniqueness check, and appending becomes:

```swift
@inline(__always) mutating func append(_ raw: UnsafeRawBufferPointer) {
    guard let src = raw.baseAddress, raw.count > 0 else { return }
    if capacity - count < raw.count { grow(to: max(count + raw.count, capacity * 2)) }  // @inline(never)
    UnsafeMutableRawPointer(base! + count).copyMemory(from: src, byteCount: raw.count)
    count += raw.count
}
```

It lends its bytes as a `Span` (`@_lifetime(borrow self)`), and a `Span` can be passed through an awaited actor
call, so a worker can lend a whole batch of response bodies to another thread without copying them.

## Dictionary and Set always hash with SipHash

You can't give `Dictionary` another hasher. For a per-batch set of keys (user ids, slugs, pairs), an open-addressing
table over the caller's array works better: 16- or 32-bit slots, linear probing, at most half full, and a hash of one
multiply per word with a final mix. Byte keys hash eight bytes per step instead of one.

## sort() calls its comparison

The standard library's `sort` is stable and calls its `areInIncreasingOrder` closure for every comparison; in a
profile it appeared as `implicit closure #1 in MutableCollection.sort()`. An `@inline(__always)` unstable sort
(quicksort on a median of three, insertion sort below 16, heapsort past a depth limit, working on an
`UnsafeMutableBufferPointer`) gets its comparison inlined.

When the comparison reads other state (cells of a row buffer), it may still not inline. Read the sort keys into a
small array of tuples first, then sort integers.

## Globals cost a check per access

A file-scope or `static let` is initialized lazily, behind `swift_once`. In a loop that check costs on every access.
A CRC fold with its constants as file-scope `let`s made eight `swift_once` calls; the same constants as locals
became immediate operands, with no calls. For tables, copy them into instance storage once.

## Small values in place

- `InlineArray` for fixed-size state: SHA-256's eight words, a response head, a 20-digit number buffer.
- A key type that holds up to 56 bytes in seven words (`InlineArray<7, UInt64>`), with a heap fallback, makes routing
  allocate nothing for a slug or a username.

## Inlining across modules

A hot function in another module is not inlined unless it is `@inlinable` (its body is part of the interface) and,
for a small one, `@inline(__always)`. An io_uring `entry()` stayed a call until both were added. `@usableFromInline`
exposes internal declarations to inlinable code without making them public.
