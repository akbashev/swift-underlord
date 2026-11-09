# ``Buffers``

Noncopyable buffers that own their memory: bytes, an array of noncopyable elements, and a queue.

## Overview

`[UInt8]` is a fine general-purpose array and a slow growable buffer: every `append(contentsOf:)` is a generic call
with a uniqueness check. ``ByteBuffer`` owns raw memory, is `~Copyable` so it can't be shared, and appends with a
capacity check and a `memcpy`. ``ByteBuffer/append(maximum:_:)`` reserves room for a whole response once and lets the
caller write it through an `OutputRawSpan` whose appends check the room left (``Swift/OutputRawSpan`` extensions add
literals, unaligned values and decimals).

``UniqueArray`` holds `~Copyable` elements, and ``Fifo`` is a queue that compacts only when the consumed part is large.

```swift
var out = ByteBuffer(capacity: 4096)
out.append("HTTP/1.1 200 OK\r\n")
out.append(maximum: 64) { head in
    head.appendLiteral("Content-Length: ")
    head.appendDecimal(Int64(body.count))
    head.appendLiteral("\r\n\r\n")
}
```

## Topics

### Bytes

- ``ByteBuffer``

### Elements

- ``UniqueArray``
- ``Fifo``
