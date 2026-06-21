import Foundation

/// The policy seam: desired Wi-Fi state = f(any wired link, override). An actor so the
/// SCDynamicStore callback thread and the observe loop funnel mutations through one isolation
/// domain — Swift-6 data-race-safe with no locks of our own.
///
/// "ipoff" is STICKY: suppression sets the Wi-Fi service's IP config (IPv4 off, IPv6 link-local),
/// which the OS then holds on its own — nothing fights it, so there is no re-assert / backstop /
/// restore-watchdog. The durable capture file (`Paths.capture`) is the source of truth for "am I
/// suppressed": its PRESENCE gates RE-CAPTURE (never overwrite the recorded baseline), while
/// actuation is always (re-)applied to match desired state.
///
/// State advances ONLY on a confirmed-successful `networksetup` write (`Suppressor` returns Bool);
/// a failed write leaves `acted`/the capture file untouched so the observe loop retries — fast
/// (`fastRetry`) for ~2 min, then slow (`slowRetry`), tracked by `failureStreak`. Before acting it
/// re-reads the live config and stands down if the user has taken manual control (a static IP), so
/// it never clobbers a non-standard config.
actor Reconciler {
    enum Desired: String { case normal, suppressed }

    // Retry cadence after a failed write: fast for ~2 min (fastRetryAttempts × fastRetry), then slow.
    private static let fastRetry = Duration.seconds(5)
    private static let slowRetry = Duration.seconds(60)
    private static let fastRetryAttempts = 24

    private let config: Config
    private let wifiBSD: String
    private var acted: Desired?
    private var inFlight = false
    private var failureStreak = 0          // consecutive failed writes; 0 = healthy
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
        guard let snap = NetProbe.snapshot(config: config) else {
            Log.warn("initial: probe unavailable; deferring reconcile to the observe loop")
            startObserveLoop()
            return
        }
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
        } else if failureStreak != 0 {
            failureStreak = 0          // converged (desired matches what we did) — clear stale backoff
        }
    }

    private func desiredState(_ snap: NetSnapshot) -> Desired {
        if FileManager.default.fileExists(atPath: Paths.overrideFlag) { return .normal }
        return snap.anyWiredActive ? .suppressed : .normal
    }

    // MARK: - Debounced settle (desired-state transitions; also the retry timer)

    private func scheduleSettle(_ desired: Desired) {
        // Idempotent: if a settle for this same target is already pending, DON'T reset the timer.
        // The observe loop calls this every tick while desired != acted; without this guard an
        // observe interval shorter than the debounce window perpetually re-arms it so it never fires.
        if pendingSettle == desired { return }
        pendingSettle = desired
        debounceTask?.cancel()
        // A fresh transition rides the debounce window; once writes start failing, this same timer
        // becomes the retry timer and stretches per the backoff schedule.
        let window: Duration =
            failureStreak == 0 ? .seconds(config.debounceSeconds) :
            failureStreak < Self.fastRetryAttempts ? Self.fastRetry :
            Self.slowRetry
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            if Task.isCancelled { return }
            await self?.settle(desired)
        }
    }

    private func settle(_ desired: Desired) async {
        pendingSettle = nil
        guard let snap = NetProbe.snapshot(config: config) else {
            Log.debug("settle: probe unavailable; observe loop will retry")
            return
        }
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
    /// double-actuating during that window; the loop re-converges once it clears. `acted` and the
    /// capture file advance ONLY on a confirmed-successful write; on failure they're left as-is so
    /// the observe loop retries on the backoff schedule.
    private func applyTransition(to desired: Desired, snap: NetSnapshot, reason: String) async {
        guard !inFlight else {
            Log.debug("apply: write in flight, deferring \(desired.rawValue)(\(reason))")
            return
        }
        inFlight = true
        defer { inFlight = false }

        // Read the live configured methods + service name once; used for the fail-closed gate, the
        // never-clobber-a-static-config stand-down, and as a service-name fallback.
        let live = SCNetworkConfig.resolve(wifiBSD: wifiBSD, override: config.wifiServiceOverride)

        switch desired {
        case .suppressed:
            let hadCapture = StateStore.hasCapture()
            // Resume after a restart, but the user has since taken manual control with a static IP:
            // stand down (fail-closed) rather than stripping their config.
            if hadCapture, live?.hasStaticConfig == true {
                StateStore.clearCapture()
                markActed(.normal)
                logState(snap, desired: .normal, action: "abandon-user-static(\(reason))")
                return
            }
            if !hadCapture {
                // Fresh suppression: fail closed unless plain DHCP; record the baseline first.
                guard let r = live, r.isPlainDHCP else {
                    let why = live.map { "v4=\($0.v4Method ?? "?") v6=\($0.v6Method ?? "?")" } ?? "unresolved"
                    Log.warn("suppress(\(reason)): Wi-Fi not plain DHCP (\(why)) — NOT suppressing (fail-closed)")
                    markActed(.normal)
                    logState(snap, desired: .normal, action: "skip-nonstandard(\(reason))")
                    return
                }
                StateStore.writeCapture(Capture(service: r.serviceName, v4Method: r.v4Method ?? "",
                                                v6Method: r.v6Method ?? "", capturedAt: Log.timestamp()))
            }
            guard let service = StateStore.readCapture()?.service ?? live?.serviceName else {
                Log.warn("suppress(\(reason)): Wi-Fi service unresolvable — cannot suppress")
                markActed(.normal)
                logState(snap, desired: .normal, action: "suppress-unresolved(\(reason))")
                return
            }
            if await Suppressor.suppress(service: service, v6: config.v6Mode) {
                markActed(.suppressed)
                logState(snap, desired: .suppressed, action: hadCapture ? "suppress-resume(\(reason))" : "suppress(\(reason))")
            } else {
                noteFailure()
                logState(snap, desired: acted ?? .normal, action: "suppress-failed#\(failureStreak)(\(reason))")
            }

        case .normal:
            guard StateStore.hasCapture() else {
                markActed(.normal)
                logState(snap, desired: .normal, action: "normal-noop(\(reason))")
                return
            }
            // The user re-took manual control with a static IP since we suppressed: don't clobber it.
            if live?.hasStaticConfig == true {
                StateStore.clearCapture()
                markActed(.normal)
                logState(snap, desired: .normal, action: "abandon-user-static(\(reason))")
                return
            }
            guard let service = StateStore.readCapture()?.service ?? live?.serviceName else {
                StateStore.clearCapture()        // can't address it; nothing actionable to restore
                markActed(.normal)
                logState(snap, desired: .normal, action: "restore-unresolved(\(reason))")
                return
            }
            if await Suppressor.restore(service: service) {
                StateStore.clearCapture()
                markActed(.normal)
                logState(snap, desired: .normal, action: "restore(\(reason))")
            } else {
                noteFailure()
                logState(snap, desired: acted ?? .suppressed, action: "restore-failed#\(failureStreak)(\(reason))")
            }
        }
    }

    /// Reached a settled conclusion (a successful write, or a deliberate stand-down): record it and
    /// clear the retry backoff.
    private func markActed(_ state: Desired) {
        acted = state
        failureStreak = 0
    }

    /// A `networksetup` write failed: leave `acted`/the capture file as-is so the observe loop
    /// retries, and advance the streak so `scheduleSettle` stretches the retry window.
    private func noteFailure() {
        failureStreak += 1
    }

    // MARK: - Observe loop (read-only sampling + override polling + missed-event/retry safety net)

    private func observeTick() async {
        guard let snap = NetProbe.snapshot(config: config) else { return }
        let desired = desiredState(snap)
        if desired != acted {
            Log.debug("observe: desired \(acted?.rawValue ?? "nil")→\(desired.rawValue); reconciling")
            scheduleSettle(desired)
        } else if failureStreak != 0 {
            failureStreak = 0          // converged — clear stale backoff
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
