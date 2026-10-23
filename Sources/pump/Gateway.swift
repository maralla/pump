import Foundation

/// Local API flavors and their canonical local paths.
enum APIFlavor {
    /// normalized local path → flavor name
    static let routes: [String: String] = [
        "/chat/completions": "openai-chat",
        "/completions": "openai-completions",
        "/messages": "anthropic-messages",
        "/responses": "openai-responses",
        "/embeddings": "embeddings",
    ]

    /// Strip a single leading /v1 (so /v1/chat/completions == /chat/completions).
    static func normalize(_ path: String) -> String {
        if path == "/v1" || path == "/v1/" { return "/models" }
        if path.hasPrefix("/v1/") { return String(path.dropFirst(3)) }
        return path
    }
}

/// Builds an upstream request from an EndpointConfig and the client request.
/// All endpoint specifics (paths, model header, auth headers) come from
/// configuration.
enum Gateway {
    struct Built {
        var url: String
        var headers: [(String, String)]
        var body: [UInt8]
        var model: String?
    }

    /// Headers dropped from the client request before proxying.
    private static let droppedRequestHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        "authorization", "x-api-key", "cookie", "accept-encoding",
    ]

    static func build(
        endpoint: EndpointConfig,
        localPath: String,
        query: String,
        clientHeaders: [String: String],
        body: [UInt8],
        authHeaders: [(String, String)]
    ) -> Built? {
        let norm = APIFlavor.normalize(localPath)
        guard let upstreamPath = endpoint.apiPaths[APIFlavor.routes[norm] ?? ""] ?? (endpoint.passthrough ? norm : nil) else {
            return nil
        }

        // Peek at the body for the model field (used for routing header and logs).
        var model: String?
        if !body.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
           let requested = obj["model"] as? String {
            model = requested
        }
        // Passthrough paths carry the model in the URL (Google-style
        // /models/<id>:<action>); extract it so model-call logs stay uniform.
        if model == nil, upstreamPath.hasPrefix("/models/") {
            let rest = upstreamPath.dropFirst("/models/".count)
            if let id = rest.split(separator: ":").first.map(String.init), !id.isEmpty {
                model = id
            }
        }

        var hs: [(String, String)] = []
        for (k, v) in clientHeaders {
            if droppedRequestHeaders.contains(k) { continue }
            if k.hasPrefix("access-control-") { continue }
            if k == endpoint.modelHeader?.lowercased() { continue }  // re-added below
            hs.append((k, v))
        }
        // Model routing header, when the endpoint declares one: explicit
        // client value wins over the body model.
        if let header = endpoint.modelHeader, !header.isEmpty {
            let clientValue = clientHeaders[header.lowercased()]
            if let cv = clientValue, !cv.isEmpty {
                hs.append((header, cv))
            } else if let m = model {
                hs.append((header, m))
            }
        }
        // Auth headers, resolved by the endpoint's AuthProvider.
        hs.append(contentsOf: authHeaders)
        hs.append(("Content-Type", "application/json"))
        hs.append(("User-Agent", "pump/\(PUMP_VERSION)"))

        var url = endpoint.baseUrl + upstreamPath
        if !query.isEmpty { url += "?" + query }
        return Built(url: url, headers: hs, body: body, model: model)
    }

    /// Response headers to forward to the client. Hop-by-hop and framing
    /// headers are dropped (pump reframes); the body is forwarded decoded, so
    /// `content-encoding` is dropped too. Everything else — including any
    /// provider-specific headers — passes.
    static func clientResponseHeaders(from upstream: [(String, String)]) -> [(String, String)] {
        let dropped: Set<String> = [
            "connection", "keep-alive", "transfer-encoding", "content-length",
            "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization",
            "date", "server", "content-type",  // re-added from upstream value below
            "content-encoding",                 // body is forwarded decoded
        ]
        var out: [(String, String)] = [("Access-Control-Allow-Origin", "*")]
        var contentType: String?
        for (k, v) in upstream {
            if dropped.contains(k) { if k == "content-type" { contentType = v }; continue }
            if k.hasPrefix("access-control-") { continue }
            out.append((k, v))
        }
        out.append(("Content-Type", contentType ?? "application/json"))
        return out
    }
}
