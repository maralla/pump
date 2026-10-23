import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streams upstream HTTP responses through to a client connection.
///
/// Per attempt a `StreamState` is registered for the task. Sequence:
///   1. handler starts the task, waits on the state's condition for the
///      response head (or completion, e.g. connect failure);
///   2. handler inspects status — may abort + retry (auth refresh) before
///      anything was written to the client;
///   3. handler writes the response head itself (choosing Content-Length vs
///      chunked framing), then marks headersSent;
///   4. data delegate callbacks, gated on headersSent, stream through as they
///      arrive; didComplete releases the handler, which sends the chunked
///      terminator if needed.
final class UpstreamClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class StreamState {
        let cond = NSCondition()
        var gotResponse = false
        var headersSent = false
        var aborted = false
        var completed = false
        var status = 0
        var upstreamHeaders: [(String, String)] = []
        var expectedLength: Int64 = -1
        var errorMessage: String?
        var bytesDown = 0
        let startedAt = Date()

        // set by the handler once framing is decided
        weak var conn: ClientConn?
        var chunked = false
        weak var task: URLSessionDataTask?

        /// Wait until the response head arrived or the attempt completed.
        func awaitHeadOrCompletion() {
            cond.lock()
            while !gotResponse && !completed { cond.wait() }
            cond.unlock()
        }

        func awaitCompletion() {
            cond.lock()
            while !completed { cond.wait() }
            cond.unlock()
        }

        func abort() {
            cond.lock()
            aborted = true
            cond.broadcast()
            cond.unlock()
            task?.cancel()
        }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var streams: [ObjectIdentifier: StreamState] = [:]

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(method: String, url: String, headers: [(String, String)], body: [UInt8], conn: ClientConn) -> StreamState {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if !body.isEmpty { req.httpBody = Data(body) }

        let state = StreamState()
        let task = session.dataTask(with: req)
        state.conn = conn
        state.task = task
        lock.lock(); streams[ObjectIdentifier(task)] = state; lock.unlock()
        task.resume()
        return state
    }

    // MARK: delegate plumbing

    private func state(for task: URLSessionTask) -> StreamState? {
        lock.lock(); defer { lock.unlock() }
        return streams[ObjectIdentifier(task)]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let state = state(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        state.cond.lock()
        state.status = http.statusCode
        state.expectedLength = http.expectedContentLength
        var hs: [(String, String)] = []
        for (k, v) in http.allHeaderFields {
            hs.append((String(describing: k).lowercased(), String(describing: v)))
        }
        state.upstreamHeaders = hs
        state.gotResponse = true
        state.cond.broadcast()
        state.cond.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        state.cond.lock()
        while !state.headersSent && !state.aborted { state.cond.wait() }
        let send = state.headersSent && !state.aborted
        let chunked = state.chunked
        let conn = state.conn
        state.cond.unlock()
        guard send, let conn = conn else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = [UInt8](raw)
            state.cond.lock()
            state.bytesDown += bytes.count
            state.cond.unlock()
            if chunked {
                try? conn.writeChunk(bytes)
            } else {
                try? conn.writeRaw(bytes)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = state(for: task) else { return }
        state.cond.lock()
        state.completed = true
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            state.errorMessage = error.localizedDescription
        }
        state.cond.broadcast()
        state.cond.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)  // surface redirects instead of silently following
    }
}
