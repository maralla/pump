import Foundation

/// Process-wide logging to stderr. stdout stays reserved for command output.
enum Log {
    private static let queue = DispatchQueue(label: "pump.log")
    nonisolated(unsafe) static var verbose = false

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    static func _write(_ level: String, _ msg: String) {
        queue.sync {
            let line = "[\(stamp())] [\(level)] \(msg)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    static func info(_ msg: String) { _write("INFO", msg) }
    static func warn(_ msg: String) { _write("WARN", msg) }
    static func err(_ msg: String) { _write("ERROR", msg) }
    static func debug(_ msg: String) { if verbose { _write("DEBUG", msg) } }
}
