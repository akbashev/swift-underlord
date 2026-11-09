// crypt_blowfish's test vectors (OpenWall), the prefixes bcrypt hashes come with, and lockstep batches against single
// hashes.
@testable import Bcrypt
import Testing

private let vectors: [(password: String, hash: String)] = [
    ("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
    ("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
    ("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"),
    ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored",
     "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"),
    ("", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy"),
]

/// `Bcrypt.verify` on arrays (`#expect` can't capture the `Span`s it takes).
private func verifies(_ password: [UInt8], _ hash: [UInt8]) -> Bool { Bcrypt.verify(password.span, hash.span) }

@Test func knownVectors() {
    for v in vectors {
        let password = Array(v.password.utf8), hash = Array(v.hash.utf8)
        #expect(verifies(password, hash), "\(v.hash)")
        // The same digest under $2b$ and $2y$.
        for prefix: UInt8 in [0x62, 0x79] {
            var other = hash
            other[2] = prefix
            #expect(verifies(password, other))
        }
        // A different first byte (a byte past the 72nd would be ignored, as bcrypt does).
        let wrong = password.isEmpty ? [0x21] : [password[0] ^ 1] + password.dropFirst()
        #expect(!verifies(wrong, hash))
    }
}

@Test func hashThenVerify() {
    let password = Array("correct horse battery staple".utf8)
    let hash = Bcrypt.hash(password.span, cost: 6)
    #expect(hash.count == 60 && hash.starts(with: Array("$2b$06$".utf8)))
    #expect(verifies(password, hash))
    #expect(!verifies(Array("correct horse battery stapler".utf8), hash))
}

@Test func malformedHashes() {
    let password = Array("x".utf8)
    for bad in ["", "$2a$05$short", "$2c$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
                "$2a$99$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
                "$2a$05$CCCCCCCCCCCCCCCCCCCCC!E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"] {
        #expect(!verifies(password, Array(bad.utf8)), "\(bad)")
    }
}

@Test func lockstepMatchesOneAtATime() {
    // More passwords than any lockstep width, so groups of every size up to it run.
    let passwords = (0..<13).map { Array("password \($0)".utf8) }
    let hashes = Bcrypt.hash(passwords, cost: 5)
    for (password, hash) in zip(passwords, hashes) { #expect(verifies(password, hash)) }
    var pairs = zip(passwords, hashes).map { (password: $0, encoded: $1) }
    pairs[3].password = Array("wrong".utf8)
    pairs[7].encoded = Array("not a hash".utf8)
    pairs.append((Array(vectors[0].password.utf8), Array(vectors[0].hash.utf8)))
    let results = Bcrypt.verify(pairs)
    #expect(results == pairs.indices.map { $0 != 3 && $0 != 7 })
}

@Test func calibrationChoseSomething() {
    let c = Bcrypt.calibration
    #expect((1...6).contains(c.lanes) && c.microsecondsPerHash > 0 && ["constant", "shrx"].contains(c.kernelName))
}
