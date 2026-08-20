import AppKit
import CoreGraphics
import Foundation

@MainActor
final class Capsomnia: NSObject, NSApplicationDelegate {
    private var lastAppliedState: Bool?
    private var failedSleepState: Bool?
    // Monotonic, not wall-clock. `Date` arithmetic silently stretched every one of
    // these windows by however far the clock jumped backwards — an NTP correction
    // shortly after boot is the ordinary way that happens — and stale state was
    // trusted for the length of the jump. nil means "no deadline pending".
    private var nextSleepStateRetryAt: ContinuousClock.Instant?
    private var nextSleepStateVerificationAt: ContinuousClock.Instant?
    private var nextDisplaySleepRetryAt: ContinuousClock.Instant?
    private var didRequestDisplaySleepForClosedLid = false
    private var hasLoggedMissingClamshellState = false
    private var hasLoggedMissingDisplayState = false
    private var hasLoggedMissingSleepState = false
    private var shouldRestoreSleepOnTerminate = true
    /// Set only by the menu's Quit action, right before calling `NSApp.terminate(nil)`,
    /// and consumed (reset to false) the moment `applicationShouldTerminate` reads it —
    /// so a later system-initiated termination (logout, Force Quit) that happens to
    /// share the same call path never inherits an explicit-quit intent it didn't have.
    private var isExplicitUserQuit = false
    /// Tracks whether `applicationShouldTerminate`'s explicit-quit flow already ran the
    /// exit-time restore for the termination in progress, so the `applicationWillTerminate`
    /// call that follows does not repeat it — and, critically, gives that debt BACK when
    /// the user cancels the termination. See `QuitRestoreLedger`.
    private var quitRestoreLedger = QuitRestoreLedger()
    /// Held open for the life of the process; closing it would release the lock.
    private var instanceLockDescriptor: Int32 = -1
    private var pollingTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private var menuPresenter: MenuPanelPresenter?
    private var menuModel: MenuModel?
    private var settingsWindowController: SettingsWindowController?
    private let onImage = DotImage.make(color: Brand.led)
    private let offImage = DotImage.make(color: NSColor(calibratedWhite: 0.58, alpha: 1.0))
    private let errorImage = DotImage.make(color: .systemRed)
    /// Held by the battery floor: the mode is armed, the floor is holding it off. A ring
    /// rather than another shade of dot — at menu-bar size a colour change alone does not
    /// read as a different state.
    private let heldImage = DotImage.makeRing(color: Brand.led)
    private let helperRetryInterval: TimeInterval = 5
    private let sleepStateVerificationInterval: TimeInterval = 10
    private var cachedBattery: BatteryReader.Snapshot?
    private var cachedBatteryReadAt: ContinuousClock.Instant?
    private let batteryCacheInterval: TimeInterval = 5
    private let batteryFloorRecoverMargin = 5
    /// Explicit consent to keep running below the floor. Deliberately NOT persisted:
    /// after a relaunch — including one that followed a crash — the app must come back
    /// on the safe side rather than silently still overriding a safety limit.
    private var batteryFloorOverride = false
    /// Whether the closed-lid guard is currently holding the intent against an external
    /// Caps Lock off. Tracked only so engage/release each log ONCE instead of per poll.
    private var externalCapsOffHeld = false
    /// The reasoned keep-awake state, and the copy of it the UI has already been told
    /// about. The status can change without the applied on/off state changing (the floor
    /// engaging, an override being taken), and those changes have to reach the menu bar.
    private var keepAwakeStatus: KeepAwakeStatus = .normal
    private var publishedStatus: KeepAwakeStatus?
    /// Beyond this age a cached power read is treated as no read at all. Falling back to
    /// an arbitrarily old snapshot would let the floor act on a charge from hours ago.
    private let batteryStaleInterval: TimeInterval = 60

    /// Persisted so a relaunch cannot silently un-latch: the same charge used to mean
    /// "released" or "awake" depending on whether the app had restarted since. Safe to
    /// persist because the un-latch conditions (AC, or charge back above the recover
    /// threshold) are re-evaluated from a fresh read on every poll, so a latch cannot
    /// outlive the discharge that set it.
    private var batteryFloorLatched: Bool {
        get {
            Preferences.batteryFloorLatched
                && Preferences.batteryFloorLatchedFloor == Preferences.batteryFloorPercent
        }
        set {
            // Written from the 250ms poll, so it must not touch UserDefaults when
            // nothing changed. (Measured cost of the unconditional write was
            // negligible; it is still a write nobody asked for.)
            guard Preferences.batteryFloorLatched != newValue
                || Preferences.batteryFloorLatchedFloor != Preferences.batteryFloorPercent else {
                return
            }
            Preferences.batteryFloorLatched = newValue
            Preferences.batteryFloorLatchedFloor = Preferences.batteryFloorPercent
        }
    }

    private var batteryFloorRecoverPercent: Int {
        BatteryFloorPolicy.recoverPercent(
            floorPercent: Preferences.batteryFloorPercent,
            recoverMargin: batteryFloorRecoverMargin
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfNewerInteractiveDuplicate() {
            return
        }

        Preferences.registerDefaults()
        let shouldShowInitialSetup = Preferences.consumeForceWelcomeOnNextLaunch()
            || !Preferences.didCompleteInitialSetup

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsNotification),
            name: openSettingsNotificationName,
            object: appLabel
        )

        NSApp.setActivationPolicy(.accessory)
        syncStatusItemVisibility()
        installSignalHandlers()
        installPollingMonitor()
        log("start backdrop=\(GlassBackdrop.usesLiquidGlass ? "liquid_glass" : "vibrancy")")
        logStaleSleepStateBreadcrumbIfPresent()
        applyCurrentCapsLockState(reason: "startup")

        if shouldShowInitialSetup {
            showSettingsWindow(page: .initialPreferences)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow(page: currentSettingsPage())
        return true
    }

    /// `disablesleep` is a systemwide `pmset` flag: reconciling it at the START of every
    /// launch (see `applicationDidFinishLaunching` — `lastAppliedState` resets to `nil`,
    /// so the first `apply()` always issues a real helper call for the freshly-computed
    /// desired state) is the real fix for a breadcrumb left behind by a failed exit.
    /// This is only the log line that makes that reconciliation an explicit, observed
    /// fact instead of a side effect nobody would notice a future refactor breaking.
    private func logStaleSleepStateBreadcrumbIfPresent() {
        guard let breadcrumb = SleepStateBreadcrumbStore.read() else { return }
        log(
            "startup unclean_exit_detected owned=\(breadcrumb.owned) "
                + "prior_sleep_disabled=\(breadcrumb.priorSleepDisabled.map { $0 ? "true" : "false" } ?? "unknown") "
                + "generation=\(breadcrumb.generation) pid=\(breadcrumb.pid) set_at=\(breadcrumb.setAt)"
        )
    }

    /// This is the ONLY place termination can be cancelled — by the time
    /// `applicationWillTerminate` runs, AppKit has already committed to quitting and
    /// there is no API to back out. D6 (a visible, user-actionable failure on the
    /// explicit Quit path) therefore has to live here, not in `applicationWillTerminate`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let isExplicit = isExplicitUserQuit
        // Consumed immediately: a later system-initiated termination (logout, Force
        // Quit) that happens to reach this same delegate method must not inherit an
        // explicit-quit intent it never actually had.
        isExplicitUserQuit = false

        guard shouldRestoreSleepOnTerminate, isExplicit else { return .terminateNow }
        return performExplicitQuitRestore()
    }

    /// The explicit-Quit restore attempt. Deliberately does NOT go through
    /// `ExitRestoreGate` — that gate exists solely to deduplicate the real race between
    /// `applicationWillTerminate` and the SIGINT/SIGTERM handler for one termination
    /// event; this path is single-owner and sequential (driven by the user clicking
    /// "Try Again"), and claiming a one-shot-forever gate here would make a SECOND Quit
    /// attempt, after the user cancelled the first failure's alert, silently skip the
    /// restore instead of retrying it — masking the exact failure D6 exists to surface.
    /// `quitRestoreLedger` is what stops the `applicationWillTerminate` call
    /// that follows a `.terminateNow` return from repeating this same restore.
    private func performExplicitQuitRestore() -> NSApplication.TerminateReply {
        let result = runHelper("off", timeout: Self.exitHelperTimeout)
        log("quit restore_off helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
        quitRestoreLedger.markHandled()

        guard result.status == 0 else {
            let reply = presentRestoreFailureAlert()
            if reply == .terminateCancel {
                // The app keeps running, so the restore this flow claimed is no longer
                // paid for: hand the debt back before the next termination arrives on a
                // path that would otherwise trust the claim and skip the restore.
                quitRestoreLedger.terminationCancelled()
            }
            return reply
        }
        SleepStateBreadcrumbStore.clear()
        return .terminateNow
    }

    /// A plain `NSAlert`, deliberately outside the glass-panel visual system (spec D6).
    /// Never loops automatically — every additional attempt is one more explicit click.
    private func presentRestoreFailureAlert() -> NSApplication.TerminateReply {
        let strings = AppStrings.current()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.exitRestoreFailedTitle
        alert.informativeText = "\(strings.exitRestoreFailedMessage)\n\n\(sleepRestoreCommand)"
        alert.addButton(withTitle: strings.copyCommand)
        alert.addButton(withTitle: strings.tryAgain)
        alert.addButton(withTitle: strings.quitAnyway)

        // Capsomnia is `.accessory` (LSUIElement) and normally has no active window, so
        // it is not the front app when the user picks Quit from the menu-bar panel.
        // Without this, `runModal()` puts a modal window up behind whatever the user was
        // actually looking at: the Quit appears to do nothing, and the app is left alive
        // and blocked on a dialog nobody can see — the worst possible outcome for an
        // alert whose entire job is to make a silent failure visible.
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sleepRestoreCommand, forType: .string)
            log("quit restore_off command_copied")
            // Cancel: give the user the chance to run the command themselves before
            // quitting for real, instead of racing them out the door.
            return .terminateCancel
        case .alertSecondButtonReturn:
            return performExplicitQuitRestore()
        default:
            log("quit restore_off quit_anyway_after_failure")
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard shouldRestoreSleepOnTerminate, quitRestoreLedger.shouldRestoreOnWillTerminate else { return }

        guard Self.exitRestoreGate.claim() else {
            log("terminate restore_off skipped=already_claimed")
            return
        }

        let result = runHelper("off", timeout: Self.exitHelperTimeout)
        log("terminate restore_off helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
        if result.status == 0 {
            SleepStateBreadcrumbStore.clear()
        }
    }

    /// An advisory file lock decides who runs, not a PID comparison against
    /// `runningApplications`. That query is a snapshot: a login-item launch racing a
    /// manual open could have both instances see an empty list, both survive, and both
    /// drive the same root helper from their own poll loops. The lock is held by the fd
    /// for the life of the process, so it is released however the process dies —
    /// including SIGKILL.
    private func terminateIfNewerInteractiveDuplicate() -> Bool {
        guard !acquireSingleInstanceLock() else { return false }

        shouldRestoreSleepOnTerminate = false
        DistributedNotificationCenter.default().post(
            name: openSettingsNotificationName,
            object: appLabel,
            userInfo: nil
        )
        // Best-effort courtesy only: bringing the incumbent forward. Whether we exit was
        // already decided by the lock.
        NSRunningApplication
            .runningApplications(withBundleIdentifier: appLabel)
            .first { !$0.isTerminated && $0.processIdentifier != getpid() }?
            .activate(options: [])
        log("duplicate_instance lock_held_elsewhere terminate_without_restore")
        NSApp.terminate(nil)
        return true
    }

    /// True when this process now owns the lock. A lock file that cannot be created at
    /// all returns true: failing to start is worse than the duplicate it would prevent.
    private func acquireSingleInstanceLock() -> Bool {
        let path = logDirectoryURL.appendingPathComponent("instance.lock").path
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            log("instance_lock unavailable path=\(path) errno=\(errno)")
            return true
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        instanceLockDescriptor = descriptor
        return true
    }

    @objc private func handleOpenSettingsNotification(_ notification: Notification) {
        showSettingsWindow(page: currentSettingsPage())
    }

    /// The state Capsomnia is acting on for status display: the last state it applied,
    /// falling back to the mode's intent before the first apply.
    private var currentCapsLockState: Bool {
        if let lastAppliedState {
            return lastAppliedState
        }
        switch Preferences.keepAwakeMode {
        case .off:
            return false
        case .auto:
            return true
        case .capsLock:
            return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        }
    }

    private func syncStatusItemVisibility() {
        if Preferences.showMenuBarIcon {
            if statusItem == nil {
                installStatusItem()
            }

            refreshStatus(capsLockOn: currentCapsLockState)
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        statusItem = item

        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = appName
            button.target = self
            button.action = #selector(togglePopover)
        }

        setupPopover()
        updateStatus(capsLockOn: false)
    }

    private func setupPopover() {
        let model = makeMenuModel()
        menuModel = model
        // A panel we place and resize ourselves, instead of NSPopover: AppKit re-places
        // a popover whose content size changes and lands on the wrong display.
        menuPresenter = MenuPanelPresenter(controller: StatusPopoverController(model: model))
    }

    private func makeMenuModel() -> MenuModel {
        let model = MenuModel(strings: currentMenuStrings())
        model.onSelectMode = { [weak self] mode in self?.setKeepAwakeMode(mode) }
        model.onSetFloorEnabled = { [weak self] enabled in self?.setBatteryFloorEnabled(enabled) }
        model.onSetFloorPercent = { [weak self] percent in
            self?.setBatteryFloorEnabled(true)
            self?.setBatteryFloorPercent(percent)
        }
        model.onSetFloorOverride = { [weak self] enabled in self?.setBatteryFloorOverride(enabled) }
        model.onSetShowMenuBarIcon = { [weak self] enabled in self?.setShowMenuBarIcon(enabled) }
        model.onSelectLanguage = { [weak self] language in self?.setLanguage(language) }
        model.onOpenCapsomnia = { [weak self] in self?.openCapsomnia() }
        model.onQuit = { [weak self] in self?.quit() }
        syncMenuModel(model)
        return model
    }

    private func currentMenuStrings() -> MenuStrings {
        let s = AppStrings.current()
        return MenuStrings(
            appName: appName,
            keepAwakeHeading: s.keepAwakeHeading,
            modeOff: s.modeOff,
            modeCapsLock: s.modeCapsLock,
            modeAuto: s.modeAuto,
            batteryFloorMenu: s.batteryFloorMenu,
            showMenuBarIcon: s.showMenuBarIcon,
            language: s.language,
            openCapsomnia: s.openCapsomnia,
            quit: s.quit,
            statusHeld: s.statusHeld,
            batteryFloorHeldFormat: s.batteryFloorHeldFormat,
            batteryFloorOverride: s.batteryFloorOverride,
            batteryFloorOverrideActive: s.batteryFloorOverrideActive,
            batteryFloorOverrideSubtitleFormat: s.batteryFloorOverrideSubtitleFormat
        )
    }

    private func syncMenuModel(_ model: MenuModel) {
        model.strings = currentMenuStrings()
        model.mode = Preferences.keepAwakeMode
        model.floorEnabled = Preferences.batteryFloorEnabled
        model.floorPercent = Preferences.batteryFloorPercent
        model.showMenuBarIcon = Preferences.showMenuBarIcon
        model.language = Preferences.language
        model.keepingAwake = currentCapsLockState
        model.heldByFloor = keepAwakeStatus.isHeldByFloor
        model.overridingFloor = keepAwakeStatus.isOverriding
        model.batteryPercent = keepAwakeStatus.percent ?? cachedBattery?.percent
        model.floorRecoverPercent = batteryFloorRecoverPercent
        model.floorCriticalPercent = BatteryFloorPolicy.criticalPercent
        model.helperFailing = failedSleepState != nil
    }

    /// Kept as the single "menu changed" entry point so the existing setters can call it
    /// exactly where they used to rebuild the NSMenu; now it just refreshes the live model.
    private func rebuildStatusMenu() {
        guard let model = menuModel else { return }
        syncMenuModel(model)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let menuPresenter else { return }
        if menuPresenter.isShown {
            menuPresenter.close()
        } else {
            rebuildStatusMenu()
            menuPresenter.show(under: button)
        }
    }

    /// Note what is NOT here: the hysteresis latch is not cleared. Choosing a mode says
    /// what you want, it says nothing about the battery — clearing the latch here meant
    /// that between the floor and the recover threshold the same charge produced
    /// "released" or "awake" depending on whether the user had happened to touch the
    /// mode, which is the undocumented escape hatch that made this feel unstable.
    /// Turning the mode fully off does end an override: that is consent withdrawn.
    private func setKeepAwakeMode(_ mode: KeepAwakeMode) {
        guard Preferences.keepAwakeMode != mode else { return }
        Preferences.keepAwakeMode = mode
        if mode == .off, batteryFloorOverride {
            batteryFloorOverride = false
            log("battery_floor override_expired reason=mode_off")
        }
        rebuildStatusMenu()
        applyCurrentCapsLockState(reason: "mode_change")
        refreshStatus(capsLockOn: currentCapsLockState)
        log("preference keep_awake_mode=\(mode.rawValue)")
    }

    /// The floor setters DO reset the latch and any override, and the difference from
    /// the mode setter is deliberate: editing the floor redefines the threshold the
    /// hysteresis is measured against, so the old latch describes a policy that no longer
    /// exists. The equality guard matters — the menu's floor pills call this before
    /// setting a percent, so without it every pill tap reset the safety state.
    private func setBatteryFloorEnabled(_ enabled: Bool) {
        guard Preferences.batteryFloorEnabled != enabled else { return }
        Preferences.batteryFloorEnabled = enabled
        resetBatteryFloorState()
        rebuildStatusMenu()
        applyCurrentCapsLockState(reason: "battery_floor_change")
        log("preference battery_floor_enabled=\(enabled ? "on" : "off")")
    }

    private func setBatteryFloorPercent(_ percent: Int) {
        guard Preferences.batteryFloorPercent != percent else { return }
        Preferences.batteryFloorPercent = percent
        resetBatteryFloorState()
        rebuildStatusMenu()
        applyCurrentCapsLockState(reason: "battery_floor_percent")
        log("preference battery_floor_percent=\(percent)")
    }

    private func resetBatteryFloorState() {
        batteryFloorLatched = false
        batteryFloorOverride = false
    }

    @objc private func openCapsomnia() {
        showSettingsWindow(page: currentSettingsPage())
    }

    @objc private func quit() {
        log("menu_quit")
        isExplicitUserQuit = true
        NSApp.terminate(nil)
    }

    private func showSettingsWindow(page: SettingsPage) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                onShowMenuBarIconChange: { [weak self] enabled in
                    self?.setShowMenuBarIcon(enabled)
                },
                onLanguageChange: { [weak self] language in
                    self?.setLanguage(language)
                },
                onLaunchAtLoginChange: { [weak self] enabled in
                    self?.setLaunchAtLogin(enabled)
                },
                onDisplaySleepOnLidCloseChange: { [weak self] enabled in
                    self?.setDisplaySleepOnLidClose(enabled)
                },
                onIgnoreExternalCapsOffChange: { [weak self] enabled in
                    self?.setIgnoreExternalCapsOffWhileLidClosed(enabled)
                },
                onKeepAwakeModeChange: { [weak self] mode in
                    self?.setKeepAwakeMode(mode)
                },
                onBatteryFloorEnabledChange: { [weak self] enabled in
                    self?.setBatteryFloorEnabled(enabled)
                },
                onBatteryFloorPercentChange: { [weak self] percent in
                    self?.setBatteryFloorPercent(percent)
                },
                onFinishInitialSetup: { [weak self] in
                    Preferences.didCompleteInitialSetup = true
                    self?.log("initial_setup_complete")
                }
            )
        }

        settingsWindowController?.show(page: page)
    }

    private func currentSettingsPage() -> SettingsPage {
        Preferences.didCompleteInitialSetup ? .settings : .initialPreferences
    }

    private func setShowMenuBarIcon(_ enabled: Bool) {
        Preferences.showMenuBarIcon = enabled
        syncStatusItemVisibility()
        rebuildStatusMenu()
        log("preference show_menu_bar_icon=\(enabled ? "on" : "off")")
    }

    private func setLanguage(_ language: AppLanguage) {
        guard Preferences.language != language else { return }
        Preferences.language = language
        rebuildStatusMenu()

        refreshStatus(capsLockOn: currentCapsLockState)
        settingsWindowController?.reloadText()
        log("preference language=\(language.rawValue)")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAgentManager.setEnabled(enabled)
            Preferences.launchAtLogin = enabled
            rebuildStatusMenu()
            log("preference launch_at_login=\(enabled ? "on" : "off")")
        } catch {
            rebuildStatusMenu()
            log("preference launch_at_login_error=\(error.localizedDescription)")
        }
    }

    private func setIgnoreExternalCapsOffWhileLidClosed(_ enabled: Bool) {
        Preferences.ignoreExternalCapsLockOffWhileLidClosed = enabled
        // Turning the guard OFF while it is holding must release on the spot, not on the
        // next flag change; re-apply so the poll's decision runs once with the new rule.
        applyCurrentCapsLockState(reason: "preference")
        log("preference ignore_external_caps_off_while_lid_closed=\(enabled ? "on" : "off")")
    }

    private func setDisplaySleepOnLidClose(_ enabled: Bool) {
        Preferences.displaySleepOnLidClose = enabled
        if enabled {
            evaluateDisplaySleepForClosedLid(capsLockOn: currentCapsLockState, reason: "preference")
        } else {
            didRequestDisplaySleepForClosedLid = false
        }
        log("preference display_sleep_on_lid_close=\(enabled ? "on" : "off")")
    }

    private func installPollingMonitor() {
        pollingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCurrentCapsLockState(reason: "poll") }
        }
        timer.tolerance = 0.05
        pollingTimer = timer
        // .default (not .common): the poll — which may spawn pmset on the 10s
        // verification tick — must NOT fire while a menu is being tracked, or the
        // subprocess hitches the click. Caps Lock is re-applied when tracking ends.
        RunLoop.main.add(timer, forMode: .default)
        log("polling_ready interval_ms=250 tolerance_ms=50")
    }

    private func applyCurrentCapsLockState(reason: String) {
        apply(capsLockOn: desiredKeepAwake(reason: reason), reason: reason)
        publishStatusIfChanged()
    }

    /// Cached power-source read (refreshed every `batteryCacheInterval`) so the 250ms
    /// poll never spins IOKit needlessly. A failed re-read falls back to the cached
    /// snapshot only while it is still recent: past that the answer is "unknown", which
    /// keeps the Mac awake rather than letting the floor act on a stale charge.
    private func batterySnapshot() -> BatteryReader.Snapshot? {
        let now = ContinuousClock.now
        if let cachedBattery, let readAt = cachedBatteryReadAt,
           readAt.duration(to: now) < .seconds(batteryCacheInterval) {
            return cachedBattery
        }
        if let fresh = BatteryReader.read() {
            cachedBattery = fresh
            cachedBatteryReadAt = now
            return fresh
        }
        guard let readAt = cachedBatteryReadAt,
              readAt.duration(to: now) < .seconds(batteryStaleInterval) else {
            cachedBattery = nil
            return nil
        }
        return cachedBattery
    }

    /// Single source of truth for whether to keep the Mac awake: user intent (mode)
    /// with a hysteresis-latched battery-floor safety, and the reason recorded alongside
    /// so the menu bar can say which of the two is talking. On battery below the floor it
    /// releases so the Mac can sleep with charge still in reserve (a flat battery would
    /// also drop remote access). Unreadable power state stays awake — reachability is
    /// the priority.
    private func desiredKeepAwake(reason: String) -> Bool {
        let intent: Bool
        switch Preferences.keepAwakeMode {
        case .off:
            intent = false
        case .capsLock:
            let flagOn = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
            // Closed-lid guard (ported from upstream v3.1.0, adapted — see
            // ClosedLidCapsLockGuard): an off observed while the lid is closed came from
            // an external source, so the intent holds instead of following it. The
            // clamshell read only happens on the rare poll where the flag is off while
            // the applied state was on, never on the steady 250ms path — which holds
            // only because `clamshellClosed` is an `@autoclosure`. It was a plain
            // parameter until 2026-08-20, and a plain parameter is evaluated before the
            // call: this IOKit lookup ran at 4Hz for the whole time Caps Lock was off,
            // exactly the steady path the sentence above promises it avoids.
            if !flagOn,
               ClosedLidCapsLockGuard.shouldHoldIntent(
                   preferenceEnabled: Preferences.ignoreExternalCapsLockOffWhileLidClosed,
                   mode: .capsLock,
                   capsLockFlagOn: flagOn,
                   lastAppliedKeepAwake: lastAppliedState,
                   clamshellClosed: ClamshellStateReader.isClosed()
               ) {
                intent = true
                if !externalCapsOffHeld {
                    externalCapsOffHeld = true
                    log("\(reason) external_caps_off_held clamshell=closed — intent held, flag=off")
                }
            } else {
                intent = flagOn
                if externalCapsOffHeld {
                    externalCapsOffHeld = false
                    log("\(reason) external_caps_off_released flag=\(flagOn ? "on" : "off")")
                }
            }
        case .auto:
            intent = true
        }

        let battery = batterySnapshot()
        expireBatteryFloorOverride(battery: battery)
        let result = BatteryFloorPolicy.decide(
            intent: intent,
            floorEnabled: Preferences.batteryFloorEnabled,
            floorPercent: Preferences.batteryFloorPercent,
            recoverMargin: batteryFloorRecoverMargin,
            onAC: battery?.onAC ?? false,
            percent: battery?.percent,
            batteryReadable: battery != nil,
            latched: batteryFloorLatched,
            overrideActive: batteryFloorOverride
        )
        batteryFloorLatched = result.latched
        keepAwakeStatus = result.status
        return result.keepAwake
    }

    /// The override is consent to run below the floor *now*. Reaching wall power ends
    /// the situation it was given for, and leaving it armed would silently skip the
    /// floor on the next discharge; at the critical charge it is refused anyway, so it
    /// is dropped rather than left to look active.
    private func expireBatteryFloorOverride(battery: BatteryReader.Snapshot?) {
        guard batteryFloorOverride else { return }
        if battery?.onAC == true {
            batteryFloorOverride = false
            log("battery_floor override_expired reason=ac")
            return
        }
        if let percent = battery?.percent, percent <= BatteryFloorPolicy.criticalPercent {
            batteryFloorOverride = false
            log("battery_floor override_expired reason=critical percent=\(percent)")
        }
    }

    private func setBatteryFloorOverride(_ enabled: Bool) {
        guard batteryFloorOverride != enabled else { return }
        batteryFloorOverride = enabled
        log("battery_floor override=\(enabled ? "on" : "off")")
        // Re-applies and, through publishStatusIfChanged, repaints the menu and the icon.
        applyCurrentCapsLockState(reason: "battery_floor_override")
    }

    /// Pushes a status change to the menu bar and the open menu, once per change. The
    /// applied on/off state can stay put while the reason for it changes (the floor
    /// engaging, an override being taken), and that used to reach nothing at all.
    private func publishStatusIfChanged() {
        guard keepAwakeStatus != publishedStatus else { return }
        let previous = publishedStatus
        publishedStatus = keepAwakeStatus
        logStatusChange(from: previous)
        rebuildStatusMenu()
        refreshStatus(capsLockOn: currentCapsLockState)
    }

    /// One line per change, never per poll. Diagnosing a released keep-awake used to mean
    /// correlating `pmset -g log` by hand, because the app logged `capslock=off` with no
    /// reason attached. The raw inputs go on the same line so a future "it flapped" can
    /// be settled from this log alone.
    private func logStatusChange(from previous: KeepAwakeStatus?) {
        let capsLockFlag = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        let battery = cachedBattery
        log(
            "keep_awake_status \(previous.map(describe) ?? "none")->\(describe(keepAwakeStatus)) "
                + "mode=\(Preferences.keepAwakeMode.rawValue) capslock_flag=\(capsLockFlag ? "on" : "off") "
                + "battery=\(battery?.percent.map(String.init) ?? "unknown") "
                + "power=\(battery.map { $0.onAC ? "ac" : "batt" } ?? "unknown") "
                + "floor=\(Preferences.batteryFloorEnabled ? "\(Preferences.batteryFloorPercent)" : "off") "
                + "recover=\(batteryFloorRecoverPercent) latched=\(batteryFloorLatched ? "yes" : "no")"
        )
    }

    private func describe(_ status: KeepAwakeStatus) -> String {
        switch status {
        case .awake: return "awake"
        case .normal: return "normal"
        case .heldByFloor: return "held_by_floor"
        case .overriding: return "overriding"
        case .awakePowerUnknown: return "awake_power_unknown"
        }
    }

    private func apply(capsLockOn: Bool, reason: String) {
        let now = ContinuousClock.now
        if failedSleepState == capsLockOn, let retryAt = nextSleepStateRetryAt, now < retryAt {
            return
        }

        if lastAppliedState == capsLockOn {
            if failedSleepState == nil, let verifyAt = nextSleepStateVerificationAt, now < verifyAt {
                evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: reason)
                return
            }

            guard let actualState = SleepStateReader.isDisabled() else {
                if !hasLoggedMissingSleepState {
                    log("\(reason) sleep_state_unavailable")
                    hasLoggedMissingSleepState = true
                }
                markSleepStateFailed(capsLockOn, at: now)
                return
            }

            hasLoggedMissingSleepState = false
            if actualState == capsLockOn {
                markSleepStateConfirmed(capsLockOn, at: now, reason: reason)
                return
            }

            log("\(reason) sleep_state_drift expected=\(capsLockOn ? "on" : "off") actual=\(actualState ? "on" : "off")")
        }

        let mode = capsLockOn ? "on" : "off"
        if capsLockOn, SleepStateBreadcrumbStore.read()?.owned != true {
            // Read BEFORE the helper call, and only on the first attempt of this
            // off->on cycle (retries would otherwise overwrite the true prior state
            // with whatever a partially-succeeded earlier attempt already changed it
            // to — see SleepStateBreadcrumbStore.markAttemptingOn's doc comment).
            SleepStateBreadcrumbStore.markAttemptingOn(priorSleepDisabled: SleepStateReader.isDisabled())
        }
        let result = runHelper(mode)
        // `keep_awake=`, not `capslock=`. The parameter is named capsLockOn but every caller passes
        // desiredKeepAwake(reason:) -- the DECISION, not the key. So in auto mode this line printed
        // `capslock=on` in the same second that logStatusChange printed `capslock_flag=off`, and the
        // two contradicted each other. Six such pairs exist in the log, all with mode=auto.
        //
        // Renamed 2026-07-30 after that contradiction cost real time: while investigating Tom's
        // network instability I read these two lines, concluded the app had a state desync, and was
        // about to report it as a defect. It is not one -- the behaviour is correct -- but a log that
        // says `capslock=on` while Caps Lock is off will mislead the next reader the same way.
        log("\(reason) keep_awake=\(mode) helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")

        guard result.status == 0 else {
            markSleepStateFailed(capsLockOn, at: now, resetVerification: false)
            return
        }

        lastAppliedState = capsLockOn
        let confirmedState = SleepStateReader.isDisabled()
        guard confirmedState == Optional(capsLockOn) else {
            hasLoggedMissingSleepState = confirmedState == nil
            log("\(reason) sleep_state_confirmation_failed expected=\(mode) actual=\(confirmedState.map { $0 ? "on" : "off" } ?? "unknown")")
            markSleepStateFailed(capsLockOn, at: now)
            return
        }

        markSleepStateConfirmed(capsLockOn, at: now, reason: reason)
    }

    private func markSleepStateFailed(
        _ capsLockOn: Bool,
        at now: ContinuousClock.Instant,
        resetVerification: Bool = true
    ) {
        failedSleepState = capsLockOn
        nextSleepStateRetryAt = now.advanced(by: .seconds(helperRetryInterval))
        if resetVerification {
            nextSleepStateVerificationAt = nextSleepStateRetryAt
        }
        // The menu bar goes to the error dot here, so the open menu must stop claiming
        // the state was applied: `lastAppliedState` is set optimistically before the
        // confirming read, and without this the popover showed a confident green ON
        // beside a red menu-bar icon.
        menuModel?.helperFailing = true
        updateStatusError()
    }

    private func markSleepStateConfirmed(
        _ capsLockOn: Bool,
        at now: ContinuousClock.Instant,
        reason: String
    ) {
        hasLoggedMissingSleepState = false
        failedSleepState = nil
        menuModel?.helperFailing = false
        nextSleepStateRetryAt = nil
        nextSleepStateVerificationAt = now.advanced(by: .seconds(sleepStateVerificationInterval))
        if !capsLockOn {
            SleepStateBreadcrumbStore.clear()
        }
        // Keep the popover's status pill / LED live even while it is open (e.g. the
        // battery floor releasing keep-awake flips it to OFF without a reopen).
        menuModel?.keepingAwake = capsLockOn
        syncStatusItemVisibility()
        evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: reason)
    }

    private func evaluateDisplaySleepForClosedLid(capsLockOn: Bool, reason: String) {
        guard Preferences.displaySleepOnLidClose else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = nil
            return
        }

        guard capsLockOn else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = nil
            return
        }

        guard let clamshellClosed = ClamshellStateReader.isClosed() else {
            didRequestDisplaySleepForClosedLid = false
            if !hasLoggedMissingClamshellState {
                log("\(reason) clamshell_state_unavailable")
                hasLoggedMissingClamshellState = true
            }
            return
        }
        hasLoggedMissingClamshellState = false

        guard clamshellClosed else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = nil
            return
        }

        let externalDisplayConnected = ExternalDisplayReader.isConnected()
        if externalDisplayConnected != nil {
            hasLoggedMissingDisplayState = false
        }
        guard DisplaySleepPolicy.shouldRequestDisplaySleep(
            externalDisplayConnected: externalDisplayConnected
        ) else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = nil
            if externalDisplayConnected == nil, !hasLoggedMissingDisplayState {
                log("\(reason) external_display_state_unavailable")
                hasLoggedMissingDisplayState = true
            }
            return
        }

        guard !didRequestDisplaySleepForClosedLid else { return }
        let now = ContinuousClock.now
        if let retryAt = nextDisplaySleepRetryAt, now < retryAt { return }

        let result = runHelper(displaySleepHelperMode)
        log("\(reason) clamshell=closed display_sleep_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
        if result.status == 0 {
            didRequestDisplaySleepForClosedLid = true
            nextDisplaySleepRetryAt = nil
        } else {
            nextDisplaySleepRetryAt = now.advanced(by: .seconds(helperRetryInterval))
        }
    }

    private func updateStatus(capsLockOn: Bool) {
        guard let button = statusItem?.button else { return }
        let strings = AppStrings.current()
        if case .heldByFloor(let percent) = keepAwakeStatus {
            button.image = heldImage
            button.toolTip = TextTemplate.fill(strings.tooltipHeldFormat, [
                "battery": percent,
                "floor": Preferences.batteryFloorPercent,
                "recover": batteryFloorRecoverPercent
            ])
            return
        }
        button.image = capsLockOn ? onImage : offImage
        button.toolTip = tooltipText(capsLockOn: capsLockOn, strings: strings)
    }

    /// Caps Lock wording only in the mode where Caps Lock is what decides. In Auto the
    /// tooltip used to read "Caps Lock OFF: normal sleep" while Auto was the selected
    /// mode — the app narrating a control the user was not using.
    private func tooltipText(capsLockOn: Bool, strings: AppStrings) -> String {
        if case .awakePowerUnknown = keepAwakeStatus {
            return strings.tooltipPowerUnknown
        }
        if case .overriding(let percent) = keepAwakeStatus {
            return TextTemplate.fill(strings.batteryFloorOverrideDetailFormat, [
                "battery": percent,
                "critical": BatteryFloorPolicy.criticalPercent
            ])
        }
        switch Preferences.keepAwakeMode {
        case .capsLock:
            return capsLockOn ? strings.tooltipOn : strings.tooltipOff
        case .off, .auto:
            return capsLockOn ? strings.tooltipKeepAwakeOn : strings.tooltipKeepAwakeOff
        }
    }

    private func refreshStatus(capsLockOn: Bool) {
        if failedSleepState == nil {
            updateStatus(capsLockOn: capsLockOn)
        } else {
            updateStatusError()
        }
    }

    private func updateStatusError() {
        if statusItem == nil {
            installStatusItem()
        }
        guard let button = statusItem?.button else { return }
        button.image = errorImage
        button.toolTip = AppStrings.current().tooltipError
    }

    private func runHelper(
        _ mode: String,
        timeout: TimeInterval = CommandRunner.defaultTimeout
    ) -> (status: Int32, stdout: String, stderr: String) {
        CommandRunner.run("/usr/bin/sudo", ["-n", helperPath, mode], timeout: timeout)
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        // A dedicated queue, not `.main`. This handler exists to put system sleep back
        // while the app is being killed — including when the main actor is stuck, which
        // is exactly when it matters. Running it there meant a blocked main actor made
        // the app unkillable by anything but SIGKILL, and SIGKILL skips the restore
        // entirely, leaving sleep disabled system-wide.
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: Self.signalQueue)
            source.setEventHandler {
                // The loser of the race logs that it skipped and returns WITHOUT
                // calling exit() itself: an unconditional exit(0) from the losing side
                // would be a process-wide, immediate termination that could cut off the
                // winning side's in-flight restore — worse than the race this gate
                // exists to remove. The process still terminates: either the winner
                // calls exit() below, or (if applicationWillTerminate is the winner)
                // AppKit's own termination sequence completes it, as it already did
                // before this gate existed.
                guard Self.exitRestoreGate.claim() else {
                    Self.appendLog("signal=\(signalNumber) restore_off skipped=already_claimed")
                    return
                }

                let result = Self.restoreSleepOffHelper()
                Self.appendLog(
                    "signal=\(signalNumber) restore_off helper_status=\(result.status) "
                        + "stdout=\(result.stdout) stderr=\(result.stderr)"
                )
                if result.status == 0 {
                    SleepStateBreadcrumbStore.clear()
                }
                exit(ExitRestoreOutcome.exitCode(helperStatus: result.status))
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private nonisolated static let signalQueue = DispatchQueue(label: "\(appLabel).signal")
    /// Shared with `applicationWillTerminate` so only one of the two exit paths ever
    /// performs the restore for a single termination event.
    private nonisolated static let exitRestoreGate = ExitRestoreGate()
    /// Down from `CommandRunner.defaultTimeout` (5s), only for these exit-path call
    /// sites — every other caller keeps the 5s default. D2: one attempt, no retry — the
    /// observed failure (`sudo: you do not exist in the passwd database`) is
    /// opendirectoryd being torn down for the rest of shutdown, not a flapping
    /// condition, so a later retry cannot out-wait it; a retry only buys launchd more
    /// time to SIGKILL the app, which loses the restore AND the log line AND the
    /// breadcrumb write.
    private nonisolated static let exitHelperTimeout: TimeInterval = 2.0

    /// Putting sleep back must not need the main actor, for the same reason the handler
    /// does not run there.
    private nonisolated static func restoreSleepOffHelper() -> (status: Int32, stdout: String, stderr: String) {
        CommandRunner.run("/usr/bin/sudo", ["-n", helperPath, "off"], timeout: exitHelperTimeout)
    }

    private func log(_ message: String) {
        Self.appendLog(message)
    }

    /// One rollover kept, no dated archive. A permanently failing helper retries every
    /// five seconds forever, which is on the order of a megabyte a day of identical
    /// lines into a file nothing was trimming.
    private nonisolated static let maxLogBytes: UInt64 = 1_000_000

    /// `nonisolated` so the signal handlers, which deliberately run off the main actor,
    /// can still record what they did.
    nonisolated static func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = line.data(using: .utf8) else { return }

        guard FileManager.default.fileExists(atPath: logPath),
              let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)

        // Renaming out from under the open handle is safe: this write already landed,
        // and the next call finds no file at logPath and starts a fresh one.
        guard let size = try? handle.offset(), size > maxLogBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
