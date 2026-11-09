# ``JWT``

JSON Web Tokens signed with HS256, verified in place, and strict base64url.

## Overview

``HS256/verify(_:now:requireExpiry:_:)`` checks a compact token in the order that trusts the least first: three parts,
a matching signature (compared in constant time), `alg` HS256, then `exp`, `nbf` and `iat` against a clock the caller
passes. Only then is the decoded payload, on the stack for short tokens, handed to the caller to read its own claims.
The key's HMAC pads are hashed once, when the ``HS256`` is made.

```swift
let tokens = HS256(secret: Array(secret.utf8).span)
switch tokens.verify(token, now: now) { payload in JSON.scan(payload, keys: ["sub"]) } {
case .valid(let claims): ...
case .rejected(let why): ...
}
```

``Base64URL`` decodes strictly (no padding, no stray bits), so each byte string has exactly one accepted encoding.

## Topics

### Tokens

- ``HS256``
- ``HS256/Verdict``
- ``HS256/Rejection``

### Base64url

- ``Base64URL``
