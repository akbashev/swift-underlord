import Buffers
import JWT
import Testing

private func bytes(_ buffer: borrowing ByteBuffer) -> [UInt8] {
    buffer.withUnsafeBytes { Array($0) }
}

private func encoded(_ data: [UInt8]) -> String {
    var out = ByteBuffer()
    Base64URL.encode(data.span, into: &out)
    return String(decoding: bytes(out), as: UTF8.self)
}

private func decoded(_ text: String) -> [UInt8]? {
    Base64URL.decode(Array(text.utf8).span)
}

@Test func base64URLVectors() {
    // RFC 4648 §10, with base64url's alphabet and no padding.
    let vectors = [("", ""), ("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"), ("foob", "Zm9vYg"), ("fooba", "Zm9vYmE"),
                   ("foobar", "Zm9vYmFy")]
    for (plain, text) in vectors {
        #expect(encoded(Array(plain.utf8)) == text)
        #expect(decoded(text) == Array(plain.utf8))
    }
    #expect(encoded([0xFB, 0xFF, 0xBF]) == "-_-_")
    // A length no encoding has, padding, the standard alphabet's + and /, bits past the last byte.
    for text in ["Z", "Zm9vY", "Zg==", "Zm9v+A", "Zm9v/A", "Zh", "Zm9"] { #expect(decoded(text) == nil, "\(text)") }
}

@Test func base64URLRoundTrips() {
    var generator = SystemRandomNumberGenerator()
    for count in 0..<100 {
        let data = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
        #expect(decoded(encoded(data)) == data)
    }
}

/// RFC 7515 appendix A.1: an HS256 token whose header has a line break in it, so it's read rather than matched.
@Test func rfc7515Example() throws {
    let key = try #require(decoded("AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"))
    let token = Array(("eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9"
        + ".eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"
        + ".dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk").utf8)
    let signer = HS256(secret: key.span)
    let before = signer.verify(token.span, now: 1_300_819_379) { String(decoding: $0.withUnsafeBufferPointer { Array($0) }, as: UTF8.self) }
    guard case .valid(let payload) = before else { Issue.record("\(before)"); return }
    #expect(payload.contains("\"iss\":\"joe\""))
    let at = signer.verify(token.span, now: 1_300_819_380) { _ in () }
    guard case .rejected(.expired) = at else { Issue.record("\(at)"); return }
}

private let signer = HS256(secret: Array("a secret for the tests".utf8).span)

private func token(_ payload: String) -> [UInt8] {
    var out = ByteBuffer()
    signer.appendToken(payload: Array(payload.utf8).span, to: &out)
    return bytes(out)
}

/// A token with any header, signed with `signer`.
private func token(header: String, payload: String) -> [UInt8] {
    var out = ByteBuffer()
    Base64URL.encode(Array(header.utf8).span, into: &out)
    out.append(0x2E)
    Base64URL.encode(Array(payload.utf8).span, into: &out)
    let tag = signer.signature(out.span)
    out.append(0x2E)
    Base64URL.encode(tag.span, into: &out)
    return bytes(out)
}

private func verdict(_ token: [UInt8], now: Double = 1_000, requireExpiry: Bool = true) -> String {
    switch signer.verify(token.span, now: now, requireExpiry: requireExpiry, { $0.count }) {
    case .valid(let count): "valid \(count)"
    case .rejected(let why): "\(why)"
    }
}

@Test func verifiesItsOwnTokens() {
    let payload = #"{"sub":"42","exp":2000,"nbf":500,"iat":400}"#
    #expect(verdict(token(payload)) == "valid \(payload.utf8.count)")
    // A payload too long for the stack buffer.
    let long = #"{"exp":2000,"pad":""# + String(repeating: "x", count: 1_000) + #""}"#
    #expect(verdict(token(long)) == "valid \(long.utf8.count)")
}

@Test func rejections() {
    let good = token(#"{"exp":2000}"#)
    var tampered = good
    tampered[tampered.firstIndex(of: 0x2E)! + 2] ^= 0x01
    #expect(verdict(tampered) == "badSignature")
    #expect(verdict(Array(good.dropLast())) == "badSignature")
    #expect(verdict(Array("a.b".utf8)) == "malformed")
    #expect(verdict(good + Array(".x".utf8)) == "malformed")
    #expect(verdict(token(header: #"{"alg":"none"}"#, payload: #"{"exp":2000}"#)) == "unsupportedAlgorithm")
    #expect(verdict(token(header: #"{"alg":"HS512"}"#, payload: #"{"exp":2000}"#)) == "unsupportedAlgorithm")
    #expect(verdict(token(header: #"{ "typ": "JWT", "alg": "HS256" }"#, payload: #"{"exp":2000}"#)) == "valid 12")
    #expect(verdict(token(#"{"exp":2000}"#), now: 2_000) == "expired")
    #expect(verdict(token(#"{"sub":"1"}"#)) == "missingExpiry")
    #expect(verdict(token(#"{"sub":"1"}"#), requireExpiry: false) == "valid 11")
    #expect(verdict(token(#"{"exp":2000,"nbf":1001}"#)) == "notYetValid")
    #expect(verdict(token(#"{"exp":"2000"}"#)) == "badClaim")
    #expect(verdict(token(#"{"exp":2000,"iat":"now"}"#)) == "badClaim")
    #expect(verdict(token(#"[1,2]"#)) == "malformed")
    #expect(verdict(token(#"{"exp":2000"#)) == "malformed")
}
