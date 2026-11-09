# ``Gzip``

gzip for in-memory bodies at ISA-L level 0's speed, in Swift.

## Overview

``Gzip`` compresses a whole body in one call into room the caller provides (``Gzip/bound(_:)`` bytes is always
enough). It is ISA-L's level-0 design ported to Swift: its default Huffman table, a hash table of 16-bit positions, two
positions per step, 8-byte compares, and a branch-free 64-bit bit writer. The output is about 40% larger than zlib's
level 1, in about a sixth of the time: right for HTTP responses, where a few hundred bytes rarely cost a packet and CPU
time always costs throughput; not for archives.

```swift
var gzip = Gzip()
var out = [UInt8](repeating: 0, count: Gzip.bound(body.count))
let count = body.withUnsafeBytes { input in
    out.withUnsafeMutableBytes { gzip.compress(input, into: $0) }
}
```

The CRC-32 in the gzip trailer comes from the `CRC32` module, on carry-less multiplies where the CPU has them.

## Topics

### Compressing

- ``Gzip/init()``
- ``Gzip/compress(_:into:)``
- ``Gzip/bound(_:)``
