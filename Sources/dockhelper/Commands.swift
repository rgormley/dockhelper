import Foundation

/// CLI subcommands that talk to the daemon purely through files — `status` reads the
/// state file, `override` writes/removes the flag file. No IPC server; the running daemon
/// notices an override change within one observe cycle.
enum Commands {
    static func status() -> Int32 {
        guard let s = StateStore.read() else {
            print("dockhelper: no state at \(Paths.state) — daemon not running?")
            return 1
        }
        let wired = s.wiredActive.filter { $0.value }.keys.sorted().joined(separator: ",")
        print("""
        dockhelper status
          updated:     \(s.ts)
          strategy:    \(s.strategy)
          override:    \(s.overrideEngaged ? "ENGAGED (suppression paused)" : "off")
          wired up:    \(s.anyWired)\(wired.isEmpty ? "" : " [\(wired)]")
          wifi (\(s.wifiBSD)): assoc=\(s.wifiAssoc) ip=\(s.wifiIP) primary=\(s.wifiPrimary) powerOn=\(s.powerOn)
          primary if:  \(s.primary ?? "-")
          desired:     \(s.desired)
          last action: \(s.action)
        """)
        return 0
    }

    static func override(_ engage: Bool) -> Int32 {
        let fm = FileManager.default
        if engage {
            if !fm.fileExists(atPath: Paths.runtimeDir) {
                do {
                    try fm.createDirectory(atPath: Paths.runtimeDir, withIntermediateDirectories: true)
                } catch {
                    print("dockhelper: cannot create \(Paths.runtimeDir): \(error)")
                    return 1
                }
            }
            guard fm.createFile(atPath: Paths.overrideFlag, contents: Data()) else {
                print("dockhelper: cannot write override flag \(Paths.overrideFlag) (need sudo?)")
                return 1
            }
            print("override ENGAGED — Wi-Fi stays normal even while docked (\(Paths.overrideFlag))")
        } else {
            if fm.fileExists(atPath: Paths.overrideFlag) {
                do {
                    try fm.removeItem(atPath: Paths.overrideFlag)
                } catch {
                    print("dockhelper: cannot remove override flag: \(error)")
                    return 1
                }
            }
            print("override released — daemon will reconcile to current link state")
        }
        return 0
    }
}
