import Foundation

/// Daemon configuration, loaded from JSON (see `Paths.config`) with built-in defaults.
/// Every key is optional in the file — a partial config overrides only what it sets, so
/// a chezmoi-templated per-host file can tweak just `strategy`, `v6_mode`, or the cadences.
struct Config: Codable, Sendable {
    /// IPv6 handling while suppressed: link-local only (validated default) or fully off.
    enum V6Mode: String, Codable, Sendable {
        case linkLocal = "link_local"
        case off
    }

    /// Suppression strategy. Only "ipoff" is implemented (strip the Wi-Fi service's routable IP
    /// while docked); the field stays configurable for a future radio-off fallback.
    var strategy: String = "ipoff"

    /// IPv6 config to apply while suppressed (IPv4 is always set off).
    var v6Mode: V6Mode = .linkLocal

    /// Override the Wi-Fi service name; nil auto-resolves it from the BSD via SystemConfiguration.
    var wifiServiceOverride: String? = nil

    /// A link transition must stay settled this long before we SUPPRESS (flap suppression).
    /// Defaults high enough to ride a dock's Ethernet bring-up flap without thrashing.
    var debounceSeconds: Double = 5.0

    /// Settle window before RESTORING on undock. Short by default — restore is the fast path
    /// (recover connectivity quickly); only the suppress side needs the longer flap ride-through.
    var restoreDebounceSeconds: Double = 0.5

    /// Read-only state sampling cadence (also the override-flag polling interval).
    var observeSeconds: Double = 0.5

    /// If non-empty, ONLY these BSD names count as wired uplinks.
    var interfaceInclude: [String] = []
    /// These BSD names never count as wired, on top of the built-in virtual-interface filter.
    var interfaceExclude: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case strategy
        case v6Mode = "v6_mode"
        case wifiServiceOverride = "wifi_service"
        case debounceSeconds = "debounce_seconds"
        case restoreDebounceSeconds = "restore_debounce_seconds"
        case observeSeconds = "observe_seconds"
        case interfaceInclude = "interface_include"
        case interfaceExclude = "interface_exclude"
    }

    init(from decoder: Decoder) throws {
        let def = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try c.decodeIfPresent(String.self, forKey: .strategy) ?? def.strategy
        v6Mode = try c.decodeIfPresent(V6Mode.self, forKey: .v6Mode) ?? def.v6Mode
        wifiServiceOverride = try c.decodeIfPresent(String.self, forKey: .wifiServiceOverride) ?? def.wifiServiceOverride
        debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? def.debounceSeconds
        restoreDebounceSeconds = try c.decodeIfPresent(Double.self, forKey: .restoreDebounceSeconds) ?? def.restoreDebounceSeconds
        observeSeconds = try c.decodeIfPresent(Double.self, forKey: .observeSeconds) ?? def.observeSeconds
        interfaceInclude = try c.decodeIfPresent([String].self, forKey: .interfaceInclude) ?? def.interfaceInclude
        interfaceExclude = try c.decodeIfPresent([String].self, forKey: .interfaceExclude) ?? def.interfaceExclude
    }

    static func load(from path: String) -> Config {
        guard let data = FileManager.default.contents(atPath: path) else {
            Log.info("config: \(path) not found; using defaults")
            return Config()
        }
        do {
            let c = try JSONDecoder().decode(Config.self, from: data)
            Log.info("config: loaded \(path)")
            return c
        } catch {
            Log.warn("config: failed to parse \(path) (\(error)); using defaults")
            return Config()
        }
    }
}
