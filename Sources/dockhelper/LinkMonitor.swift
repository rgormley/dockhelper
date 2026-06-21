import Foundation
import SystemConfiguration

/// The detection seam: watches SCDynamicStore link/IPv4/AirPort keys and forwards a
/// fresh snapshot to the Reconciler on every change. Event-driven — zero polling.
final class LinkMonitor {
    let reconciler: Reconciler
    let config: Config
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    init(reconciler: Reconciler, config: Config) {
        self.reconciler = reconciler
        self.config = config
    }

    func start() {
        var ctx = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let store = SCDynamicStoreCreate(
            nil, "dockhelper" as CFString, linkMonitorCallback, &ctx) else {
            Log.error("LinkMonitor: failed to create SCDynamicStore")
            return
        }
        self.store = store

        // Explicit key: the global primary-interface flip. Patterns: per-interface
        // link state, Wi-Fi IPv4 appear/disappear, and Wi-Fi association (BSSID).
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = [
            "State:/Network/Interface/[^/]+/Link",
            "State:/Network/Interface/[^/]+/IPv4",
            "State:/Network/Interface/[^/]+/AirPort",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)

        let rls = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        self.runLoopSource = rls
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        Log.info("LinkMonitor: watching Link / IPv4 / AirPort + Global/IPv4")
    }
}

/// C-callback boundary. Top-level (captures nothing) so it's usable as a C function
/// pointer; the `info` pointer carries the LinkMonitor. We recompute a full snapshot
/// here (cheap) and hand it to the actor — no per-key diffing.
private func linkMonitorCallback(
    _ store: SCDynamicStore,
    _ changedKeys: CFArray,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let monitor = Unmanaged<LinkMonitor>.fromOpaque(info).takeUnretainedValue()
    let reconciler = monitor.reconciler
    guard let snap = NetProbe.snapshot(config: monitor.config) else { return }
    Task { await reconciler.handleEvent(snap) }
}
