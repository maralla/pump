import Foundation

struct PumpError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Token acquisition for one endpoint, fully delegated to configuration.
///
///   1. env tokens named in auth.envTokens — used as-is (Bearer)
///   2. auth.command — a user-supplied script. It does whatever the user
///      designed and prints its result; pump parses the output:
///
///        {"expiration": <unix-seconds>, "headers": {"X-Auth": "...", ...}}
///
///      as the last stdout line → those headers are injected on requests and
///      cached in memory until `expiration`. If the output is not that JSON
///      document, the trimmed stdout is treated as a bearer token.
///
/// Single-flight: concurrent requests trigger exactly one command run.
final class AuthProvider {
    enum Source: String {
        case env, command, none
        /// Retry-worthy: re-running might yield a fresh credential.
        var refreshable: Bool { self == .command }
    }

    struct Resolved {
        let headers: [(String, String)]
        let source: Source
    }

    let endpointName: String
    private let auth: EndpointConfig.AuthConfig

    private let cond = NSCondition()
    private var acquiring = false
    private var current: Resolved?
    private var expiresAt: Date?

    init(endpointName: String, auth: EndpointConfig.AuthConfig) {
        self.endpointName = endpointName
        self.auth = auth
    }

    var lastSource: Source? { cond.withLock { current?.source } }

    /// Returns the headers to inject into requests to this endpoint.
    func acquire() throws -> Resolved {
        if auth.kind == .none {
            return Resolved(headers: [], source: .none)
        }

        cond.lock()
        if let c = current, !isExpired() { cond.unlock(); return c }  // fast path
        while acquiring {
            cond.wait()
            if let c = current, !isExpired() { cond.unlock(); return c }
        }
        acquiring = true
        cond.unlock()

        defer {
            cond.lock()
            acquiring = false
            cond.broadcast()
            cond.unlock()
        }

        // Re-check after single-flight wait.
        cond.lock()
        if let c = current, !isExpired() { cond.unlock(); return c }
        cond.unlock()

        let env = ProcessInfo.processInfo.environment
        for name in auth.envTokens {
            if let tok = env[name], !tok.isEmpty {
                Log.info("[\(endpointName)] auth: using token from \(name)")
                return finish([("Authorization", "Bearer \(tok)")], source: .env, expires: nil)
            }
        }

        guard let command = auth.command, !command.isEmpty else {
            throw PumpError(
                "[\(endpointName)] no credentials available (checked \(auth.envTokens.joined(separator: ", "))). "
                    + "Configure auth.command — a script that obtains and prints the credential."
            )
        }

        let (headers, expires) = try runCommand(command)
        return finish(headers, source: .command, expires: expires)
    }

    /// Drop the in-memory result so the next acquire() re-runs the command.
    func invalidate() {
        guard auth.kind == .command else { return }
        cond.lock()
        current = nil
        expiresAt = nil
        cond.unlock()
        Log.warn("[\(endpointName)] auth: invalidated; next request re-runs the auth command")
    }

    // MARK: internals

    private func isExpired() -> Bool {
        if let e = expiresAt { return Date() >= e }
        return false
    }

    private func finish(_ headers: [(String, String)], source: Source, expires: Date?) -> Resolved {
        let value = Resolved(headers: headers, source: source)
        cond.lock()
        current = value
        expiresAt = expires
        cond.unlock()
        if let e = expires {
            Log.info("[\(endpointName)] auth: acquired via \(source.rawValue), cached until \(ISO8601DateFormatter().string(from: e))")
        } else {
            Log.info("[\(endpointName)] auth: acquired via \(source.rawValue)")
        }
        return value
    }

    /// Run the user's auth script. stderr streams through (progress messages
    /// land in pump's log); stdout is parsed for the credential.
    private func runCommand(_ command: String) throws -> (headers: [(String, String)], expires: Date?) {
        Log.info("[\(endpointName)] auth: running auth command")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.standardError  // live progress for the user

        do { try proc.run() } catch {
            throw PumpError("[\(endpointName)] auth command failed to start: \(error.localizedDescription)")
        }

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + .seconds(Int(auth.commandTimeout))) == .timedOut {
            proc.terminate()
            _ = sem.wait(timeout: .now() + .seconds(5))
            throw PumpError("[\(endpointName)] auth command timed out after \(Int(auth.commandTimeout))s")
        }
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            throw PumpError("[\(endpointName)] auth command exited \(proc.terminationStatus)")
        }

        // Last non-empty stdout line = the result.
        let lines = stdout.split(separator: "\n").reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let last = lines.first,
           let obj = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any],
           obj["headers"] is [String: Any] {
            let headersDict = obj["headers"] as! [String: Any]
            let headers = headersDict.map { (String($0.key), String(describing: $0.value)) }
            var expires: Date?
            if let exp = (obj["expiration"] as? Double) ?? (obj["expiration"] as? Int).map(Double.init) {
                expires = Date(timeIntervalSince1970: exp)
            } else if let ttl = auth.cacheTTL {
                expires = Date().addingTimeInterval(ttl)
            }
            return (headers, expires)
        }

        // Fallback: plain output = bearer token.
        let token = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n") else {
            throw PumpError("[\(endpointName)] auth command printed no parsable credential "
                + "(expected {\"expiration\": …, \"headers\": {…}} as the last stdout line, or a bare token)")
        }
        Log.info("[\(endpointName)] auth: command printed a bare token; injecting as Authorization: Bearer")
        var expires: Date?
        if let ttl = auth.cacheTTL { expires = Date().addingTimeInterval(ttl) }
        return ([("Authorization", "Bearer \(token)")], expires)
    }
}
