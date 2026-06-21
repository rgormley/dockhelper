import Foundation

// dockhelper — single-home onto wired Ethernet while docked by stripping the Wi-Fi service's
// routable IP (IPv4 off, IPv6 link-local). Wi-Fi stays associated, so AWDL/Handoff/AirDrop survive;
// restores on undock. Subcommands: run (the daemon launchd invokes), status, override.

func printUsage() {
    print("""
    dockhelper — strip Wi-Fi's routable IP while docked (Wi-Fi stays associated)

    usage:
      dockhelper run              run the daemon
      dockhelper status           print current state (reads the state file)
      dockhelper override on|off  pause / resume suppression
    """)
}

func runDaemon() {
    Log.info("dockhelper daemon starting — pid \(ProcessInfo.processInfo.processIdentifier), uid \(getuid())")

    let config = Config.load(from: Paths.config)
    let inv = InterfaceInventory.resolve(config: config)
    Log.info("inventory: wifi=\(inv.wifiBSD) ethernet=\(inv.ethernetBSDs)")
    Log.info("config: strategy=\(config.strategy) debounce=\(config.debounceSeconds)s observe=\(config.observeSeconds)s v6=\(config.v6Mode.rawValue) override=\(Paths.overrideFlag)")
    if config.strategy != "ipoff" {
        Log.warn("config: strategy '\(config.strategy)' not implemented; using ipoff")
    }

    let reconciler = Reconciler(config: config, wifiBSD: inv.wifiBSD)
    let monitor = LinkMonitor(reconciler: reconciler, config: config, wifiBSD: inv.wifiBSD)

    // SIG_IGN the default disposition so the source — not the kernel's default terminate —
    // gets the signal. Sources run on the main queue (drained by CFRunLoopRun) and are
    // kept alive, with the monitor and reconciler, by withExtendedLifetime across the loop.
    let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            // Clean stop (bootout / unload / shutdown / kill -TERM): if we suppressed Wi-Fi and the
            // user hasn't since taken manual control, restore it before exiting — once the job is
            // gone nothing else will. (A crash bypasses this handler; KeepAlive's restart just
            // re-suppresses, so there's no strand there.)
            if let cap = StateStore.readCapture(),
               SCNetworkConfig.resolve(wifiBSD: inv.wifiBSD, override: config.wifiServiceOverride)?.hasStaticConfig != true {
                let sem = DispatchSemaphore(value: 0)
                Task {
                    _ = await Suppressor.restore(service: cap.service)
                    StateStore.clearCapture()
                    sem.signal()
                }
                sem.wait()
                Log.info("caught signal \(sig); restored Wi-Fi (was suppressed); exiting.")
            } else {
                Log.info("caught signal \(sig); exiting (nothing to restore).")
            }
            exit(0)
        }
        src.resume()
        return src
    }

    monitor.start()
    Task { await reconciler.start() }

    Log.info("entering run loop")
    withExtendedLifetime((signalSources, monitor, reconciler)) {
        CFRunLoopRun()
    }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "run":
    runDaemon()
case "status":
    exit(Commands.status())
case "override":
    switch args.dropFirst().first {
    case "on", "engage", "pause":    exit(Commands.override(true))
    case "off", "release", "resume": exit(Commands.override(false))
    default: print("usage: dockhelper override on|off"); exit(2)
    }
case nil, "help", "-h", "--help":
    printUsage()
default:
    printUsage()
    exit(2)
}
