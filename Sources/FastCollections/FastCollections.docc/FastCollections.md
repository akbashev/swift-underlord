# ``FastCollections``

A hash index into the caller's own array of keys, a multiply hasher, and an unstable sort in place.

## Overview

Swift's `Dictionary` and `Set` always hash with SipHash, which guards against flooding with chosen keys; the standard
library's `sort` is a stable merge sort that calls its comparison through a closure. Both are the right defaults, and
both cost a server that builds small key sets and sorts small batches on every request.

``IndexTable`` maps a key's hash to its position in an array the caller already keeps, so a set or a map needs no second
copy of the keys; ``FastHasher`` hashes a word with one multiply. ``Swift/MutableSpan/sortUnstable(by:)`` and
``Swift/Array/sortUnstable(by:)`` sort in place with the comparison inlined into the caller.

Neither the hasher nor the table is for keys an attacker chooses.

## Topics

### Hashing

- ``IndexTable``
- ``FastHasher``
- ``FastHashable``

### Sorting

- ``Swift/MutableSpan``
- ``Swift/Array``
