import Foundation

/// Immutable value snapshot of the network state relevant to the reconcile decision.
/// Sendable so it can cross the SCDynamicStore C-callback thread → Reconciler actor.
struct NetSnapshot: Sendable, Codable {
    let wifiBSD: String
    let ethernetBSDs: [String]
    let perWiredActive: [String: Bool]
    let anyWiredActive: Bool
    /// True if Wi-Fi looks like it's carrying/holding an infrastructure association.
    /// OR of three independent SCDynamicStore signals so no single redaction blinds us:
    /// non-zero BSSID, Wi-Fi is the primary IPv4 interface, or Wi-Fi has an IPv4 address.
    let wifiAssociated: Bool
    let wifiHasRoutableIPv4: Bool
    let wifiIsPrimary: Bool
    let wifiPowerOn: Bool
    let primaryInterface: String?

    func json() -> String {
        (try? JSONEncoder().encode(self))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
