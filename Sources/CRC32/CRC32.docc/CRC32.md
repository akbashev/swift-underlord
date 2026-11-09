# ``CRC32``

CRC-32 as gzip and zlib use it, on PCLMULQDQ or AVX-512 VPCLMULQDQ where the CPU has them.

## Overview

One-shot (``CRC32/checksum(_:)``) or incremental (``CRC32/update(_:)-(Span<UInt8>)``). On x86-64 it folds 64 bytes
per step with carry-less multiplies, eight lanes at a time with AVX-512's VPCLMULQDQ; elsewhere it runs a portable
slicing-by-8 table. ``CRC32/instructions`` says which path was chosen.

```swift
let sum = CRC32.checksum(bytes.span)
```

## Topics

### Checksums

- ``CRC32/checksum(_:)``
- ``CRC32/init()``
- ``CRC32/value``

### The path taken

- ``CRC32/instructions``
