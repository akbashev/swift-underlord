# ``EventLoop``

An executor for actors on a thread of its own, sleeping in `epoll_wait`.

## Overview

``EventLoop/EventLoop`` is a `SerialExecutor` and a `TaskExecutor` over one thread. Jobs enqueued from other threads
wake it through an eventfd; between jobs it sleeps in `epoll_wait`, so an actor that runs on it can register its
sockets and wait for them in the same call that waits for jobs: a server that needs no global executor and no
libdispatch threads, one actor per core. Linux only.

```swift
actor Reactor {
    let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }
    init(loop: EventLoop) { self.loop = loop }
}

let loop = try EventLoop(name: "reactor-0")
try loop.register(listener, for: [.readable], token: 0)
```

An actor method that waits with ``EventLoop/EventLoop/wait(until:)`` must be `nonisolated(nonsending)` or isolated to
the actor: a plain `nonisolated async` function runs on the global executor, off the loop's thread.

## Topics

### The loop

- ``EventLoop/EventLoop``
- ``EventLoopError``
