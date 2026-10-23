import Foundation

#if canImport(Glibc)
import Glibc
#endif

struct IOError: Error { let op: String; let code: Int32 }

/// A parsed inbound HTTP request.
struct HTTPRequest {
    var method: String
    var path: String        // path without query
    var query: String       // raw query (no '?')
    var httpVersion: String
    var headers: [String: String]  // keys lowercased, duplicates joined with ", "
    var body: [UInt8]

    var keepAlive: Bool {
        let conn = headers["connection"]?.lowercased() ?? ""
        if httpVersion == "HTTP/1.0" { return conn.contains("keep-alive") }
        return !conn.contains("close")
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// One accepted client connection: buffered request reading and response
/// writing (Content-Length or chunked), keep-alive aware.
final class ClientConn {
    let fd: Int32
    private var buf: [UInt8] = []
    private(set) var broken = false

    /// Mark the connection unusable after a failed write from outside the
    /// request loop (e.g. streaming error paths).
    func markBroken() { broken = true }
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        #if canImport(Glibc)
        var tv = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    // MARK: reading

    /// Returns nil on clean EOF / idle timeout (between requests).
    func readRequest(maxHeaderBytes: Int = 65536, maxBodyBytes: Int = 64 * 1024 * 1024) throws -> HTTPRequest? {
        // Find end of headers.
        var headerEnd = findDoubleCRLF()
        while headerEnd < 0 {
            if buf.count > maxHeaderBytes { throw HTTPError(code: 431, message: "request header too large") }
            guard try fill() else { return nil }
            headerEnd = findDoubleCRLF()
        }

        let headBytes = Data(buf[0..<headerEnd])
        guard let headText = String(data: headBytes, encoding: .utf8) else {
            throw HTTPError(code: 400, message: "malformed request head")
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { throw HTTPError(code: 400, message: "malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[key] { headers[key] = existing + ", " + value } else { headers[key] = value }
        }

        let bodyStart = headerEnd + 4
        var body: [UInt8] = []
        let method = parts[0].uppercased()

        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            body = try readChunkedBody(maxBodyBytes: maxBodyBytes, consumedFrom: bodyStart)
        } else if let cl = headers["content-length"], let n = Int(cl) {
            guard n >= 0, n <= maxBodyBytes else { throw HTTPError(code: 413, message: "request body too large") }
            while buf.count < bodyStart + n { guard try fill() else { throw HTTPError(code: 400, message: "truncated request body") } }
            body = Array(buf[bodyStart..<(bodyStart + n)])
            buf.removeFirst(bodyStart + n)
        } else {
            buf.removeFirst(bodyStart)
        }

        let target = parts[1]
        var path = target
        var query = ""
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = String(target[target.index(after: q)...])
        }
        let version = parts[2].uppercased().hasPrefix("HTTP/") ? parts[2].uppercased() : "HTTP/1.1"
        return HTTPRequest(method: method, path: path, query: query, httpVersion: version, headers: headers, body: body)
    }

    private func readChunkedBody(maxBodyBytes: Int, consumedFrom: Int) throws -> [UInt8] {
        var cursor = consumedFrom
        var body: [UInt8] = []
        func take(_ n: Int) throws -> [UInt8] {
            while buf.count < cursor + n { guard try fill() else { throw HTTPError(code: 400, message: "truncated chunked body") } }
            let out = Array(buf[cursor..<(cursor + n)])
            cursor += n
            return out
        }
        chunkLoop: while true {
            // size line
            var lineEnd: Int
            while true {
                if let idx = firstCRLF(from: cursor) { lineEnd = idx; break }
                guard try fill() else { throw HTTPError(code: 400, message: "truncated chunk size") }
            }
            let sizeLine = String(bytes: try take(lineEnd - cursor), encoding: .utf8) ?? ""
            cursor += 2 // CRLF
            let sizeStr = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw HTTPError(code: 400, message: "bad chunk size")
            }
            if size == 0 { break chunkLoop }
            guard body.count + size <= maxBodyBytes else { throw HTTPError(code: 413, message: "request body too large") }
            body += try take(size)
            _ = try take(2) // trailing CRLF
        }
        // trailers until blank line
        while true {
            if buf.count >= cursor + 2, buf[cursor] == 13, buf[cursor + 1] == 10 { cursor += 2; break }
            if let idx = firstCRLF(from: cursor) { cursor = idx + 2; continue }
            guard try fill() else { break }
        }
        buf.removeFirst(cursor)
        return body
    }

    private func findDoubleCRLF() -> Int {
        guard buf.count >= 4 else { return -1 }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i+1] == 10 && buf[i+2] == 13 && buf[i+3] == 10 {
            return i
        }
        return -1
    }

    private func firstCRLF(from: Int) -> Int? {
        guard from + 1 < buf.count else { return nil }
        for i in from..<(buf.count - 1) where buf[i] == 13 && buf[i + 1] == 10 { return i }
        return nil
    }

    /// Append more bytes from the socket. Returns false on EOF/idle timeout.
    @discardableResult
    private func fill() throws -> Bool {
        var tmp = [UInt8](repeating: 0, count: 16384)
        let n = recv(fd, &tmp, tmp.count, 0)
        if n > 0 { buf.append(contentsOf: tmp[0..<n]); return true }
        if n == 0 { return false }
        if errno == EAGAIN || errno == EWOULDBLOCK { return false }
        if errno == EINTR { return true }
        return false // treat any other socket error as end of connection
    }

    // MARK: writing

    private func sendAll(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                let p = raw.baseAddress!.advanced(by: offset)
                #if canImport(Glibc)
                return send(fd, p, bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                return send(fd, p, bytes.count - offset, 0)
                #endif
            }
            if n <= 0 {
                if errno == EINTR { continue }
                broken = true
                throw IOError(op: "send", code: errno)
            }
            offset += n
        }
    }

    static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status \(code)"
        }
    }

    static func headBytes(status: Int, headers: [(String, String)], contentLength: Int?, chunked: Bool) -> [UInt8] {
        var out = "HTTP/1.1 \(status) \(reason(for: status))\r\n".utf8.map { UInt8($0) }
        for (k, v) in headers {
            out += "\(k): \(v)\r\n".utf8.map { UInt8($0) }
        }
        if chunked {
            out += "Transfer-Encoding: chunked\r\n".utf8.map { UInt8($0) }
        } else if let cl = contentLength {
            out += "Content-Length: \(cl)\r\n".utf8.map { UInt8($0) }
        }
        out += "\r\n".utf8.map { UInt8($0) }
        return out
    }

    /// Write a complete buffered response.
    func respond(status: Int, headers: [(String, String)], body: [UInt8], keepAlive: Bool) throws {
        let head = Self.headBytes(status: status, headers: headers, contentLength: body.count, chunked: false)
        try sendAll(head + body)
    }

    func respondText(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8", keepAlive: Bool = true) throws {
        try respond(
            status: status,
            headers: [("Content-Type", contentType), ("Connection", keepAlive ? "keep-alive" : "close")],
            body: Array(text.utf8),
            keepAlive: keepAlive
        )
    }

    func respondJSON(_ status: Int, _ object: Any, keepAlive: Bool = true) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try respond(
            status: status,
            headers: [("Content-Type", "application/json"), ("Connection", keepAlive ? "keep-alive" : "close")],
            body: Array(data),
            keepAlive: keepAlive
        )
    }

    /// Begin a streamed response. Either `contentLength` (raw framing) or
    /// `chunked` framing must be chosen by the caller.
    func beginStream(status: Int, headers: [(String, String)], contentLength: Int?, chunked: Bool) throws {
        try sendAll(Self.headBytes(status: status, headers: headers, contentLength: chunked ? nil : contentLength, chunked: chunked))
    }

    func writeRaw(_ bytes: [UInt8]) throws { try sendAll(bytes) }

    func writeChunk(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        var frame = String(format: "%x", bytes.count).utf8.map { UInt8($0) }
        frame += [13, 10]
        frame += bytes
        frame += [13, 10]
        try sendAll(frame)
    }

    func finishChunked() throws { try sendAll(Array("0\r\n\r\n".utf8)) }

    func close() {
        #if canImport(Glibc)
        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
        _ = Glibc.close(fd)
        #else
        _ = shutdown(fd, SHUT_RDWR)
        _ = close(fd)
        #endif
    }
}

struct HTTPError: Error { let code: Int; let message: String }

/// Minimal threaded HTTP/1.1 server over POSIX sockets.
final class HTTPServer {
    let host: String
    let port: UInt16
    let handler: (HTTPRequest, ClientConn) -> Void
    private var listenFD: Int32 = -1

    init(host: String, port: UInt16, handler: @escaping (HTTPRequest, ClientConn) -> Void) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    /// Blocks forever serving connections.
    func run() throws {
        #if canImport(Glibc)
        signal(SIGPIPE, SIG_IGN)
        #endif
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw IOError(op: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host == "0.0.0.0" || host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY
        } else {
            var inAddr = in_addr()
            guard inet_pton(AF_INET, host, &inAddr) == 1 else {
                throw IOError(op: "inet_pton(\(host))", code: errno)
            }
            addr.sin_addr = inAddr
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw IOError(op: "bind", code: errno) }
        guard listen(fd, 128) == 0 else { throw IOError(op: "listen", code: errno) }
        listenFD = fd
        Log.info("listening on http://\(host):\(port)")

        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                Log.err("accept failed (errno \(errno))")
                usleep(10_000)
                continue
            }
            let conn = ClientConn(fd: clientFD)
            let h = handler
            let thread = Thread {
                conn.serve(with: h)
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    func shutdown() {
        if listenFD >= 0 {
            #if canImport(Glibc)
            _ = Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
            _ = Glibc.close(listenFD)
            #else
            _ = shutdown(listenFD, SHUT_RDWR)
            _ = close(listenFD)
            #endif
        }
    }
}

extension ClientConn {
    /// Keep-alive request loop for one connection.
    func serve(with handler: (HTTPRequest, ClientConn) -> Void) {
        defer { close() }
        while true {
            guard let req = try? readRequest() else { return }
            handler(req, self)
            if broken || !req.keepAlive { return }
        }
    }
}
