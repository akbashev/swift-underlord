// Each test parses text into a plain value: what the handler saw, copied out of the request, or why it stopped.
import Buffers
import HTTP
import Testing

private struct Seen: Equatable {
    var method = "", target = "", path = "", body = ""
    var query: String?
    var host: String?
    var version = HTTP.Version.http11
    var keepAlive = true
}

private enum Outcome: Equatable {
    case complete(consumed: Int, keepAlive: Bool, Seen)
    case incomplete(sendContinue: Bool)
    case rejected(UInt16)
}

private func string(_ bytes: Span<UInt8>) -> String {
    bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
}

/// `Optional.map` needs an escapable value, which a `Span` isn't.
private func optionalString(_ bytes: Span<UInt8>?) -> String? {
    guard let bytes else { return nil }
    return string(bytes)
}

private func parse(_ bytes: [UInt8], limits: HTTP.Limits = HTTP.Limits()) -> Outcome {
    let parsed = HTTP.parse(bytes.span, limits: limits) { (request: borrowing HTTP.Request) -> Seen in
        var seen = Seen()
        seen.method = string(request.method)
        seen.target = string(request.target)
        seen.path = string(request.path)
        seen.query = optionalString(request.query)
        seen.body = string(request.body)
        seen.host = optionalString(request.header("host"))
        seen.version = request.version
        seen.keepAlive = request.keepAlive
        return seen
    }
    switch parsed {
    case .complete(let consumed, let keepAlive, let seen): return .complete(consumed: consumed, keepAlive: keepAlive, seen)
    case .incomplete(let sendContinue): return .incomplete(sendContinue: sendContinue)
    case .rejected(let status): return .rejected(status)
    }
}

private func parse(_ text: String, limits: HTTP.Limits = HTTP.Limits()) -> Outcome {
    parse(Array(text.utf8), limits: limits)
}

@Test func parsesARequestInPlace() {
    let text = "GET /feed?limit=20&x=y HTTP/1.1\r\nHOST:  example.org \r\nAccept: */*\r\n\r\n"
    var expected = Seen()
    expected.method = "GET"
    expected.target = "/feed?limit=20&x=y"
    expected.path = "/feed"
    expected.query = "limit=20&x=y"
    expected.host = "example.org"
    #expect(parse(text) == .complete(consumed: text.utf8.count, keepAlive: true, expected))
}

@Test func connectionHeaderAndVersion() {
    guard case .complete(_, let keepAlive10, let seen10) = parse("GET / HTTP/1.0\r\n\r\n") else { Issue.record(); return }
    #expect(!keepAlive10 && seen10.version == .http10)
    guard case .complete(_, let keepAlive10KA, _) = parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n") else {
        Issue.record(); return
    }
    #expect(keepAlive10KA)
    guard case .complete(_, let keepAlive11, _) = parse("GET / HTTP/1.1\r\nconnection: close\r\n\r\n") else {
        Issue.record(); return
    }
    #expect(!keepAlive11)
}

@Test func pipelinedRequestsOneAtATime() {
    let first = "POST /posts HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
    let second = "GET /posts/7 HTTP/1.1\r\n\r\n"
    var bytes = Array((first + second).utf8)
    guard case .complete(let consumed, _, let seen) = parse(bytes) else { Issue.record(); return }
    #expect(consumed == first.utf8.count && seen.body == "hello" && seen.method == "POST")
    bytes.removeFirst(consumed)
    guard case .complete(let consumed2, _, let seen2) = parse(bytes) else { Issue.record(); return }
    #expect(consumed2 == second.utf8.count && seen2.path == "/posts/7" && seen2.body.isEmpty)
}

@Test func everyPrefixIsIncomplete() {
    for text in [
        "POST /posts HTTP/1.1\r\nHost: a\r\nContent-Length: 11\r\n\r\nhello world",
        "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n",
    ] {
        let bytes = Array(text.utf8)
        for n in 0..<bytes.count {
            let outcome = parse(Array(bytes[0..<n]))
            #expect(outcome == .incomplete(sendContinue: false), "\(n) of \(bytes.count) bytes")
        }
        guard case .complete(let consumed, _, let seen) = parse(bytes) else { Issue.record(); continue }
        #expect(consumed == bytes.count && seen.body == "hello world")
    }
}

@Test func expectContinueWaitsForTheBody() {
    let head = "POST /posts HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n"
    #expect(parse(head) == .incomplete(sendContinue: true))
    guard case .complete(_, _, let seen) = parse(head + "abc") else { Issue.record(); return }
    #expect(seen.body == "abc")
}

@Test func rejectsWhatItDoesNotTake() {
    let cases: [(String, UInt16)] = [
        ("GET\r\n\r\n", 400),
        ("G(T / HTTP/1.1\r\n\r\n", 400),
        ("GET  HTTP/1.1\r\n\r\n", 400),
        ("GET / HTTP/2.0\r\n\r\n", 400),
        ("GET /a\u{7F} HTTP/1.1\r\n\r\n", 400),
        ("GET / HTTP/1.1\r\nno colon\r\n\r\n", 400),
        ("GET / HTTP/1.1\r\nbad name: x\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", 400),
        ("POST / HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", 501),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 400),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n0\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n123456789\r\n", 400),
    ]
    for (text, status) in cases {
        #expect(parse(text) == .rejected(status), "\(text.debugDescription)")
    }
    // Repeated Content-Length headers that agree are fine.
    guard case .complete = parse("POST / HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nab") else {
        Issue.record(); return
    }
}

@Test func limits() {
    let limits = HTTP.Limits(head: 64, body: 8)
    #expect(parse("GET /" + String(repeating: "a", count: 80), limits: limits) == .rejected(431))
    #expect(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 60) + "\r\n\r\n", limits: limits)
        == .rejected(431))
    #expect(parse("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\n", limits: limits) == .rejected(413))
    #expect(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n4\r\n", limits: limits)
        == .rejected(413))
    guard case .complete(_, _, let seen) = parse("POST / HTTP/1.1\r\nContent-Length: 8\r\n\r\n12345678",
                                                   limits: limits) else { Issue.record(); return }
    #expect(seen.body == "12345678")
}

@Test func headerLookup() {
    let text = "GET / HTTP/1.1\r\nX-One: 1\r\nx-two:\t2 \r\nX-One: again\r\n\r\n"
    let bytes = Array(text.utf8)
    // The first of repeated headers; whitespace around a value trimmed; nil for one not sent.
    let parsed = HTTP.parse(bytes.span) { (request: borrowing HTTP.Request) -> [String?] in
        [optionalString(request.header("x-one")), optionalString(request.header("x-two")),
         optionalString(request.header("x-three"))]
    }
    guard case .complete(_, _, let values) = parsed else { Issue.record(); return }
    #expect(values == ["1", "2", nil])
}

@Test func responseHeads() {
    var out = ByteBuffer()
    HTTP.appendHead(&out, status: 200, contentLength: 12)
    HTTP.appendHead(&out, status: 404, contentType: "text/plain", contentLength: 0, close: true)
    let text = out.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n"
        + "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}
