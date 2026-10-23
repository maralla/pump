import Foundation

/// One configured endpoint wired to its runtime pieces.
final class RunningEndpoint {
    let config: EndpointConfig
    let auth: AuthProvider

    init(config: EndpointConfig) {
        self.config = config
        self.auth = AuthProvider(endpointName: config.name, auth: config.auth ?? EndpointConfig.AuthConfig())
    }
}

/// Request routing for serve mode: local standard-API surface in front of the
/// configured endpoints, with on-demand auth and one retry on auth failure.
/// The first endpoint declaring a flavor serves it.
final class ProxyHandlers {
    let config: Config
    let endpoints: [RunningEndpoint]
    let upstream: UpstreamClient

    init(config: Config, endpoints: [RunningEndpoint], upstream: UpstreamClient) {
        self.config = config
        self.endpoints = endpoints
        self.upstream = upstream
    }

    func handle(_ req: HTTPRequest, _ conn: ClientConn) {
        let startedAt = Date()
        let norm = APIFlavor.normalize(req.path)

        // CORS preflight
        if req.method == "OPTIONS" {
            let _ = try? conn.respond(
                status: 204,
                headers: [
                    ("Access-Control-Allow-Origin", "*"),
                    ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                    ("Access-Control-Allow-Headers", "*"),
                    ("Access-Control-Max-Age", "86400"),
                ],
                body: [],
                keepAlive: true
            )
            return
        }

        switch (req.method, norm) {
        case ("GET", "/"), ("GET", "/health"):
            let _ = try? conn.respondJSON(200, ["status": "ok", "service": "pump", "version": PUMP_VERSION])
        case ("POST", let p) where APIFlavor.routes[p] != nil:
            route(req, conn, flavor: APIFlavor.routes[p]!, passthroughPath: nil, startedAt: startedAt)
        case ("POST", let p):
            // Unknown POST path → raw passthrough on endpoints that allow it.
            route(req, conn, flavor: "", passthroughPath: p, startedAt: startedAt)
        default:
            respondError(conn, 404, "no route for \(req.method) \(req.path)", label: "\(req.method) \(req.path)", startedAt: startedAt)
        }
    }

    // MARK: endpoint selection

    private func pick(flavor: String, passthroughPath: String?) throws -> RunningEndpoint {
        let candidates: [RunningEndpoint]
        if let path = passthroughPath {
            candidates = endpoints.filter { $0.config.passthrough }
            if candidates.isEmpty {
                throw PumpError("no configured endpoint allows passthrough for \(path)")
            }
        } else {
            candidates = endpoints.filter { $0.config.apiPaths[flavor] != nil }
            if candidates.isEmpty {
                throw PumpError("no configured endpoint declares apiPaths for \"\(flavor)\"")
            }
        }
        return candidates[0]
    }

    // MARK: proxying

    private func route(_ req: HTTPRequest, _ conn: ClientConn, flavor: String, passthroughPath: String?, startedAt: Date) {
        let ep: RunningEndpoint
        do {
            ep = try pick(flavor: flavor, passthroughPath: passthroughPath)
        } catch {
            respondError(conn, 404, "\(error)", label: "\(req.method) \(req.path)", startedAt: startedAt)
            return
        }

        // Auth (on demand — may run the configured auth command).
        var acquired: AuthProvider.Resolved
        do {
            acquired = try ep.auth.acquire()
        } catch {
            respondError(conn, 502, "\(error)", label: "\(req.method) \(req.path)", startedAt: startedAt)
            return
        }

        var attempt = 0
        while true {
            attempt += 1
            guard let built = Gateway.build(
                endpoint: ep.config,
                localPath: passthroughPath ?? req.path,
                query: req.query,
                clientHeaders: req.headers,
                body: req.body,
                authHeaders: acquired.headers
            ) else {
                respondError(conn, 404, "endpoint \(ep.config.name) does not map \(req.path)", label: "\(req.method) \(req.path)", startedAt: startedAt)
                return
            }

            let state = upstream.start(
                method: req.method,
                url: built.url,
                headers: built.headers,
                body: built.body,
                conn: conn
            )
            state.awaitHeadOrCompletion()

            // Connect-level failure before any response head?
            if state.errorMessage != nil && state.status == 0 {
                _ = try? conn.respondJSON(502, [
                    "error": ["message": "[\(ep.config.name)] upstream connection failed: \(state.errorMessage!)", "type": "pump_upstream_error"],
                ])
                logRequest(ep, req, model: built.model, status: 502, bytesDown: 0, startedAt: startedAt, extra: "upstream error")
                return
            }

            // Auth failure → refresh once and retry (never for env tokens).
            if (state.status == 401 || state.status == 403) && attempt == 1 && acquired.source.refreshable {
                Log.warn("[\(ep.config.name)] upstream returned \(state.status) for \(built.model ?? "?"); refreshing auth and retrying once")
                state.abort()
                state.awaitCompletion()
                ep.auth.invalidate()
                do {
                    acquired = try ep.auth.acquire()
                } catch {
                    respondError(conn, 502, "\(error)", label: "\(req.method) \(req.path)", startedAt: startedAt)
                    return
                }
                continue
            }

            streamThrough(ep: ep, req: req, state: state, conn: conn, startedAt: startedAt, model: built.model)
            return
        }
    }

    private func streamThrough(ep: RunningEndpoint, req: HTTPRequest, state: UpstreamClient.StreamState, conn: ClientConn, startedAt: Date, model: String?) {
        let filtered = Gateway.clientResponseHeaders(from: state.upstreamHeaders)
        // URLSession decodes content-encoding transparently, so a declared
        // Content-Length no longer matches the byte count we forward — force
        // chunked framing whenever the upstream compressed the body.
        let compressed = state.upstreamHeaders.contains { $0.0 == "content-encoding" }
        let chunked = state.expectedLength < 0 || compressed
        var wrote = false
        state.cond.lock()
        if !state.aborted {
            do {
                try conn.beginStream(status: state.status, headers: filtered, contentLength: chunked ? nil : Int(state.expectedLength), chunked: chunked)
                state.chunked = chunked
                state.headersSent = true
                state.cond.broadcast()
                wrote = true
            } catch {
                state.aborted = true
                state.cond.broadcast()
                conn.markBroken()
            }
        }
        state.cond.unlock()

        state.awaitCompletion()
        if wrote && chunked {
            try? conn.finishChunked()
        }
        logRequest(ep, req, model: model, status: state.status, bytesDown: state.bytesDown, startedAt: startedAt, extra: state.errorMessage.map { "upstream error: \($0)" })
    }

    private func respondError(_ conn: ClientConn, _ status: Int, _ message: String, label: String, startedAt: Date) {
        let body: [String: Any] = ["error": ["message": message, "type": "pump_error", "code": status]]
        let _ = try? conn.respondJSON(status, body)
        logRequest(nil, nil, label: label, status: status, bytesDown: 0, startedAt: startedAt)
    }

    private func logRequest(_ ep: RunningEndpoint?, _ req: HTTPRequest?, model: String? = nil, label: String? = nil, status: Int, bytesDown: Int, startedAt: Date, extra: String? = nil) {
        let epName = ep.map { "[\($0.config.name)] " } ?? ""
        let target = label ?? "\(req?.method ?? "?") \(req?.path ?? "?")"
        let withModel = model.map { "\(target) (\($0))" } ?? target
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        var line = "\(epName)\(withModel) -> \(status) (\(ms)ms, \(bytesDown)B)"
        if let extra = extra { line += " — \(extra)" }
        Log.info(line)
    }
}
