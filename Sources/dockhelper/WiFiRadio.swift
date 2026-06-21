import Foundation
import CoreWLAN

/// The sole surviving CoreWLAN read: Wi-Fi radio power. Every other Wi-Fi read goes through
/// SCDynamicStore (`NetProbe`) to avoid the Location/TCC-triggering CoreWLAN calls. The "ipoff"
/// strategy never touches the radio (only the service's IP config), so there is no write surface
/// here — disassociate/setPower/forceRejoin went away with the disassociate strategy.
enum WiFiRadio {
    static func isPowerOn() -> Bool {
        CWWiFiClient.shared().interface()?.powerOn() ?? false
    }
}
