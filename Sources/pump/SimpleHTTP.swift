import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tiny synchronous HTTP client for low-volume calls (auth command).
struct SimpleHTTP {

    struct Response {
        let status: Int
        let data: Data
        func jsonObject() -> Any? {
            try? JSONSerialization.jsonObject(with: data)
        }
    }

    func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60) -> Response {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession.makePumpSession()
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        var out: Response!
        session.dataTask(with: req) { data, resp, error in
            if let http = resp as? HTTPURLResponse {
                out = Response(status: http.statusCode, data: data ?? Data())
            } else {
                out = Response(status: -1, data: Data(("pump: " + (error?.localizedDescription ?? "unknown error")).utf8))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return out
    }

    func requestJSON(_ method: String, _ url: String, headers: [String: String] = [:], json: [String: Any]? = nil, timeout: TimeInterval = 60) -> Response {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return request(method, url, headers: headers, body: body, timeout: timeout)
    }
}

extension URLSession {
    static func makePumpSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
    }
}
