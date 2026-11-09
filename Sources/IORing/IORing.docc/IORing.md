# ``IORing``

io_uring over its system calls, in Swift: rings, typed requests, completions, registered files and provided buffers.

## Overview

``IORing/IORing`` maps a ring's submission and completion queues and reads and writes them with `Atomic` loads and
stores, as the kernel's ABI requires; `io_uring_setup`, `io_uring_enter` and `io_uring_register` go through
`syscall(2)`. There is no liburing and no C. Requests are an enum (``IORing/IORing/Request``) rather than raw
submission entries, so a field can't be left unset; a ring is `~Copyable`, so it has exactly one owner. Linux only.

```swift
var ring = try IORing(entries: 4096, options: .singleThread)
try ring.registerFiles(count: 65_536)
let group = try ring.registerBuffers(count: 1024, size: 2048)
ring.prepare(.accept(listener, direct: true), userData: 1)
_ = ring.submit(waitingFor: 1)
while let completion = ring.nextCompletion() { /* ... */ }
ring.finishCompletions()
```

Docker's default seccomp profile blocks io_uring: run tests with `--security-opt seccomp=unconfined`.

## Topics

### The ring

- ``IORing/IORing``
- ``IORingError``
