import Foundation

let PUMP_VERSION = "0.1.0"

// MARK: - endpoint configuration

/// One proprietary upstream endpoint. Everything pump needs to talk to it —
/// including how to authenticate — lives here; the code has no per-endpoint
/// behavior.
struct EndpointConfig {
    var name: String
    var baseUrl: String
    /// local API flavor → upstream path. Flavors: openai-chat,
    /// openai-completions, anthropic-messages, openai-responses, embeddings.
    var apiPaths: [String: String] = [:]
    /// Forward unknown POST paths to baseUrl + path.
    var passthrough = false
    /// Optional model-routing header name; absent → not sent.
    var modelHeader: String?
    /// Auth specification; pump assumes nothing about the protocol.
    struct AuthConfig {
        enum Kind: String { case none = "none"; case command = "command" }
        var kind: Kind = .none
        /// Environment variables checked for a ready token before running
        /// the command.
        var envTokens: [String] = []
        /// Shell command that obtains the credential (interactive allowed).
        /// Output contract: last stdout line =
        /// {"expiration": <unix-seconds>, "headers": {…}} — or a bare token
        /// (injected as Authorization: Bearer).
        var command: String?
        /// Kill the command after this many seconds.
        var commandTimeout: TimeInterval = 600
        /// Fallback in-memory cache lifetime when the output carries no
        /// "expiration". Absent → cache for the process lifetime.
        var cacheTTL: TimeInterval?
    }
    var auth: AuthConfig?
}

// MARK: - global configuration

struct Config {
    var host = "127.0.0.1"
    var port: UInt16 = 8787
    var verbose = false
    var endpoints: [EndpointConfig] = []
    var sourcePath: String?

    static func defaultPath() -> String {
        ProcessInfo.processInfo.environment["PUMP_CONFIG"]
            ?? NSHomeDirectory() + "/.pump/config.json"
    }

    /// Load config from `path`. pump is fully config-driven: there is no
    /// built-in endpoint, and endpoint credentials/URLs never live in source.
    static func load(path: String) throws -> Config {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw PumpError(
                "no config file at \(path) — create one (see README.md for the "
                    + "schema: endpoints with baseUrl, apiPaths, and auth), or point "
                    + "--config / PUMP_CONFIG at an existing file"
            )
        }
        var cfg = try parse(data: data, source: path)
        cfg.sourcePath = path
        return cfg
    }

    static func parse(data: Data, source: String) throws -> Config {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PumpError("\(source): invalid JSON — \(error.localizedDescription)")
        }
        guard let root = obj as? [String: Any] else {
            throw PumpError("\(source): top level must be a JSON object")
        }
        var cfg = Config()

        if let v = root["host"] as? String { cfg.host = v }
        if let v = root["port"] as? Int, v > 0, v < 65536 { cfg.port = UInt16(v) }

        guard let endpointsRaw = root["endpoints"] as? [[String: Any]], !endpointsRaw.isEmpty else {
            throw PumpError("\(source): \"endpoints\" must be a non-empty array")
        }
        for (i, raw) in endpointsRaw.enumerated() {
            cfg.endpoints.append(try parseEndpoint(raw, source: source, index: i))
        }

        var seen = Set<String>()
        for ep in cfg.endpoints {
            guard seen.insert(ep.name).inserted else {
                throw PumpError("\(source): duplicate endpoint name \"\(ep.name)\"")
            }
        }
        return cfg
    }

    // MARK: endpoint parsing

    private static func parseEndpoint(_ dict: [String: Any], source: String, index: Int) throws -> EndpointConfig {
        let where_ = "\(source) endpoints[\(index)]"
        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw PumpError("\(where_): \"name\" (string) is required")
        }
        guard let baseUrl = dict["baseUrl"] as? String, !baseUrl.isEmpty else {
            throw PumpError("\(where_) (\(name)): \"baseUrl\" (string) is required")
        }
        var ep = EndpointConfig(name: name, baseUrl: baseUrl)

        if let raw = dict["apiPaths"] as? [String: Any] {
            var paths: [String: String] = [:]
            for (k, v) in raw {
                guard let p = v as? String else { throw PumpError("\(where_) (\(name)): apiPaths.\(k) must be a string") }
                paths[k] = p
            }
            ep.apiPaths = paths
        }
        if let v = dict["passthrough"] as? Bool { ep.passthrough = v }
        if let v = dict["modelHeader"] as? String { ep.modelHeader = v }
        if let raw = dict["auth"] as? [String: Any] {
            ep.auth = try parseAuth(raw, endpoint: name, source: source)
        }
        return ep
    }

    private static func parseAuth(_ dict: [String: Any], endpoint: String, source: String) throws -> EndpointConfig.AuthConfig {
        let where_ = "\(source) endpoints[name=\(endpoint)].auth"
        var auth = EndpointConfig.AuthConfig()

        let kindRaw = (dict["type"] as? String) ?? ((dict["command"] != nil) ? "command" : "none")
        guard let kind = EndpointConfig.AuthConfig.Kind(rawValue: kindRaw) else {
            throw PumpError("\(where_): unknown type \"\(kindRaw)\" (expected none | command)")
        }
        auth.kind = kind

        if let v = dict["envTokens"] as? [String] { auth.envTokens = v }
        if let v = dict["command"] as? String { auth.command = v }
        if let v = dict["commandTimeout"] as? Double { auth.commandTimeout = v }
        if let v = dict["commandTimeout"] as? Int { auth.commandTimeout = TimeInterval(v) }
        if let v = dict["cacheTTL"] as? Double { auth.cacheTTL = v }
        if let v = dict["cacheTTL"] as? Int { auth.cacheTTL = TimeInterval(v) }

        if kind == .command && (auth.command ?? "").isEmpty {
            throw PumpError("\(where_): type \"command\" requires \"command\"")
        }
        return auth
    }
}
