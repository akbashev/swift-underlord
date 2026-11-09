# ``HTTP``

HTTP/1.1 requests parsed in place, and response heads.

## Overview

``HTTP/parse(_:limits:_:)`` reads the request at the start of a connection's bytes and hands it, borrowed, to a closure:
the method, target, headers and body are `Span`s into the bytes the receive delivered, so nothing is copied but a
chunked body. It reports how many bytes the request took, so pipelined requests are parsed one after another from the
same buffer; a request not all there yet is ``HTTP/Parsed/incomplete(sendContinue:)``, with the
`Expect: 100-continue` handshake; a request it won't take is ``HTTP/Parsed/rejected(status:)`` with the status to
answer.

```swift
switch HTTP.parse(received) { request in route(request) } {
case .complete(let consumed, let keepAlive, let response): ...
case .incomplete(let sendContinue): ...
case .rejected(let status): ...
}
```

``HTTP/appendHead(_:status:contentType:contentLength:close:)`` writes a response head in one reservation.

## Topics

### Requests

- ``HTTP/parse(_:limits:_:)``
- ``HTTP/Request``
- ``HTTP/Parsed``
- ``HTTP/Limits``

### Responses

- ``HTTP/appendHead(_:status:contentType:contentLength:close:)``
- ``HTTP/statusText(_:)``
- ``HTTP/continueResponse``
