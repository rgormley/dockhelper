import Foundation

/// Actuation for the "ipoff" strategy: strip the Wi-Fi service's routable IP while docked so the
/// host single-homes onto the wire — WITHOUT disassociating. The radio stays associated (AWDL /
/// Handoff / AirDrop survive); with no "manual disconnect" there's no auto-join score drop, so
/// restore is trivial (the OS never left the network). All via `networksetup`, which needs root.
///
/// Capture/restore is DHCP-only (the read + the fail-closed gate live in `SCNetworkConfig`): we
/// suppress only a plain DHCP + IPv6-automatic service and restore exactly that. The blocking
/// `networksetup` writes run OFF the caller's actor on a private serial queue, so the Reconciler's
/// executor is never stalled by the ~100ms `Process` wait.
enum Suppressor {
    /// Single-home: IPv4 off, IPv6 link-local (or off). Leaves the Wi-Fi association untouched.
    /// Returns true only if BOTH sub-commands exited 0 — the caller must not record suppression
    /// (advance state / trust the capture) on a partial or failed write.
    static func suppress(service: String, v6 mode: Config.V6Mode) async -> Bool {
        let v4ok = await run(["-setv4off", service]) == 0
        let v6ok: Bool
        switch mode {
        case .linkLocal: v6ok = await run(["-setv6LinkLocal", service]) == 0
        case .off:       v6ok = await run(["-setv6off", service]) == 0
        }
        return v4ok && v6ok
    }

    /// Restore to DHCP + IPv6-automatic — the only config the DHCP-only scope ever suppresses.
    /// Returns true only if BOTH sub-commands exited 0.
    static func restore(service: String) async -> Bool {
        let v4ok = await run(["-setdhcp", service]) == 0
        let v6ok = await run(["-setv6automatic", service]) == 0
        return v4ok && v6ok
    }

    /// Serial queue so a suppress/restore's two sub-commands can't interleave (with each other or a
    /// concurrent transition's) and — crucially — so the blocking `Process` wait never runs on the
    /// calling actor's serial executor.
    private static let queue = DispatchQueue(label: "me.gormley.dockhelper.networksetup")

    @discardableResult
    private static func run(_ args: [String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            queue.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                p.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do {
                    try p.run()
                } catch {
                    Log.warn("networksetup \(args.joined(separator: " ")) failed to launch: \(error)")
                    cont.resume(returning: -1)
                    return
                }
                // networksetup output is a few bytes; drain stdout then stderr before waiting on
                // exit (each read returns when the child closes the fd, i.e. at exit).
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let msg = (String(data: err, encoding: .utf8) ?? "")
                        + (String(data: out, encoding: .utf8) ?? "")
                    Log.warn("networksetup \(args.joined(separator: " ")) exited \(p.terminationStatus): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                cont.resume(returning: p.terminationStatus)
            }
        }
    }
}
