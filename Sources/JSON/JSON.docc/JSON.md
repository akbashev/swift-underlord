# ``JSON``

JSON read without building anything, and written 32 bytes at a time.

## Overview

A request body or a token's claims rarely need a tree. ``JSON/scan(_:keys:)`` validates a whole document (UTF-8,
escapes, numbers, nesting up to 64 levels) and keeps only the members the caller names, as places in the bytes; strings
are read in place (``JSON/withString(_:_:_:)``) and unescaped only when they have escapes. Writing escapes strings 32
bytes per step, copying a chunk whole when nothing in it needs escaping, and integers two digits per step.

```swift
guard let found = JSON.scan(body, keys: ["body", "tags"]), found.isObject,
      let text = found[0], text.kind == .string else { return badRequest }
JSON.withString(body, text) { save($0) }

var out = ByteBuffer()
JSON.writeString(&out, title)
```

## Topics

### Reading

- ``JSON/scan(_:keys:)``
- ``JSON/isValid(_:)``
- ``JSON/withString(_:_:_:)``
- ``JSON/integer(_:_:)``
- ``JSON/number(_:_:)``

### Writing

- ``JSON/writeString(_:_:)``
- ``JSON/writeInteger(_:_:)``
