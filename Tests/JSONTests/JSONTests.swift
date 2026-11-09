// `#expect` captures the parts of a call it checks, and a Span can't be captured: results go through locals, and
// spans are copied into arrays.
import Buffers
import JSON
import Testing

private func array(_ span: Span<UInt8>) -> [UInt8] {
    (0..<span.count).map { span[$0] }
}

private func written(_ text: String) -> String {
    var buffer = ByteBuffer()
    let utf8 = Array(text.utf8)
    JSON.writeString(&buffer, utf8.span)
    return buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
}

private func valid(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return JSON.isValid(bytes.span)
}

@Test func writesEscapesExactly() {
    #expect(written("plain") == "\"plain\"")
    #expect(written("say \"hi\"\\ok") == #""say \"hi\"\\ok""#)
    #expect(written("tab\there\nnew\rret") == #""tab\there\nnew\rret""#)
    #expect(written("\u{01}\u{1F}\u{7F}") == "\"\\u0001\\u001f\u{7F}\"")
    #expect(written("é ü 😀") == "\"é ü 😀\"")
}

@Test func escapesAtEveryChunkBoundary() {
    // A special byte at every position of strings long enough to use the 32- and 16-byte paths and the tail.
    for length in [1, 15, 16, 17, 31, 32, 33, 47, 48, 49, 64, 65, 100] {
        for position in 0..<length {
            var bytes = [UInt8](repeating: 0x61, count: length)
            bytes[position] = 0x22
            let text = String(decoding: bytes, as: UTF8.self)
            let expected = "\"" + String(repeating: "a", count: position) + "\\\""
                + String(repeating: "a", count: length - position - 1) + "\""
            #expect(written(text) == expected, "length \(length), quote at \(position)")
        }
    }
}

@Test func writesIntegers() {
    for value: Int64 in [0, 7, 10, 99, 100, 12345, -1, -987654321, .max, .min] {
        var buffer = ByteBuffer()
        JSON.writeInteger(&buffer, value)
        let text = buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        #expect(text == String(value))
    }
}

@Test func scanFindsMembersInPlace() throws {
    let document = Array(#"{"name":"ada","age":36,"tags":["x"],"nested":{"name":"inner"},"name":"lovelace","esc\u0061pe":"a\nb"}"#.utf8)
    let span = document.span
    let scanned = JSON.scan(span, keys: ["name", "age", "tags", "escape", "missing"])
    let fields = try #require(scanned)
    #expect(fields.isObject && !fields.hasNul)
    let name = try #require(fields[0])
    #expect(name.kind == .string)
    // The later duplicate wins, and the nested one doesn't count.
    let nameText = JSON.withString(span, name) { array($0) }
    #expect(nameText == Array("lovelace".utf8))
    let age = try #require(fields[1])
    let (ageInteger, ageNumber) = (JSON.integer(span, age), JSON.number(span, age))
    #expect(ageInteger == 36 && ageNumber == 36)
    #expect(fields[2]?.kind == .array)
    let escaped = try #require(fields[3])
    #expect(escaped.keyEscaped && escaped.valueEscaped)
    let escapedText = JSON.withString(span, escaped) { array($0) }
    #expect(escapedText == Array("a\nb".utf8))
    #expect(fields[4] == nil)
}

@Test func numbers() throws {
    let document = Array(#"{"a":-42,"b":3.5,"c":1e3,"d":9223372036854775807,"e":-9223372036854775808,"f":92233720368547758070}"#.utf8)
    let span = document.span
    let scanned = JSON.scan(span, keys: ["a", "b", "c", "d", "e", "f"])
    let f = try #require(scanned)
    let a = JSON.integer(span, f[0]!)
    let (bInteger, bNumber) = (JSON.integer(span, f[1]!), JSON.number(span, f[1]!))
    let c = JSON.number(span, f[2]!)
    let (d, e) = (JSON.integer(span, f[3]!), JSON.integer(span, f[4]!))
    let (fInteger, fNumber) = (JSON.integer(span, f[5]!), JSON.number(span, f[5]!))
    #expect(a == -42)
    #expect(bInteger == nil && bNumber == 3.5)
    #expect(c == 1000)
    #expect(d == .max && e == .min)
    #expect(fInteger == nil && fNumber == 9.223372036854775807e19)
}

@Test func unicodeEscapes() throws {
    let document = Array(#"{"s":"\u00e9\ud83d\ude00\u0000"}"#.utf8)
    let span = document.span
    let scanned = JSON.scan(span, keys: ["s"])
    let found = try #require(scanned)
    #expect(found.hasNul)
    let text = JSON.withString(span, found[0]!) { array($0) }
    #expect(text == Array("é😀\u{0}".utf8))
}

@Test func rejectsInvalidDocuments() {
    let invalid = [
        "", "{", "{\"a\":}", "{\"a\":1,}", "[1,]", "\"open", "{\"a\":\"\\x\"}", "{\"a\":\"\\ud800\"}",
        "{\"a\":\"\\udc00\"}", "01", "1.", "-", "tru", "nul", "{\"a\" 1}", "{} {}", "\"tab\there\"",
        String(repeating: "[", count: 65) + String(repeating: "]", count: 65),
    ]
    for text in invalid { #expect(!valid(text), "\(text.prefix(20))") }
    let notUTF8: [UInt8] = [0x22, 0xC3, 0x28, 0x22]
    let notUTF8Valid = JSON.isValid(notUTF8.span)
    #expect(!notUTF8Valid)
    let accepted = ["0", "-0.5e-3", "true", " null ", "[]", "{}", "[[[]]]", "\"\\u00e9\"",
                    String(repeating: "[", count: 64) + String(repeating: "]", count: 64)]
    for text in accepted { #expect(valid(text), "\(text.prefix(20))") }
}

@Test func roundTripsArbitraryText() throws {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let length = Int.random(in: 0..<120, using: &generator)
        let characters = (0..<length).map { _ -> Character in
            switch Int.random(in: 0..<10, using: &generator) {
            case 0: Character(Unicode.Scalar(UInt8.random(in: 0..<0x20, using: &generator)))
            case 1: "\""
            case 2: "\\"
            case 3: "é"
            default: Character(Unicode.Scalar(UInt8.random(in: 0x20..<0x7F, using: &generator)))
            }
        }
        let utf8 = Array(String(characters).utf8)
        var buffer = ByteBuffer()
        buffer.append("{\"v\":")
        JSON.writeString(&buffer, utf8.span)
        buffer.append("}")
        let document = buffer.withUnsafeBytes { Array($0) }
        let scanned = JSON.scan(document.span, keys: ["v"])
        let found = try #require(scanned)
        let text = JSON.withString(document.span, found[0]!) { array($0) }
        #expect(text == utf8)
    }
}
