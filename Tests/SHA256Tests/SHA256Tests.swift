// FIPS 180-2's examples, RFC 4231's HMAC test cases, and the SHA-extension path against the portable one.
@testable import SHA256
import Testing

private func hex(_ d: SHA256.Digest) -> String {
    var s = ""
    for i in 0..<32 { s += String(d[i] >> 4, radix: 16) + String(d[i] & 15, radix: 16) }
    return s
}

private func sha(_ bytes: [UInt8]) -> String { hex(SHA256.hash(bytes.span)) }
private func hmac(_ key: [UInt8], _ data: [UInt8]) -> String { hex(HMACSHA256(key: key.span).authenticate(data.span)) }

@Test func fipsExamples() {
    #expect(sha([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(sha(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(sha(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(sha([UInt8](repeating: 0x61, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test func hasherMatchesOneShot() {
    let message = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) }
    for n in [0, 1, 55, 56, 63, 64, 65, 200, 1000] {
        let whole = sha(Array(message.prefix(n)))
        for piece in [1, 7, 63, 64, 65, 300] {
            var hasher = SHA256.Hasher()
            var at = 0
            while at < n {
                let part = Array(message[at..<min(at + piece, n)])
                hasher.update(part.span)
                at += part.count
            }
            let digest = hex(hasher.finalize())
            #expect(digest == whole, "\(n) bytes in pieces of \(piece)")
        }
    }
}

@Test func rfc4231() {
    #expect(hmac([UInt8](repeating: 0x0B, count: 20), Array("Hi There".utf8))
        == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    #expect(hmac(Array("Jefe".utf8), Array("what do ya want for nothing?".utf8))
        == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    #expect(hmac([UInt8](repeating: 0xAA, count: 20), [UInt8](repeating: 0xDD, count: 50))
        == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    #expect(hmac(Array(1...25), [UInt8](repeating: 0xCD, count: 50))
        == "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
    #expect(hmac([UInt8](repeating: 0xAA, count: 131), Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))
        == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    let long = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
    #expect(hmac([UInt8](repeating: 0xAA, count: 131), Array(long.utf8))
        == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
}

@Test func extensionsAgreeWithPortable() {
    print("SHA256 on extensions: \(SHA256.usesExtensions)")
    // Only meaningful where the CPU has SHA-NI; elsewhere both runs take the portable path.
    for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 1000, 4099] {
        let message = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }
        let fast = SHA256.hash(from: SHA256.initialState, priorBytes: 0, message.span, extensions: SHA256.usesExtensions)
        let portable = SHA256.hash(from: SHA256.initialState, priorBytes: 0, message.span, extensions: false)
        for i in 0..<8 { #expect(fast[i] == portable[i], "length \(n)") }
    }
}
