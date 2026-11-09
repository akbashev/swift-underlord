// JSON Web Tokens signed with HMAC-SHA256 (RFC 7519, RFC 7515's HS256): verified in place, the signature first, the
// payload decoded onto the stack and its claims read without building anything. The key's HMAC pads are hashed
// once, so a token costs its own blocks plus one.
public import Buffers
import JSON
public import SHA256

/// Signs and verifies HS256 tokens with one secret.
public struct HS256: Sendable {
    private let mac: HMACSHA256

    public init(secret: Span<UInt8>) {
        mac = HMACSHA256(key: secret)
    }

    /// Why a token was turned down.
    public enum Rejection: Error, Sendable {
        /// Not three base64url parts, or a payload that isn't a JSON object.
        case malformed
        /// The signature doesn't match the header and payload.
        case badSignature
        /// The header's `alg` isn't `HS256`.
        case unsupportedAlgorithm
        /// No `exp` claim, and one is required.
        case missingExpiry
        /// `exp` has passed.
        case expired
        /// `nbf` hasn't come yet.
        case notYetValid
        /// `exp`, `nbf` or `iat` isn't a number.
        case badClaim
    }

    public enum Verdict<Value> {
        case valid(Value)
        case rejected(Rejection)
    }

    /// The signature of `signingInput`, the encoded header and payload joined by a dot.
    public func signature(_ signingInput: Span<UInt8>) -> SHA256.Digest {
        mac.authenticate(signingInput)
    }

    /// A token for `payload` (a JSON object), appended to `out`, under the header `{"alg":"HS256","typ":"JWT"}`.
    public func appendToken(payload: Span<UInt8>, to out: inout ByteBuffer) {
        let start = out.count
        out.append(Self.standardHeader)
        out.append(0x2E)
        Base64URL.encode(payload, into: &out)
        let tag = signature(out.span.extracting(start..<out.count))
        out.append(0x2E)
        Base64URL.encode(tag.span, into: &out)
    }

    /// Checks `token` and, when it is valid, hands its decoded payload (JSON, borrowed for the call) to `claims`.
    ///
    /// In order: three parts, a matching signature (compared in constant time, before anything else is trusted),
    /// `alg` HS256, then the registered claims against `now` (seconds since 1970): `exp` (required unless
    /// `requireExpiry` is false) must be later, `nbf` not later, and `iat` a number if it is there.
    public func verify<Value, E: Error>(
        _ token: Span<UInt8>, now: Double, requireExpiry: Bool = true,
        _ claims: (_ payload: Span<UInt8>) throws(E) -> Value
    ) throws(E) -> Verdict<Value> {
        guard let dot1 = Self.find(token, 0x2E, from: 0), let dot2 = Self.find(token, 0x2E, from: dot1 + 1),
              Self.find(token, 0x2E, from: dot2 + 1) == nil else { return .rejected(.malformed) }
        let header = token.extracting(0..<dot1)
        let payloadText = token.extracting((dot1 + 1)..<dot2)

        var tag = InlineArray<32, UInt8>(repeating: 0)
        var tagSpan = tag.mutableSpan
        guard Base64URL.decode(token.extracting((dot2 + 1)..<token.count), into: &tagSpan) == 32 else {
            return .rejected(.badSignature)
        }
        guard Self.equalInConstantTime(signature(token.extracting(0..<dot2)), tag) else {
            return .rejected(.badSignature)
        }
        guard Self.isHS256(header) else { return .rejected(.unsupportedAlgorithm) }

        // The payload on the stack when it's short (most are), on the heap otherwise.
        if payloadText.count <= 680 {
            var payload = InlineArray<512, UInt8>(repeating: 0)
            var payloadSpan = payload.mutableSpan
            guard let n = Base64URL.decode(payloadText, into: &payloadSpan) else { return .rejected(.malformed) }
            return try Self.checked(payload.span.extracting(0..<n), now: now, requireExpiry: requireExpiry, claims)
        }
        guard let payload = Base64URL.decode(payloadText) else { return .rejected(.malformed) }
        return try Self.checked(payload.span, now: now, requireExpiry: requireExpiry, claims)
    }

    /// `{"alg":"HS256","typ":"JWT"}`, and the other two spellings most libraries write, compared as they are.
    static let standardHeader: StaticString = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    static let reorderedHeader: StaticString = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
    static let minimalHeader: StaticString = "eyJhbGciOiJIUzI1NiJ9"

    /// Whether the header says `"alg":"HS256"`: the usual spellings compared as text, any other decoded and read.
    static func isHS256(_ header: Span<UInt8>) -> Bool {
        if equal(header, standardHeader) || equal(header, reorderedHeader) || equal(header, minimalHeader) { return true }
        guard header.count <= 340 else { return false }
        var bytes = InlineArray<256, UInt8>(repeating: 0)
        var span = bytes.mutableSpan
        guard let n = Base64URL.decode(header, into: &span) else { return false }
        let json = bytes.span.extracting(0..<n)
        guard let fields = JSON.scan(json, keys: ["alg"]), fields.isObject, let alg = fields[0], alg.kind == .string else {
            return false
        }
        return JSON.withString(json, alg) { equal($0, "HS256") }
    }

    /// The registered claims checked, then the payload handed on.
    static func checked<Value, E: Error>(
        _ payload: Span<UInt8>, now: Double, requireExpiry: Bool, _ claims: (Span<UInt8>) throws(E) -> Value
    ) throws(E) -> Verdict<Value> {
        guard let fields = JSON.scan(payload, keys: ["exp", "nbf", "iat"]), fields.isObject else {
            return .rejected(.malformed)
        }
        if let exp = fields[0] {
            guard exp.kind == .number, let expires = JSON.number(payload, exp) else { return .rejected(.badClaim) }
            guard now < expires else { return .rejected(.expired) }
        } else if requireExpiry {
            return .rejected(.missingExpiry)
        }
        if let nbf = fields[1] {
            guard nbf.kind == .number, let notBefore = JSON.number(payload, nbf) else { return .rejected(.badClaim) }
            guard now >= notBefore else { return .rejected(.notYetValid) }
        }
        if let iat = fields[2], iat.kind != .number { return .rejected(.badClaim) }
        return .valid(try claims(payload))
    }

    @inline(__always) static func equalInConstantTime(_ a: SHA256.Digest, _ b: InlineArray<32, UInt8>) -> Bool {
        var difference: UInt8 = 0
        for i in 0..<32 { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    @inline(__always) static func find(_ bytes: Span<UInt8>, _ byte: UInt8, from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }

    @inline(__always) static func equal(_ bytes: Span<UInt8>, _ text: StaticString) -> Bool {
        guard bytes.count == text.utf8CodeUnitCount else { return false }
        let t = text.utf8Start
        for i in 0..<bytes.count where bytes[i] != t[i] { return false }
        return true
    }
}
