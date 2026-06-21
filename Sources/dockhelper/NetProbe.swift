import Foundation
import SystemConfiguration

/// Builds a `NetSnapshot` from SCDynamicStore reads. Stateless: each call resolves a
/// fresh inventory and a throwaway store, so it's safe to invoke from either the
/// run-loop callback thread or the Reconciler actor without shared mutable state.
enum NetProbe {
    static func snapshot(config: Config) -> NetSnapshot {
        let inv = InterfaceInventory.resolve(config: config)

        guard let store = SCDynamicStoreCreate(nil, "dockhelper.probe" as CFString, nil, nil) else {
            Log.error("NetProbe: failed to create SCDynamicStore")
            return NetSnapshot(wifiBSD: inv.wifiBSD, ethernetBSDs: inv.ethernetBSDs,
                               perWiredActive: [:], anyWiredActive: false,
                               wifiAssociated: false, wifiHasRoutableIPv4: false,
                               wifiIsPrimary: false, wifiPowerOn: WiFiRadio.isPowerOn(),
                               primaryInterface: nil)
        }

        var perWired: [String: Bool] = [:]
        var anyWired = false
        for bsd in inv.ethernetBSDs {
            let active = linkActive(store, bsd)
            perWired[bsd] = active
            if active { anyWired = true }
        }

        let primary = primaryInterface(store)
        let isPrimary = (primary == inv.wifiBSD)
        let hasIP = wifiHasIPv4(store, inv.wifiBSD)
        let bssid = wifiHasBSSID(store, inv.wifiBSD)

        return NetSnapshot(
            wifiBSD: inv.wifiBSD,
            ethernetBSDs: inv.ethernetBSDs,
            perWiredActive: perWired,
            anyWiredActive: anyWired,
            wifiAssociated: bssid || isPrimary || hasIP,
            wifiHasRoutableIPv4: hasIP,
            wifiIsPrimary: isPrimary,
            wifiPowerOn: WiFiRadio.isPowerOn(),
            primaryInterface: primary)
    }

    // MARK: - SCDynamicStore reads

    private static func dict(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    private static func linkActive(_ store: SCDynamicStore, _ bsd: String) -> Bool {
        guard let d = dict(store, "State:/Network/Interface/\(bsd)/Link") else { return false }
        return (d["Active"] as? Bool) ?? false
    }

    /// Association signal that needs no CoreWLAN SSID read: a non-zero BSSID in the
    /// AirPort dict. (SSID_STR is redacted on this OS, so BSSID is the usable key.)
    private static func wifiHasBSSID(_ store: SCDynamicStore, _ wifi: String) -> Bool {
        guard let d = dict(store, "State:/Network/Interface/\(wifi)/AirPort") else { return false }
        guard let bssid = d["BSSID"] as? Data else { return false }
        return bssid.contains { $0 != 0 }
    }

    private static func wifiHasIPv4(_ store: SCDynamicStore, _ wifi: String) -> Bool {
        guard let d = dict(store, "State:/Network/Interface/\(wifi)/IPv4") else { return false }
        guard let addrs = d["Addresses"] as? [Any] else { return false }
        return !addrs.isEmpty
    }

    private static func primaryInterface(_ store: SCDynamicStore) -> String? {
        dict(store, "State:/Network/Global/IPv4")?["PrimaryInterface"] as? String
    }
}
