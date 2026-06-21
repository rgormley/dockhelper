import Foundation

/// Minimal thread-safe line logger to stdout. Plain stdout (not os.Logger) so the
/// spike's output is trivially tailable/greppable next to manual `scutil` observations.
enum Log {
    private static let lock = NSLock()

    /// Local wall-clock `yyyy-MM-ddTHH:mm:ss.SSS` — readable and easy to correlate
    /// with the manual observation commands run alongside the spike.
    static func timestamp() -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: Date())
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    private static func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// Emit a line verbatim (used for the JSON state lines, which carry their own timestamp).
    static func raw(_ s: String) { write(s.hasSuffix("\n") ? s : s + "\n") }

    private static func log(_ level: String, _ message: String) {
        write("\(timestamp()) [\(level)] \(message)\n")
    }

    static func debug(_ m: String) { log("DEBUG", m) }
    static func info(_ m: String)  { log("INFO", m) }
    static func warn(_ m: String)  { log("WARN", m) }
    static func error(_ m: String) { log("ERROR", m) }
}
