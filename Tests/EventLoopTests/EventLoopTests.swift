#if os(Linux)
import EventLoop
import Glibc
import Synchronization
import Testing

/// An actor isolated to a loop.
actor OnLoop {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }
    /// Set just before `waitForMessage` blocks.
    nonisolated let blocking = Atomic<Bool>(false)

    init(_ loop: EventLoop) { self.loop = loop }

    func onLoopThread() -> Bool { loop.isIsolatingCurrentContext() == true }

    func waitForInterrupt() async { await loop.wait() }

    func wait(for duration: Duration) async -> Duration {
        let start = ContinuousClock.now
        await loop.wait(until: start + duration)
        return .now - start
    }

    /// Watches `fd` for reading with `token` until it is ready.
    func readable(_ fd: Int32, token: UInt64) throws -> [(token: UInt64, events: EventLoop.Events)] {
        try loop.register(fd, for: .readable, token: token)
        var events = EventLoop.EventBuffer(capacity: 8)
        var seen: [(token: UInt64, events: EventLoop.Events)] = []
        while seen.isEmpty {
            let (n, _) = loop.waitForEvents(&events)
            for i in 0..<n { seen.append(events[i]) }
        }
        try loop.remove(fd)
        return seen
    }

    /// Blocks in epoll_wait with nothing registered: only a message for the loop ends it.
    func waitForMessage() -> (count: Int, jobsWaiting: Bool) {
        var events = EventLoop.EventBuffer(capacity: 4)
        blocking.store(true, ordering: .releasing)
        return loop.waitForEvents(&events)
    }

    /// A message for the loop. It touches the actor's state: a call to an empty actor method is inlined in a release
    /// build, and the hops to the actor and back go with it, so no job would reach the loop.
    private var pings = 0
    func ping() -> Int {
        pings += 1
        return pings
    }
}

@Test(.timeLimit(.minutes(1))) func actorsRunOnTheLoopsThread() async throws {
    let loop = try EventLoop(name: "test-loop")
    #expect(await OnLoop(loop).onLoopThread())
    #expect(loop.isIsolatingCurrentContext() == false)
    #expect(await Task(executorPreference: loop) { loop.isIsolatingCurrentContext() == true }.value)
}

@Test(.timeLimit(.minutes(1))) func interruptEndsAWaitBeforeOrDuring() async throws {
    let actor = OnLoop(try EventLoop(name: "test-loop"))
    actor.loop.interrupt()
    await actor.waitForInterrupt()
    async let waited: Void = actor.waitForInterrupt()
    try await Task.sleep(for: .milliseconds(20))
    actor.loop.interrupt()
    await waited
}

@Test(.timeLimit(.minutes(1))) func waitLastsUntilItsDeadline() async throws {
    let actor = OnLoop(try EventLoop(name: "test-loop"))
    #expect(await actor.wait(for: .milliseconds(30)) >= .milliseconds(30))
}

@Test(.timeLimit(.minutes(1))) func registeredDescriptorsWakeTheLoop() async throws {
    let actor = OnLoop(try EventLoop(name: "test-loop"))
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    var byte: UInt8 = 1
    #expect(write(fds[1], &byte, 1) == 1)
    let seen = try await actor.readable(fds[0], token: 42)
    #expect(seen.count == 1 && seen[0].token == 42 && seen[0].events.contains(.readable))
}

@Test(.timeLimit(.minutes(1))) func messagesWakeWaitForEvents() async throws {
    let actor = OnLoop(try EventLoop(name: "test-loop"))
    async let woke = actor.waitForMessage()
    while !actor.blocking.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(1)) }
    _ = await actor.ping()
    let (count, jobsWaiting) = await woke
    #expect(count == 0 && jobsWaiting)
}
#endif
