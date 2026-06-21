import Foundation
import SystemConfiguration
import CoreWLAN

/// Resolved BSD names, classified by interface TYPE (not by name — on eos the
/// Thunderbolt ports surface as en1..en6, so name heuristics are useless).
struct InterfaceInventory: Sendable {
    let wifiBSD: String
    let ethernetBSDs: [String]

    /// Virtual/peer interfaces that should never be treated as a wired uplink.
    /// These don't report as `kSCNetworkInterfaceTypeEthernet`, so this is a
    /// belt-and-suspenders assertion that surfaces OS classification surprises.
    private static let excludePrefixes =
        ["awdl", "llw", "bridge", "anpi", "ap", "utun", "ipsec", "gif", "stf", "vlan", "bond"]

    private static func excluded(_ bsd: String) -> Bool {
        excludePrefixes.contains { bsd.hasPrefix($0) }
    }

    static func resolve(config: Config) -> InterfaceInventory {
        var wifi: String?
        var eths: [String] = []

        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            guard let type = SCNetworkInterfaceGetInterfaceType(iface) else { continue }
            if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
                wifi = bsd
            } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) {
                if excluded(bsd) {
                    Log.warn("Ethernet-classified interface \(bsd) matched the exclude set — ignoring")
                } else {
                    eths.append(bsd)
                }
            }
        }

        // Config include/exclude, applied on top of the type-based classification.
        if !config.interfaceExclude.isEmpty {
            eths.removeAll { config.interfaceExclude.contains($0) }
        }
        if !config.interfaceInclude.isEmpty {
            eths = eths.filter { config.interfaceInclude.contains($0) }
        }

        // CoreWLAN is canonical for the Wi-Fi name (handles the rare multi-Wi-Fi case).
        let cw = CWWiFiClient.shared().interface()?.interfaceName
        if let cw, cw != wifi {
            Log.warn("Wi-Fi BSD mismatch: SC=\(wifi ?? "nil") CoreWLAN=\(cw); using CoreWLAN")
            wifi = cw
        }

        return InterfaceInventory(wifiBSD: wifi ?? "en0", ethernetBSDs: eths.sorted())
    }
}
