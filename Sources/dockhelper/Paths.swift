import Foundation

/// Fixed filesystem locations and the launchd label. Runtime/config paths honor env
/// overrides so the daemon can be exercised without root during development:
///   DOCKHELPER_CONFIG=/tmp/dh/config.json DOCKHELPER_RUNTIME_DIR=/tmp/dh \
///     .build/debug/dockhelper run
enum Paths {
    static let label = "me.gormley.dockhelper"
    static let binary = "/usr/local/sbin/dockhelper"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let log = "/var/log/dockhelper.log"

    private static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// Config file (chezmoi-managed in production).
    static var config: String {
        env("DOCKHELPER_CONFIG") ?? "/usr/local/etc/dockhelper/config.json"
    }

    /// Runtime dir — defaults under /var/run (root-owned, cleared on boot, so a forgotten
    /// override never persists across reboot).
    static var runtimeDir: String {
        env("DOCKHELPER_RUNTIME_DIR") ?? "/var/run/dockhelper"
    }

    static var state: String { runtimeDir + "/state.json" }
    static var overrideFlag: String { runtimeDir + "/override" }

    /// Durable state dir — unlike `runtimeDir` this MUST survive reboot, so a machine that
    /// rebooted while docked still knows it suppressed Wi-Fi and restores correctly on undock.
    /// /var/db is root-owned and present on every boot. Env override mirrors the runtime pattern.
    static var persistentDir: String {
        env("DOCKHELPER_STATE_DIR") ?? "/var/db/dockhelper"
    }

    /// Captured pre-suppression IP config. Its PRESENCE is the source of truth for "suppressed".
    static var capture: String { persistentDir + "/capture.json" }
}
