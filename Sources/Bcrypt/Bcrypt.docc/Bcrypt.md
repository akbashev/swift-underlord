# ``Bcrypt``

bcrypt (`$2b$`), one hash at a time or several in lockstep.

## Overview

bcrypt's cost is its key schedule: thousands of rounds of dependent loads from four S-boxes. One hash leaves most of a
core's load ports idle; several hashed in lockstep, their key schedules interleaved, overlap their loads. A server that
gathers the sign-ups and log-ins of one turn and hashes them together gets more of them done per second.

``Bcrypt/calibration`` measures, on first use, how many lanes pay off on this machine.

```swift
let encoded = Bcrypt.hash(Array(password.utf8).span, cost: 10)
let ok = Bcrypt.verify(Array(password.utf8).span, encoded.span)

let many = Bcrypt.hash(passwords, cost: 10)   // in lockstep
```

## Topics

### One at a time

- ``Bcrypt/hash(_:cost:salt:)``
- ``Bcrypt/verify(_:_:)-(Span<UInt8>,Span<UInt8>)``
- ``Bcrypt/makeSalt()``

### Several in lockstep

- ``Bcrypt/hash(_:cost:)``
- ``Bcrypt/verify(_:)``
- ``Bcrypt/calibration``
