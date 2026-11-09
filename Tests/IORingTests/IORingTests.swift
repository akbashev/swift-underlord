#if os(Linux)
import Glibc
import IORing
import Testing

/// Completions until one carries `userData`, waiting up to five seconds for each.
func completions(_ ring: inout IORing, through userData: UInt64) -> [IORing.Completion] {
    var seen: [IORing.Completion] = []
    while !seen.contains(where: { $0.userData == userData }) {
        if ring.submit(waitingFor: 1, timeout: .seconds(5)) == -ETIME { break }
        while let completion = ring.nextCompletion() { seen.append(completion) }
        ring.finishCompletions()
    }
    return seen
}

@Test(.timeLimit(.minutes(1))) func nopCompletesWithItsUserData() throws {
    var ring = try IORing(entries: 8)
    ring.prepare(.nop, userData: 7)
    let submitted = ring.submit(waitingFor: 1)
    let completion = ring.nextCompletion()
    let none = ring.nextCompletion()
    ring.finishCompletions()
    // (`#expect` takes its expression apart, which would copy the noncopyable ring: results go through locals.)
    #expect(submitted == 1)
    #expect(completion?.userData == 7 && completion?.result == 0)
    #expect(none == nil)
}

@Test(.timeLimit(.minutes(1))) func waitTimesOut() throws {
    var ring = try IORing(entries: 4, options: .singleThread)
    let needsEnter = ring.needsEnter
    let waited = ring.submit(waitingFor: 1, timeout: .milliseconds(20))
    #expect(!needsEnter)
    #expect(waited == -ETIME)
}

@Test(.timeLimit(.minutes(1))) func linkedWriteThenReadThroughAPipe() throws {
    var ring = try IORing(entries: 8, options: .singleThread)
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    let message = Array("hello, ring".utf8)
    var received = [UInt8](repeating: 0, count: 32)
    var seen: [IORing.Completion] = []
    message.withUnsafeBytes { out in
        received.withUnsafeMutableBytes { into in
            ring.reserve(2)
            ring.prepare(.write(.descriptor(fds[1]), from: out, offset: .max), userData: 1, link: .hard)
            ring.prepare(.read(.descriptor(fds[0]), into: into, offset: .max), userData: 2)
            seen = completions(&ring, through: 2)
        }
    }
    #expect(seen.map(\.userData) == [1, 2])
    #expect(seen.map(\.result) == [Int32(message.count), Int32(message.count)])
    #expect(Array(received.prefix(message.count)) == message)
}

@Test(.timeLimit(.minutes(1))) func acceptReceiveSendAndCloseOverLoopback() throws {
    var ring = try IORing(entries: 16, options: .singleThread)
    try ring.registerFiles(count: 4)
    let group = try ring.registerBuffers(count: 4, size: 1024)

    // A listener on 127.0.0.1, its port picked by the kernel, and a multishot accept into the registered table.
    let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
    #expect(bound == 0 && listen(listener, 16) == 0)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
    ring.prepare(.accept(.descriptor(listener), multishot: true, direct: true), userData: 1)
    ring.submit()

    let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    defer { close(client) }
    // The client's reads give up after five seconds instead of waiting for an answer that never comes.
    var patience = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) } }
    #expect(connected == 0)
    let accepted = try #require(completions(&ring, through: 1).first { $0.userData == 1 })
    #expect(accepted.result >= 0 && accepted.hasMore)
    let slot = UInt32(accepted.result)

    // A multishot receive into the provided buffers.
    ring.prepare(.receiveProvided(.fixed(slot), group: group, multishot: true), userData: 2)
    var ping = Array("ping".utf8)
    #expect(write(client, &ping, ping.count) == ping.count)
    let received = try #require(completions(&ring, through: 2).first { $0.userData == 2 })
    #expect(received.result == Int32(ping.count) && received.hasMore)
    let buffer = try #require(received.bufferID)
    let bytes = Array(ring.buffer(group: group, buffer, count: ping.count))
    #expect(bytes == ping)
    ring.recycle(group: group, buffer: buffer)

    // A reply, then a shutdown and close linked into one chain: the receive ends with end-of-file.
    let pong = Array("pong".utf8)
    var seen: [IORing.Completion] = []
    pong.withUnsafeBytes { bytes in
        ring.prepare(.send(.fixed(slot), bytes), userData: 3)
        seen = completions(&ring, through: 3)
    }
    #expect(seen.first { $0.userData == 3 }?.result == Int32(pong.count))
    var reply = [UInt8](repeating: 0, count: 8)
    #expect(read(client, &reply, reply.count) == pong.count && Array(reply.prefix(pong.count)) == pong)
    ring.reserve(2)
    ring.prepare(.shutdown(.fixed(slot)), userData: 4, link: .hard)
    ring.prepare(.close(.fixed(slot)), userData: 5)
    seen = completions(&ring, through: 5)
    #expect(seen.first { $0.userData == 5 }?.result == 0)
    #expect(read(client, &reply, reply.count) == 0)
}
#endif
