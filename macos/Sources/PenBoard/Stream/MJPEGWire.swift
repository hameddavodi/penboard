import Foundation

/// C2/C3 (Feature 2 MVP): the exact byte-for-byte MJPEG-over-HTTP wire format
/// shared by `ScreenStreamer`'s consumer (`MJPEGServer`, A5) — plus the tiny
/// request-line parser and token helpers the server needs. Pure (Foundation
/// only, no Network/ScreenCaptureKit) so it's unit-testable without a socket
/// or a display, same split as `CoordinateMapper`/`DisplaySelection`.
enum MJPEGWire {

    /// C3: fixed multipart boundary name.
    static let boundary = "pbframe"

    /// C3: exact response header bytes for a matched `/stream/{tok}` request
    /// (CRLF line endings, blank line terminating the header block per HTTP).
    /// Sent once, immediately followed by the first `part(jpeg:)`.
    static func responseHeader() -> Data {
        let text =
            "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        return Data(text.utf8)
    }

    /// C3: any other method/path/token gets this and the connection is closed
    /// immediately — no body. Byte layout isn't pinned by C3 (only the 200
    /// path is), so this is just a minimal, valid HTTP error response.
    static func notFoundResponse() -> Data {
        Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
    }

    /// C3: one multipart frame part. Self-terminating (ends with `\r\n`), so
    /// concatenating consecutive parts already produces a valid stream — the
    /// next part's leading `--pbframe` needs nothing extra before it.
    static func part(jpeg: Data) -> Data {
        var data = Data("--\(boundary)\r\n".utf8)
        data.append(Data("Content-Type: image/jpeg\r\n".utf8))
        data.append(Data("Content-Length: \(jpeg.count)\r\n".utf8))
        data.append(Data("\r\n".utf8))
        data.append(jpeg)
        data.append(Data("\r\n".utf8))
        return data
    }

    /// C3: request-line parser bound (only the first `maxLineLength` bytes
    /// are ever scanned) — a client can never force an unbounded scan by
    /// withholding a CRLF.
    static let maxLineLength = 2048

    /// Extracts the path from a `GET {path} HTTP/1.1` request line. Tolerant
    /// of trailing headers (anything after the first CRLF is never parsed —
    /// this only ever looks at the request line itself). Returns nil for
    /// anything that isn't a well-formed GET request line (wrong method,
    /// garbage, or no CRLF found within the bound) — C3 treats all of those
    /// identically to a wrong path (404 + close). A syntactically valid GET
    /// request line with the WRONG path still returns that path — rejecting
    /// it is `pathMatches`'s job, not this parser's.
    static func requestPath(from data: Data) -> String? {
        let bounded = data.prefix(maxLineLength)
        guard let newlineIndex = bounded.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        var lineData = bounded[..<newlineIndex]
        if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
        guard let line = String(data: lineData, encoding: .utf8) else { return nil }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/") else { return nil }
        return String(parts[1])
    }

    /// C2/C3: token match is case-sensitive.
    static func pathMatches(path: String, token: String) -> Bool {
        path == "/stream/\(token)"
    }

    /// C2: 128-bit token, 32 lowercase hex chars, from the system CSPRNG.
    /// `Int/UInt.random(in:)` uses `SystemRandomNumberGenerator`, which on
    /// Darwin is backed by `arc4random_buf` — a CSPRNG, not just any PRNG.
    static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
