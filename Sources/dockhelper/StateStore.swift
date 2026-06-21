import Foundation

/// The daemon's published state — written to `Paths.state` every reconcile and read back
/// by `dockhelper status`. This is the flag-file/state-file control model's read side.
struct DaemonState: Codable, Sendable {
    let ts: String
    let strategy: String
    let overrideEngaged: Bool
    let anyWired: Bool
    let wiredActive: [String: Bool]
    let wifiBSD: String
    let wifiAssoc: Bool
    let wifiIP: Bool
    let wifiPrimary: Bool
    let primary: String?
    let powerOn: Bool
    let desired: String
    let action: String

    /// Compact single line for the daemon log.
    func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Snapshot of the Wi-Fi service's pre-suppression IP config, persisted to a durable path
/// (`Paths.capture`). Its PRESENCE is the daemon's source of truth for "I have suppressed Wi-Fi" —
/// durable so a reboot-while-docked still restores correctly on undock. In the DHCP-only scope the
/// restore is fixed (DHCP + IPv6-automatic), so `v4Method`/`v6Method` are forensic (`status`/log)
/// detail; `service` is the live field — the `networksetup` key the restore writes to.
struct Capture: Codable, Sendable {
    let service: String      // e.g. "Wi-Fi"
    let v4Method: String     // captured IPv4 ConfigMethod, e.g. "DHCP"
    let v6Method: String     // captured IPv6 ConfigMethod, e.g. "Automatic"
    let capturedAt: String   // Log.timestamp()
}

enum StateStore {
    /// Atomically publish state. Best-effort: a non-root foreground run that can't write
    /// the runtime dir just logs a warning rather than failing the reconcile.
    static func write(_ state: DaemonState) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.runtimeDir) {
            try? fm.createDirectory(atPath: Paths.runtimeDir, withIntermediateDirectories: true)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Paths.state), options: .atomic)
        } catch {
            Log.warn("state: could not write \(Paths.state) (\(error))")
        }
    }

    static func read() -> DaemonState? {
        guard let data = FileManager.default.contents(atPath: Paths.state) else { return nil }
        return try? JSONDecoder().decode(DaemonState.self, from: data)
    }

    // MARK: - Suppression capture (durable; presence == "suppressed")

    /// Persist the pre-suppression config. Atomic; creates the durable dir on demand.
    static func writeCapture(_ c: Capture) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.persistentDir) {
            try? fm.createDirectory(atPath: Paths.persistentDir, withIntermediateDirectories: true)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Paths.capture), options: .atomic)
        } catch {
            Log.warn("capture: could not write \(Paths.capture) (\(error))")
        }
    }

    static func readCapture() -> Capture? {
        guard let data = FileManager.default.contents(atPath: Paths.capture) else { return nil }
        return try? JSONDecoder().decode(Capture.self, from: data)
    }

    static func clearCapture() {
        try? FileManager.default.removeItem(atPath: Paths.capture)
    }

    /// Bare existence check — deliberately no decode, so a corrupt file still reads as "present"
    /// and the reconciler errs toward NOT re-capturing (never overwrite the baseline).
    static func hasCapture() -> Bool {
        FileManager.default.fileExists(atPath: Paths.capture)
    }
}
