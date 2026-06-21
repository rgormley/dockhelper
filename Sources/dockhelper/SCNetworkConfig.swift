import Foundation
import SystemConfiguration

/// Reads the Wi-Fi network service's CONFIGURED IPv4/IPv6 method (DHCP vs static vs off) and its
/// human service name ("Wi-Fi"), straight from SystemConfiguration's preferences. Replaces scraping
/// `networksetup -getinfo` text: locale-proof, method-exact, needs no root and no TCC (only WRITING
/// prefs needs root), and auto-resolves the service name from the BSD interface so the daemon never
/// hard-codes "Wi-Fi". All `SCNetwork*`/`SCPreferences` handles are non-Sendable CoreFoundation refs
/// kept strictly function-local; only the `Resolved` value escapes the isolation boundary.
enum SCNetworkConfig {
    struct Resolved: Sendable {
        let serviceName: String   // the `networksetup` key, e.g. "Wi-Fi"
        let v4Method: String?     // IPv4 ConfigMethod, e.g. "DHCP"; nil if no IPv4 protocol
        let v6Method: String?     // IPv6 ConfigMethod, e.g. "Automatic"

        /// The only config the DHCP-only scope ever suppresses: plain DHCP, with IPv6 either
        /// automatic or absent. The configured (prefs) v6 value for a normal service is "Automatic"
        /// — NOT the "RouterAdvertisement"/"6to4" that show up only in the running State layer; a
        /// nil v6Method (no IPv6 protocol / no ConfigMethod) is also fine, since restore is
        /// `-setv6automatic`. Reject only a concrete static (`Manual`) v6.
        var isPlainDHCP: Bool {
            v4Method == (kSCValNetIPv4ConfigMethodDHCP as String)
                && (v6Method == (kSCValNetIPv6ConfigMethodAutomatic as String) || v6Method == nil)
        }

        /// The user has taken manual control with a static IP on v4 or v6. The daemon must never
        /// clobber this — neither suppress it nor restore (set DHCP) over it.
        var hasStaticConfig: Bool {
            v4Method == (kSCValNetIPv4ConfigMethodManual as String)
                || v6Method == (kSCValNetIPv6ConfigMethodManual as String)
        }
    }

    /// Resolve the Wi-Fi service by BSD name (e.g. "en0"). A non-nil `override` matches by human
    /// service name instead (the multi-Wi-Fi escape hatch). Returns nil if prefs can't be opened or
    /// no service matches — the caller fails closed on nil.
    static func resolve(wifiBSD: String, override: String?) -> Resolved? {
        guard let prefs = SCPreferencesCreate(nil, "dockhelper" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            return nil
        }
        for svc in services {
            guard SCNetworkServiceGetEnabled(svc) else { continue }   // skip stale/disabled duplicates
            let name = SCNetworkServiceGetName(svc) as String?
            let matches: Bool
            if let override {
                matches = (name == override)
            } else {
                let bsd = SCNetworkServiceGetInterface(svc)
                    .flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
                matches = (bsd == wifiBSD)
            }
            guard matches else { continue }
            return Resolved(
                serviceName: name ?? wifiBSD,
                v4Method: method(svc, kSCNetworkProtocolTypeIPv4),
                v6Method: method(svc, kSCNetworkProtocolTypeIPv6))
        }
        return nil
    }

    /// A protocol's `ConfigMethod`. The IPv4 and IPv6 keys are the same CFString "ConfigMethod",
    /// so one accessor serves both.
    private static func method(_ svc: SCNetworkService, _ type: CFString) -> String? {
        guard let proto = SCNetworkServiceCopyProtocol(svc, type),
              let cfg = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] else {
            return nil
        }
        return cfg[kSCPropNetIPv4ConfigMethod as String] as? String
    }
}
