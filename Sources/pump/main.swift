import Foundation

#if canImport(Glibc)
import Glibc
#endif

// MARK: flag parsing

struct Flags {
    var values: [String: String] = [:]
    var bools: Set<String> = []
    var positionals: [String] = []

    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { bools.contains(name) }
}

func parseFlags(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) throws -> Flags {
    var out = Flags()
    var i = 0
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { out.positionals.append(a); i += 1; continue }
        let name = String(a.dropFirst(2))
        if boolFlags.contains(name) {
            out.bools.insert(name); i += 1
        } else if valueFlags.contains(name) {
            guard i + 1 < args.count else { throw PumpError("--\(name) needs a value") }
            out.values[name] = args[i + 1]; i += 2
        } else {
            throw PumpError("unknown flag --\(name)")
        }
    }
    return out
}

let allValueFlags: Set<String> = ["host", "port", "config"]
let allBoolFlags: Set<String> = ["verbose", "help"]

/// Global overrides: config file ← environment ← CLI flags. Endpoint
/// specifics (URLs, auth, models) live only in the config.
func loadConfig(_ flags: Flags) throws -> Config {
    let path = flags.value("config") ?? Config.defaultPath()
    var cfg = try Config.load(path: path)

    let env = ProcessInfo.processInfo.environment
    if let v = env["PUMP_HOST"] { cfg.host = v }
    if let v = env["PUMP_PORT"], let p = UInt16(v) { cfg.port = p }

    if let v = flags.value("host") { cfg.host = v }
    if let v = flags.value("port"), let p = UInt16(v) { cfg.port = p }
    if flags.flag("verbose") { Log.verbose = true }
    return cfg
}

// MARK: commands

func cmdServe(_ flags: Flags) throws {
    let cfg = try loadConfig(flags)
    let endpoints = cfg.endpoints.map { RunningEndpoint(config: $0) }
    let handlers = ProxyHandlers(config: cfg, endpoints: endpoints, upstream: UpstreamClient())

    Log.info("pump \(PUMP_VERSION) serving")
    Log.info("  config: \(cfg.sourcePath ?? "?")")
    for ep in endpoints {
        Log.info("  endpoint \(ep.config.name): \(ep.config.baseUrl)")
        let paths = ep.config.apiPaths.keys.sorted().map { "\($0)→\(ep.config.apiPaths[$0]!)" }.joined(separator: "  ")
        Log.info("    apiPaths: \(paths)\(ep.config.passthrough ? "  +passthrough" : "")")
        switch ep.config.auth?.kind {
        case .command:
            let cmd = ep.config.auth?.command ?? ""
            Log.info("    auth: command (\(cmd.count > 80 ? cmd.prefix(77) + "..." : cmd))")
        default:
            Log.info("    auth: none")
        }
    }

    let server = HTTPServer(host: cfg.host, port: cfg.port) { req, conn in
        handlers.handle(req, conn)
    }
    try server.run()
}

// MARK: entry

let helpText = """
pump \(PUMP_VERSION) — local proxy that exposes standard AI APIs (OpenAI chat/responses, Anthropic
messages) and forwards them to proprietary endpoints defined in its config file. Endpoint
specifics — URLs, auth, model routing — live entirely in configuration; the code is
endpoint-agnostic and acquires credentials automatically at runtime.

USAGE:
  pump serve   [--config PATH] [--host H] [--port P] [--verbose]
  pump version | help

CONFIG:
  ~/.pump/config.json (override with --config or PUMP_CONFIG). Defines endpoints
  (baseUrl, apiPaths, model routing, passthrough) and their auth (env tokens,
  auth command). Endpoint configs hold credentials — keep them out of source
  control. See README.md for the full schema.

Auth runs automatically on the first request that needs it: env tokens first,
then auth.command — your script obtains the credential and prints
{"expiration": …, "headers": {…}} or a bare token. An upstream 401/403
invalidates the in-memory credential and re-runs the command once.

SERVE ROUTES (local):
  POST /v1/chat/completions   → endpoint apiPaths["openai-chat"]
  POST /v1/messages           → endpoint apiPaths["anthropic-messages"]
  POST /v1/responses          → endpoint apiPaths["openai-responses"]
  POST <other>                → passthrough (endpoint.passthrough)
"""

func main() {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.first ?? "serve"
    if command == "--help" || command == "-h" || command == "help" {
        print(helpText)
        exit(0)
    }
    args.removeFirst()

    do {
        let flags = try parseFlags(args, valueFlags: allValueFlags, boolFlags: allBoolFlags)
        if flags.flag("help") { print(helpText); exit(0) }
        switch command {
        case "serve": try cmdServe(flags)
        case "version", "--version", "-v": print("pump \(PUMP_VERSION)")
        default:
            FileHandle.standardError.write(Data("unknown command '\(command)' — try `pump help`\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("pump: error: \(error)\n".utf8))
        exit(1)
    }
}

main()
