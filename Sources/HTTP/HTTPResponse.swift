// Response heads: the status line, Content-Type, Content-Length and, when the connection ends, Connection: close,
// written in one reservation.
public import Buffers

extension HTTP {
    /// The interim response a client sending `Expect: 100-continue` waits for before its body.
    public static let continueResponse: StaticString = "HTTP/1.1 100 Continue\r\n\r\n"

    /// The status code and its reason phrase, as the status line has them.
    public static func statusText(_ status: UInt16) -> StaticString {
        switch status {
        case 100: "100 Continue"
        case 200: "200 OK"
        case 201: "201 Created"
        case 204: "204 No Content"
        case 301: "301 Moved Permanently"
        case 302: "302 Found"
        case 304: "304 Not Modified"
        case 400: "400 Bad Request"
        case 401: "401 Unauthorized"
        case 403: "403 Forbidden"
        case 404: "404 Not Found"
        case 405: "405 Method Not Allowed"
        case 409: "409 Conflict"
        case 413: "413 Content Too Large"
        case 422: "422 Unprocessable Content"
        case 429: "429 Too Many Requests"
        case 431: "431 Request Header Fields Too Large"
        case 501: "501 Not Implemented"
        case 503: "503 Service Unavailable"
        default: "500 Internal Server Error"
        }
    }

    /// A response head for a body of `contentLength` bytes, appended to `out`; with `close`, it tells the client the
    /// connection ends after it. A status this module has no phrase for is written as 500.
    @inlinable public static func appendHead(_ out: inout ByteBuffer, status: UInt16,
                                              contentType: StaticString = "application/json", contentLength: Int,
                                              close: Bool = false) {
        // The fixed text, the longest phrase (36 bytes), the content type and 20 digits.
        out.append(maximum: 140 + contentType.utf8CodeUnitCount) { head in
            if status == 200 {
                head.appendLiteral("HTTP/1.1 200 OK\r\nContent-Type: ")
            } else {
                head.appendLiteral("HTTP/1.1 ")
                head.appendLiteral(statusText(status))
                head.appendLiteral("\r\nContent-Type: ")
            }
            head.appendLiteral(contentType)
            head.appendLiteral("\r\nContent-Length: ")
            head.appendDecimal(Int64(contentLength))
            head.appendLiteral(close ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n")
        }
    }
}
