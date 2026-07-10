import Foundation
import Testing

@testable import PenBoard

/// C2/C3 (Feature 2 MVP): golden-byte + parser tests for the MJPEG wire
/// format shared by `ScreenStreamer`'s consumer (A5's `MJPEGServer`). Pure
/// (Foundation only), so these run without a socket, a display, or TCC.
struct MJPEGWireTests {

    // MARK: responseHeader / notFoundResponse (golden bytes, exact CRLF layout)

    @Test func responseHeaderGoldenBytes() {
        let expected = Data(
            (
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: multipart/x-mixed-replace; boundary=pbframe\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n"
                    + "\r\n"
            ).utf8
        )
        #expect(MJPEGWire.responseHeader() == expected)
    }

    @Test func notFoundResponseGoldenBytes() {
        let expected = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
        #expect(MJPEGWire.notFoundResponse() == expected)
    }

    // MARK: part(jpeg:) (golden bytes, exact CRLF layout)

    @Test func partGoldenBytesForThreeByteFakeJPEG() {
        let fakeJPEG = Data([0xFF, 0xD8, 0xD9]) // not a real JPEG — byte-layout test only
        var expected = Data("--pbframe\r\n".utf8)
        expected.append(Data("Content-Type: image/jpeg\r\n".utf8))
        expected.append(Data("Content-Length: 3\r\n".utf8))
        expected.append(Data("\r\n".utf8))
        expected.append(fakeJPEG)
        expected.append(Data("\r\n".utf8))

        #expect(MJPEGWire.part(jpeg: fakeJPEG) == expected)
    }

    @Test func consecutivePartsConcatenateIntoAValidStream() {
        // C3: each part is self-terminating — concatenation needs nothing
        // extra between parts, and the next part's boundary line starts
        // immediately after the previous part's trailing \r\n.
        let first = MJPEGWire.part(jpeg: Data([0x01]))
        let second = MJPEGWire.part(jpeg: Data([0x02]))
        let combined = first + second
        let secondStart = combined.index(combined.startIndex, offsetBy: first.count)
        #expect(combined[secondStart...].starts(with: Data("--pbframe\r\n".utf8)))
    }

    // MARK: requestPath (request-line parser)

    @Test func requestPathValidGETRequest() {
        let request = Data("GET /stream/abc123 HTTP/1.1\r\nHost: mac.local\r\n\r\n".utf8)
        #expect(MJPEGWire.requestPath(from: request) == "/stream/abc123")
    }

    @Test func requestPathToleratesTrailingHeadersAfterRequestLine() {
        let request = Data(
            "GET /stream/abc123 HTTP/1.1\r\nUser-Agent: test\r\nAccept: */*\r\n\r\n".utf8
        )
        #expect(MJPEGWire.requestPath(from: request) == "/stream/abc123")
    }

    @Test func requestPathWrongPathStillParsesButWontMatch() {
        // requestPath only parses the request line — rejecting a technically
        // well-formed but wrong path is pathMatches's job (below).
        let request = Data("GET /other/path HTTP/1.1\r\n\r\n".utf8)
        #expect(MJPEGWire.requestPath(from: request) == "/other/path")
        #expect(MJPEGWire.pathMatches(path: "/other/path", token: "abc123") == false)
    }

    @Test func requestPathWrongMethodRejected() {
        let request = Data("POST /stream/abc123 HTTP/1.1\r\n\r\n".utf8)
        #expect(MJPEGWire.requestPath(from: request) == nil)
    }

    @Test func requestPathGarbageRejected() {
        let request = Data("this is not a request line at all\r\n\r\n".utf8)
        #expect(MJPEGWire.requestPath(from: request) == nil)
    }

    @Test func requestPathBinaryGarbageWithNoNewlineRejected() {
        let request = Data([0x00, 0xFF, 0x10, 0x20, 0x01, 0x02])
        #expect(MJPEGWire.requestPath(from: request) == nil)
    }

    @Test func requestPathOversizedLineWithNoCRLFWithinBoundRejected() {
        // No CRLF anywhere within maxLineLength -> bounded scan finds nothing.
        let request = Data(String(repeating: "A", count: MJPEGWire.maxLineLength + 100).utf8)
        #expect(MJPEGWire.requestPath(from: request) == nil)
    }

    @Test func requestPathEmptyBufferRejected() {
        #expect(MJPEGWire.requestPath(from: Data()) == nil)
    }

    // MARK: pathMatches (case-sensitive token match, C2/C3)

    @Test func pathMatchesExactTokenOnly() {
        #expect(MJPEGWire.pathMatches(path: "/stream/abc123", token: "abc123") == true)
        #expect(MJPEGWire.pathMatches(path: "/stream/ABC123", token: "abc123") == false) // case-sensitive
        #expect(MJPEGWire.pathMatches(path: "/stream/abc123/", token: "abc123") == false)
        #expect(MJPEGWire.pathMatches(path: "/stream/wrong", token: "abc123") == false)
    }

    // MARK: makeToken (C2: 32 lowercase hex chars, CSPRNG)

    @Test func makeTokenIsThirtyTwoLowercaseHexChars() {
        let token = MJPEGWire.makeToken()
        #expect(token.count == 32)
        #expect(token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    @Test func makeTokenUniquenessSmoke() {
        let tokens = (0..<20).map { _ in MJPEGWire.makeToken() }
        #expect(Set(tokens).count == tokens.count)
    }
}
