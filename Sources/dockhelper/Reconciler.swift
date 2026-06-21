import Foundation

/// The policy seam: desired Wi-Fi state = f(any wired link, override). An actor so the
/// SCDynamicStore callback thread and the observe loop funnel mutations through one isolation
/// domain — Swift-6 data-race-safe with no locks of our own.
///
/// "ipoff" is STICKY: suppression sets the Wi-Fi service's IP config (IPv4 off, IPv6 link-local),
/// which the OS then holds on its own — nothing fights it, so there is no re-assert / backstop /
/// restore-watchdog. The durable capture file (`Paths.capture`) is the source of truth for "am I
/// suppressed": its PRESENCE gates RE-CAPTURE (never overwrite the recorded baseline), while
/// actuation is always (re-)applied to match desired state — so a reboot-while-docked re-applies
/// suppression idempotently without depending on the OS having persisted it.
actor Reconciler {
    enum Desired: String { case normal, suppressed }

    private let config: Config
    private let wifiBSD: String
    private var acted: Desired?
    private var inFlight = false
    private var debounceTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var pendingSettle: Desired?
    private var lastObservedKey: String?

    init(config: Config, wifiBSD: String) {
        self.config = config
        self.wifiBSD = wifiBSD
    }

    /// Reconcile to current state at launch (no debounce) and start the observe loop. Idempotent
    /// via the capture file, so a crash or a reboot-while-docked resumes correctly.
    func start() async {
        let snap = NetProbe.snapshot(config: config)
        Log.info("initial: anyWired=\(snap.anyWiredActive) wifiAssoc=\(snap.wifiAssociated) primary=\(snap.primaryInterface ?? "-") hasCapture=\(StateStore.hasCapture())")
        await applyTransition(to: desiredState(snap), snap: snap, reason: "startup")
        startObserveLoop()
    }

    // MARK: - Inputs

    func handleEvent(_ snap: NetSnapshot) {
        let desired = desiredState(snap)
        if desired != acted {
            Log.debug("event: desired \(acted?.rawValue ?? "nil")→\(desired.rawValue) (anyWired=\(snap.anyWiredActive)); debouncing")
            scheduleSettle(desired)
        }
    }

    private func desiredState(_ snap: NetSnapshot) -> Desired {
        if FileManager.default.fileExists(atPath: Paths.overrideFlag) { return .normal }
        return snap.anyWiredActive ? .suppressed : .normal
    }

    // MARK: - Debounced settle (desired-state transitions)

    private func scheduleSettle(_ desired: Desired) {
        // Idempotent: if a settle for this same target is already pending, DON'T reset the timer.
        // The observe loop calls this every tick while desired != acted; without this guard an
        // observe interval shorter than the debounce window perpetually re-arms it so it never fires
        // — which stranded the state machine in the disassociate-era code.
        if pendingSettle == desired { return }
        pendingSettle = desired
        debounceTask?.cancel()
        let window = Duration.seconds(config.debounceSeconds)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            if Task.isCancelled { return }
            await self?.settle(desired)
        }
    }

    private func settle(_ desired: Desired) async {
        pendingSettle = nil
        let snap = NetProbe.snapshot(config: config)
        let now = desiredState(snap)
        guard now == desired else {           // flipped back during the window — re-handle
            Log.debug("settle: desired changed during debounce (\(desired.rawValue)→\(now.rawValue))")
            handleEvent(snap)
            return
        }
        guard desired != acted else { return }
        await applyTransition(to: desired, snap: snap, reason: "settled")
    }

    // MARK: - Actuation

    /// The ONLY mutator of `acted`. Async — it awaits the off-actor `networksetup` writes, so the
    /// actor is released at each `await`. `inFlight` blocks a second event/observe from
    /// double-actuating during that window; the loop re-converges once it clears.
    private func applyTransition(to desired: Desired, snap: NetSnapshot, reason: String) async {
        guard !inFlight else {
            Log.debug("apply: write in flight, deferring \(desired.rawValue)(\(reason))")
            return
        }
        inFlight = true
        defer { inFlight = false }

        switch desired {
        case .suppressed:
            let hadCapture = StateStore.hasCapture()
            if !hadCapture {
                // Fresh suppression: fail closed unless the service is plain DHCP + IPv6-automatic,
                // then record the baseline before touching anything.
                let resolved = SCNetworkConfig.resolve(wifiBSD: wifiBSD, override: config.wifiServiceOverride)
                guard let r = resolved, r.isPlainDHCP else {
                    let why = resolved.map { "v4=\($0.v4Method ?? "?") v6=\($0.v6Method ?? "?")" } ?? "unresolved"
                    Log.warn("suppress(\(reason)): Wi-Fi not plain DHCP/automatic (\(why)) — NOT suppressing (fail-closed)")
                    acted = .normal
                    logState(snap, desired: .normal, action: "skip-nonstandard(\(reason))")
                    return
                }
                StateStore.writeCapture(Capture(service: r.serviceName, v4Method: r.v4Method ?? "",
                                                v6Method: r.v6Method ?? "", capturedAt: Log.timestamp()))
            }
            // Apply (or, on resume, re-apply) suppression. Service from the recorded baseline; SC
            // resolve only as a fallback if the capture is somehow unreadable.
            guard let service = StateStore.readCapture()?.service
                ?? SCNetworkConfig.resolve(wifiBSD: wifiBSD, override: config.wifiServiceOverride)?.serviceName else {
                Log.warn("suppress(\(reason)): Wi-Fi service unresolvable — cannot suppress")
                acted = .normal
                logState(snap, desired: .normal, action: "suppress-unresolved(\(reason))")
                return
            }
            await Suppressor.suppress(service: service, v6: config.v6Mode)
            acted = .suppressed
            logState(snap, desired: .suppressed, action: hadCapture ? "suppress-resume(\(reason))" : "suppress(\(reason))")

        case .normal:
            if StateStore.hasCapture() {
                let service = StateStore.readCapture()?.service
                    ?? SCNetworkConfig.resolve(wifiBSD: wifiBSD, override: config.wifiServiceOverride)?.serviceName
                if let service {
                    await Suppressor.restore(service: service)
                } else {
                    Log.warn("restore(\(reason)): capture present but service unresolvable — clearing without restore")
                }
                StateStore.clearCapture()
                acted = .normal
                logState(snap, desired: .normal, action: "restore(\(reason))")
            } else {
                acted = .normal
                logState(snap, desired: .normal, action: "normal-noop(\(reason))")
            }
        }
    }

    // MARK: - Observe loop (read-only sampling + override polling + missed-event safety net)

    private func observeTick() async {
        let snap = NetProbe.snapshot(config: config)
        let desired = desiredState(snap)
        if desired != acted {
            Log.debug("observe: desired \(acted?.rawValue ?? "nil")→\(desired.rawValue); reconciling")
            scheduleSettle(desired)
        }
        let overrideOn = FileManager.default.fileExists(atPath: Paths.overrideFlag)
        let key = "\(overrideOn)|\(snap.anyWiredActive)|\(snap.wifiAssociated)|\(snap.wifiHasRoutableIPv4)|\(snap.primaryInterface ?? "-")|\(snap.wifiPowerOn)"
        if key != lastObservedKey {
            lastObservedKey = key
            logState(snap, desired: acted ?? desired, action: "observe")
        }
    }

    private func startObserveLoop() {
        observeTask?.cancel()
        let interval = Duration.seconds(config.observeSeconds)
        observeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                await self?.observeTick()
            }
        }
    }

    // MARK: - Output: stdout line + published state file

    private func logState(_ snap: NetSnapshot, desired: Desired, action: String) {
        let state = DaemonState(
            ts: Log.timestamp(),
            strategy: config.strategy,
            overrideEngaged: FileManager.default.fileExists(atPath: Paths.overrideFlag),
            anyWired: snap.anyWiredActive,
            wiredActive: snap.perWiredActive,
            wifiBSD: snap.wifiBSD,
            wifiAssoc: snap.wifiAssociated,
            wifiIP: snap.wifiHasRoutableIPv4,
            wifiPrimary: snap.wifiIsPrimary,
            primary: snap.primaryInterface,
            powerOn: snap.wifiPowerOn,
            desired: desired.rawValue,
            action: action)
        Log.raw(state.json())
        StateStore.write(state)
    }
}
