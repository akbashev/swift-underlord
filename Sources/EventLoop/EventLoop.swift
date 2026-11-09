// An executor for actors: one thread of its own, an epoll instance and an eventfd. Swift's runtime hands it an actor's
// jobs through `enqueue`, from whichever thread sent the message, so the job list is the one place two threads meet (a
// Mutex), and the thread runs them one at a time, in order. With no job to run it sleeps in epoll_wait on the eventfd.
//
// An actor isolated to the loop can also use the loop's thread for I/O: register sockets on the loop's epoll instance
// and block in `waitForEvents`, which returns when a socket is ready or a message for the loop arrives. With
// `wait(until:)` and `interrupt()` it can wait for a deadline or a wake-up while the thread runs the loop's other jobs.
//
//     actor Server {
//         nonisolated let loop: EventLoop
//         nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }
//     }
//
// The thread lives as long as the process: a server's loops run until it exits.
#if os(Linux)
import Glibc
import Synchronization

public final class EventLoop: SerialExecutor, TaskExecutor {
    /// What a registered descriptor is watched for, and what `waitForEvents` reports (epoll's flags).
    public struct Events: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let readable = Events(rawValue: 0x001)
        public static let writable = Events(rawValue: 0x004)
        /// Always reported; no need to ask.
        public static let error = Events(rawValue: 0x008)
        /// Always reported; no need to ask.
        public static let hangUp = Events(rawValue: 0x010)
        /// The peer shut down its side (EPOLLRDHUP).
        public static let peerClosed = Events(rawValue: 0x2000)
        public static let oneShot = Events(rawValue: 1 << 30)
        public static let edgeTriggered = Events(rawValue: 1 << 31)
    }

    /// Room for the events one `waitForEvents` returns. `epoll_event` is packed on x86-64 (12 bytes) and naturally
    /// aligned elsewhere (16); Swift has no packed structs, so the events are read at the ABI's offsets.
    public struct EventBuffer: ~Copyable {
        #if arch(x86_64)
        @usableFromInline static let stride = 12, dataOffset = 4
        #else
        @usableFromInline static let stride = 16, dataOffset = 8
        #endif
        @usableFromInline let raw: UnsafeMutableRawPointer
        public let capacity: Int

        public init(capacity: Int) {
            precondition(capacity > 0 && capacity <= Int(Int32.max) / Self.stride)
            self.capacity = capacity
            raw = .allocate(byteCount: capacity * Self.stride, alignment: 8)
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity * Self.stride)
        }

        deinit { raw.deallocate() }

        /// Event `i`: the token its descriptor was registered with, and what happened.
        @inlinable public subscript(i: Int) -> (token: UInt64, events: Events) {
            precondition(i >= 0 && i < capacity)
            return (token(i), Events(rawValue: raw.loadUnaligned(fromByteOffset: i * Self.stride, as: UInt32.self)))
        }

        @inlinable func token(_ i: Int) -> UInt64 {
            raw.loadUnaligned(fromByteOffset: i * Self.stride + Self.dataOffset, as: UInt64.self)
        }

        func move(_ from: Int, to: Int) {
            (raw + to * Self.stride).copyMemory(from: raw + from * Self.stride, byteCount: Self.stride)
        }
    }

    /// The epoll instance a loop's sockets are registered on.
    private let epollFD: Int32
    /// An epoll instance with only the eventfd: what the thread waits on with no job to run. Registered sockets stay
    /// ready (level-triggered) while the actor using them is busy elsewhere, so waiting on `epollFD` then would
    /// return at once, again and again.
    private let idleFD: Int32
    private let wakeFD: Int32
    /// The eventfd's token; not for registered descriptors.
    public static let reservedToken = UInt64.max

    private let jobs = Mutex<[UnownedJob]>([])
    private let park = Mutex<Park>(.idle)
    /// The loop is in (or about to enter) epoll_wait: whoever queues a job next writes the eventfd.
    private let sleeping = Atomic<Bool>(false)
    private let threadID = Atomic<UInt>(0)

    private enum Park: Sendable {
        case idle
        /// A pending `wait`, until `deadline` (nil: none).
        case waiting(UnsafeContinuation<Void, Never>, deadline: ContinuousClock.Instant?)
        /// `interrupt()` came with no wait pending: the next one returns at once.
        case woken
    }

    private let name: String
    private let nice: Int32

    /// A loop on a new thread named `name` (15 bytes at most are kept), at scheduling priority `nice`. With
    /// `onCallingThread`, no thread is started: the loop runs when a thread gives itself to it with
    /// `runOnCallingThread()` (the main thread, once it's done setting up).
    public init(name: String, nice: Int32 = 0, onCallingThread: Bool = false) throws(EventLoopError) {
        self.name = name
        self.nice = nice
        epollFD = sys_epoll_create1(EPOLL_CLOEXEC)
        idleFD = sys_epoll_create1(EPOLL_CLOEXEC)
        wakeFD = sys_eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)
        guard epollFD >= 0, idleFD >= 0, wakeFD >= 0 else {
            let error = EventLoopError("epoll_create1/eventfd")
            for fd in [epollFD, idleFD, wakeFD] where fd >= 0 { close(fd) }
            throw error
        }
        for fd in [epollFD, idleFD] {
            guard Self.control(fd, EPOLL_CTL_ADD, wakeFD, Events.readable.rawValue, Self.reservedToken) == 0 else {
                let error = EventLoopError("epoll_ctl eventfd")
                for fd in [epollFD, idleFD, wakeFD] { close(fd) }
                throw error
            }
        }
        if !onCallingThread { try startThread() }
    }

    /// Gives the calling thread to this loop, for good.
    public func runOnCallingThread() -> Never {
        nameThread()
        run()
    }

    // ---------- descriptors, for the actor isolated to this loop ----------

    /// Watches `fd` for `events`; `waitForEvents` reports it with `token` (any value but `reservedToken`).
    public func register(_ fd: Int32, for events: Events, token: UInt64) throws(EventLoopError) {
        precondition(token != Self.reservedToken, "EventLoop.reservedToken is the loop's own")
        guard Self.control(epollFD, EPOLL_CTL_ADD, fd, events.rawValue, token) == 0 else { throw EventLoopError("epoll_ctl add") }
    }

    /// Changes what `fd` is watched for, and its token.
    public func modify(_ fd: Int32, for events: Events, token: UInt64) throws(EventLoopError) {
        precondition(token != Self.reservedToken, "EventLoop.reservedToken is the loop's own")
        guard Self.control(epollFD, EPOLL_CTL_MOD, fd, events.rawValue, token) == 0 else { throw EventLoopError("epoll_ctl mod") }
    }

    /// Stops watching `fd` (closing it does too, once no other descriptor refers to its file).
    public func remove(_ fd: Int32) throws(EventLoopError) {
        guard Self.control(epollFD, EPOLL_CTL_DEL, fd, 0, 0) == 0 else { throw EventLoopError("epoll_ctl del") }
    }

    /// epoll_ctl with an event built at the ABI's offsets.
    private static func control(_ epfd: Int32, _ op: Int32, _ fd: Int32, _ events: UInt32, _ token: UInt64) -> Int32 {
        withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { raw in
            raw.storeBytes(of: events, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: token, toByteOffset: EventBuffer.dataOffset, as: UInt64.self)
            return sys_epoll_ctl(epfd, op, fd, raw.baseAddress!)
        }
    }

    // ---------- the executor ----------

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        jobs.withLock { $0.append(job) }
        wake()
    }

    /// Writes the eventfd if the loop sleeps (or is about to), so it looks again at its jobs and its wait's deadline.
    private func wake() {
        if sleeping.exchange(false, ordering: .sequentiallyConsistent) {
            var one: UInt64 = 1
            _ = sys_write(wakeFD, &one, 8)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Whether the calling thread is this loop's: what `assumeIsolated` and `preconditionIsolated` check.
    public func isIsolatingCurrentContext() -> Bool? {
        threadID.load(ordering: .relaxed) == UInt(bitPattern: Int(bitPattern: pthread_self()))
    }

    public func checkIsolated() {
        if isIsolatingCurrentContext() != true { fatalError("not on this event loop's thread") }
    }

    // ---------- waiting, for the actor isolated to this loop ----------

    /// Suspends the caller until `deadline` passes or `interrupt()` (which may also have come just before), while the
    /// thread runs the loop's other jobs. One wait at a time; it can return early, so callers check what they wait for
    /// again. It runs on the caller's executor (nonsending), the loop's for the actor isolated to it.
    public nonisolated(nonsending) func wait(until deadline: ContinuousClock.Instant? = nil) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let now = park.withLock { p -> Bool in
                if case .woken = p {
                    p = .idle
                    return true
                }
                p = .waiting(continuation, deadline: deadline)
                return false
            }
            if now {
                continuation.resume()
            } else if deadline != nil && isIsolatingCurrentContext() != true {
                // Parked from another thread: the loop may have gone to sleep without this deadline.
                wake()
            }
        }
    }

    /// Ends the pending `wait`, or the next one if none is pending. From any thread.
    public func interrupt() {
        park.withLock { p -> UnsafeContinuation<Void, Never>? in
            if case .waiting(let continuation, _) = p {
                p = .idle
                return continuation
            }
            p = .woken
            return nil
        }?.resume()
    }

    /// The pending wait's deadline, if a wait with one is pending.
    private var deadline: ContinuousClock.Instant? {
        park.withLock { p in
            if case .waiting(_, let deadline) = p { deadline } else { nil }
        }
    }

    /// Ends the pending wait if its deadline has passed (never leaving a wake-up for the next one).
    private func expire(_ now: ContinuousClock.Instant) {
        park.withLock { p -> UnsafeContinuation<Void, Never>? in
            guard case .waiting(let continuation, let deadline?) = p, deadline <= now else { return nil }
            p = .idle
            return continuation
        }?.resume()
    }

    /// For the actor isolated to this loop, on its thread: blocks in epoll_wait until a registered descriptor is ready
    /// or a job is queued for the loop. Returns how many of `events` are filled (the eventfd's own are left out) and
    /// whether jobs are waiting, which the caller lets run by suspending (`await Task.yield()`).
    public func waitForEvents(_ events: inout EventBuffer) -> (count: Int, jobsWaiting: Bool) {
        assert(isIsolatingCurrentContext() == true, "waitForEvents is for the loop's own thread")
        sleeping.store(true, ordering: .sequentiallyConsistent)
        let timeout: Int32 = jobs.withLock({ $0.isEmpty }) ? -1 : 0
        let n = Int(max(sys_epoll_wait(epollFD, events.raw, Int32(events.capacity), timeout), 0))
        sleeping.store(false, ordering: .relaxed)
        var kept = 0
        for i in 0..<n {
            if events.token(i) == Self.reservedToken {
                var value: UInt64 = 0
                _ = sys_read(wakeFD, &value, 8)
                continue
            }
            if kept != i { events.move(i, to: kept) }
            kept += 1
        }
        return (kept, !jobs.withLock { $0.isEmpty })
    }

    // ---------- the thread ----------

    private func run() -> Never {
        threadID.store(UInt(bitPattern: Int(bitPattern: pthread_self())), ordering: .relaxed)
        var events = EventBuffer(capacity: 1)
        var batch: [UnownedJob] = []
        while true {
            jobs.withLock { swap(&batch, &$0) }
            if !batch.isEmpty {
                for job in batch {
                    job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: asUnownedTaskExecutor())
                }
                batch.removeAll(keepingCapacity: true)
                // A wait whose deadline passed while jobs kept coming ends now, not at the next idle moment.
                if deadline != nil { expire(.now) }
                continue
            }
            // Asleep first, then a look at the jobs and the wait: whoever adds either after that look sees the flag
            // and writes the eventfd (`wake`).
            sleeping.store(true, ordering: .sequentiallyConsistent)
            if !jobs.withLock({ $0.isEmpty }) {
                sleeping.store(false, ordering: .relaxed)
                continue
            }
            let deadline = self.deadline
            var timeout: Int32 = -1
            if let deadline {
                let (seconds, attoseconds) = (deadline - .now).components
                // Rounded up to whole milliseconds, at most a minute (the loop looks again then).
                timeout = seconds < 0 || (seconds == 0 && attoseconds <= 0) ? 0
                    : Int32(min(seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000, 60_000))
            }
            if sys_epoll_wait(idleFD, events.raw, 1, timeout) > 0 {
                var value: UInt64 = 0
                _ = sys_read(wakeFD, &value, 8)
            }
            sleeping.store(false, ordering: .relaxed)
            if deadline != nil { expire(.now) }
        }
    }

    private final class ThreadStart {
        let loop: EventLoop
        init(_ loop: EventLoop) { self.loop = loop }
    }

    private func startThread() throws(EventLoopError) {
        let start = Unmanaged.passRetained(ThreadStart(self)).toOpaque()
        var thread = pthread_t()
        let rc = pthread_create(&thread, nil, { raw in
            let loop = Unmanaged<ThreadStart>.fromOpaque(raw!).takeRetainedValue().loop
            loop.nameThread()
            loop.run()
        }, start)
        guard rc == 0 else {
            Unmanaged<ThreadStart>.fromOpaque(start).release()
            throw EventLoopError("pthread_create", rc)
        }
        pthread_detach(thread)
    }

    /// Names the calling thread and sets its priority.
    private func nameThread() {
        let bytes = Array(name.utf8.prefix(15)) + [0]
        _ = bytes.withUnsafeBytes { sys_pthread_setname_np(pthread_self(), $0.baseAddress!) }
        if nice != 0 { _ = sys_setpriority(0, UInt32(bitPattern: sys_gettid()), nice) }
    }
}

public struct EventLoopError: Error, CustomStringConvertible {
    public let call: String
    public let code: Int32
    init(_ call: String, _ code: Int32 = errno) {
        self.call = call
        self.code = code
    }
    public var description: String { "\(call): \(String(cString: strerror(code)))" }
}

// The calls Glibc's Swift module leaves out, declared here so this file and the one beside it are all the module needs
// (`@_extern(c)`, the Extern experimental feature): each is a direct call to the C function.
@_extern(c, "epoll_create1") func sys_epoll_create1(_ flags: Int32) -> Int32
@_extern(c, "epoll_ctl") func sys_epoll_ctl(_ epfd: Int32, _ op: Int32, _ fd: Int32, _ event: UnsafeMutableRawPointer) -> Int32
@_extern(c, "epoll_wait") func sys_epoll_wait(_ epfd: Int32, _ events: UnsafeMutableRawPointer, _ maxEvents: Int32, _ timeout: Int32) -> Int32
@_extern(c, "eventfd") func sys_eventfd(_ initval: UInt32, _ flags: Int32) -> Int32
@_extern(c, "read") func sys_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int
@_extern(c, "write") func sys_write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int
@_extern(c, "pthread_setname_np") func sys_pthread_setname_np(_ thread: pthread_t, _ name: UnsafeRawPointer) -> Int32
@_extern(c, "setpriority") func sys_setpriority(_ which: Int32, _ who: UInt32, _ prio: Int32) -> Int32
@_extern(c, "gettid") func sys_gettid() -> Int32

// Linux's values (sys/epoll.h, sys/eventfd.h), the same on x86-64 and arm64.
let EPOLL_CLOEXEC: Int32 = 0o2000000
let EPOLL_CTL_ADD: Int32 = 1, EPOLL_CTL_DEL: Int32 = 2, EPOLL_CTL_MOD: Int32 = 3
let EFD_NONBLOCK: Int32 = 0o4000, EFD_CLOEXEC: Int32 = 0o2000000
#endif
