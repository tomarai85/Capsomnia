import AppKit
import CoreGraphics
import Foundation

@MainActor
final class Capsomnia: NSObject, NSApplicationDelegate {
    private var lastAppliedState: Bool?
    private var failedSleepState: Bool?
    private var nextSleepStateRetryAt = Date.distantPast
    private var nextSleepStateVerificationAt = Date.distantPast
    private var nextDisplaySleepRetryAt = Date.distantPast
    private var didRequestDisplaySleepForClosedLid = false
    private var hasLoggedMissingClamshellState = false
    private var hasLoggedMissingDisplayState = false
    private var hasLoggedMissingSleepState = false
    private var shouldRestoreSleepOnTerminate = true
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
    private var cachedBatteryReadAt = Date.distantPast
    private let batteryCacheInterval: TimeInterval = 5
    private let batteryFloorRecoverMargin = 5
    /// Explicit consent to keep running below the floor. Deliberately NOT persisted:
    /// after a relaunch — including one that followed a crash — the app must come back
    /// on the safe side rather than silently still overriding a safety limit.
    private var batteryFloorOverride = false
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
        applyCurrentCapsLockState(reason: "startup")

        if shouldShowInitialSetup {
            showSettingsWindow(page: .initialPreferences)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow(page: currentSettingsPage())
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard shouldRestoreSleepOnTerminate else { return }

        let result = runHelper("off")
        log("terminate restore_off helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
    }

    private func terminateIfNewerInteractiveDuplicate() -> Bool {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != appLabel else {
            return false
        }

        let currentPID = getpid()
        let olderInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: appLabel)
            .filter { !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier < currentPID }

        guard let existing = olderInstances.min(by: { $0.processIdentifier < $1.processIdentifier }) else {
            return false
        }

        shouldRestoreSleepOnTerminate = false
        DistributedNotificationCenter.default().post(
            name: openSettingsNotificationName,
            object: appLabel,
            userInfo: nil
        )
        existing.activate(options: [])
        log("duplicate_instance existing_pid=\(existing.processIdentifier) terminate_without_restore")
        NSApp.terminate(nil)
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
        let now = Date()
        if let cachedBattery, now.timeIntervalSince(cachedBatteryReadAt) < batteryCacheInterval {
            return cachedBattery
        }
        if let fresh = BatteryReader.read() {
            cachedBattery = fresh
            cachedBatteryReadAt = now
            return fresh
        }
        guard now.timeIntervalSince(cachedBatteryReadAt) < batteryStaleInterval else {
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
            intent = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
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
            "keep_awake_status \(describe(previous) ?? "none")->\(describe(keepAwakeStatus)!) "
                + "mode=\(Preferences.keepAwakeMode.rawValue) capslock_flag=\(capsLockFlag ? "on" : "off") "
                + "battery=\(battery?.percent.map(String.init) ?? "unknown") "
                + "power=\(battery.map { $0.onAC ? "ac" : "batt" } ?? "unknown") "
                + "floor=\(Preferences.batteryFloorEnabled ? "\(Preferences.batteryFloorPercent)" : "off") "
                + "recover=\(batteryFloorRecoverPercent) latched=\(batteryFloorLatched ? "yes" : "no")"
        )
    }

    private func describe(_ status: KeepAwakeStatus?) -> String? {
        switch status {
        case nil: return nil
        case .awake: return "awake"
        case .normal: return "normal"
        case .heldByFloor: return "held_by_floor"
        case .overriding: return "overriding"
        case .awakePowerUnknown: return "awake_power_unknown"
        }
    }

    private func apply(capsLockOn: Bool, reason: String) {
        let now = Date()
        if failedSleepState == capsLockOn, now < nextSleepStateRetryAt {
            return
        }

        if lastAppliedState == capsLockOn {
            if failedSleepState == nil, now < nextSleepStateVerificationAt {
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
        let result = runHelper(mode)
        log("\(reason) capslock=\(mode) helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")

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

    private func markSleepStateFailed(_ capsLockOn: Bool, at now: Date, resetVerification: Bool = true) {
        failedSleepState = capsLockOn
        nextSleepStateRetryAt = now.addingTimeInterval(helperRetryInterval)
        if resetVerification {
            nextSleepStateVerificationAt = nextSleepStateRetryAt
        }
        updateStatusError()
    }

    private func markSleepStateConfirmed(_ capsLockOn: Bool, at now: Date, reason: String) {
        hasLoggedMissingSleepState = false
        failedSleepState = nil
        nextSleepStateRetryAt = .distantPast
        nextSleepStateVerificationAt = now.addingTimeInterval(sleepStateVerificationInterval)
        // Keep the popover's status pill / LED live even while it is open (e.g. the
        // battery floor releasing keep-awake flips it to OFF without a reopen).
        menuModel?.keepingAwake = capsLockOn
        syncStatusItemVisibility()
        evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: reason)
    }

    private func evaluateDisplaySleepForClosedLid(capsLockOn: Bool, reason: String) {
        guard Preferences.displaySleepOnLidClose else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
            return
        }

        guard capsLockOn else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
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
            nextDisplaySleepRetryAt = .distantPast
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
            nextDisplaySleepRetryAt = .distantPast
            if externalDisplayConnected == nil, !hasLoggedMissingDisplayState {
                log("\(reason) external_display_state_unavailable")
                hasLoggedMissingDisplayState = true
            }
            return
        }

        guard !didRequestDisplaySleepForClosedLid else { return }
        let now = Date()
        guard now >= nextDisplaySleepRetryAt else { return }

        let result = runHelper(displaySleepHelperMode)
        log("\(reason) clamshell=closed display_sleep_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
        if result.status == 0 {
            didRequestDisplaySleepForClosedLid = true
            nextDisplaySleepRetryAt = .distantPast
        } else {
            nextDisplaySleepRetryAt = now.addingTimeInterval(helperRetryInterval)
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

    private func runHelper(_ mode: String) -> (status: Int32, stdout: String, stderr: String) {
        CommandRunner.run("/usr/bin/sudo", ["-n", helperPath, mode])
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                let result = self?.runHelper("off")
                self?.log(
                    "signal=\(signalNumber) restore_off helper_status=\(result?.status ?? -1) "
                        + "stdout=\(result?.stdout ?? "") stderr=\(result?.stderr ?? "")"
                )
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logPath),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
