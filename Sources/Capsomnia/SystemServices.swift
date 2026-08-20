import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import os

struct LaunchAgentError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum CommandRunner {
    /// Every command this app runs (`sudo`, `pmset`, `launchctl`) answers in
    /// milliseconds. The bound exists because the calls are synchronous and made from
    /// the main actor: without it, one hung child freezes the whole app — and since the
    /// SIGINT/SIGTERM handlers used to run on that same actor, the app then could not be
    /// killed by anything short of SIGKILL, which skips the restore that puts system
    /// sleep back. A late answer is worthless here anyway; the poll will try again.
    static let defaultTimeout: TimeInterval = 5
    /// How long a timed-out child gets to die politely before it is killed outright.
    private static let terminationGrace: TimeInterval = 1
    /// Distinct from any exit code a real command produces, so callers can tell
    /// "it failed" from "it never answered" in the log.
    static let timedOutStatus: Int32 = -2

    static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set before run(): a short-lived child can exit before the handler is attached.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Drain both pipes concurrently with the wait. Reading them after the process
        // has been waited on deadlocks the moment a child fills a 64KB pipe buffer —
        // survivable so far only because pmset says so little.
        var stdoutData = Data()
        var stderrData = Data()
        let readers = DispatchGroup()
        let ioQueue = DispatchQueue(label: "\(appLabel).command-io", attributes: .concurrent)

        do {
            try process.run()
        } catch {
            return (-1, "", "\(error)")
        }

        ioQueue.async(group: readers) {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        ioQueue.async(group: readers) {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
        }

        // The readers finish once the child's write ends close, which killing it forces.
        _ = readers.wait(timeout: .now() + terminationGrace)

        guard !timedOut else {
            return (timedOutStatus, "", "timed out after \(timeout)s")
        }
        return (process.terminationStatus, text(stdoutData), text(stderrData))
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum LaunchAgentManager {
    static func setEnabled(_ enabled: Bool) throws {
        let arguments = [
            enabled ? "enable" : "disable",
            "gui/\(getuid())/\(appLabel)"
        ]
        let result = CommandRunner.run("/bin/launchctl", arguments)
        guard result.status == 0 else {
            throw LaunchAgentError(
                message: "launchctl \(arguments.joined(separator: " ")) failed: \(result.stderr.isEmpty ? result.stdout : result.stderr)"
            )
        }
    }
}

enum SleepStateReader {
    static func isDisabled() -> Bool? {
        let result = CommandRunner.run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2,
                  fields[0].lowercased() == "sleepdisabled" else {
                continue
            }

            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }

        return nil
    }
}

/// The tri-state the app actually knows about system sleep — derived only from a
/// CONFIRMED read (`SleepStateReader.isDisabled()` agreeing with what was requested),
/// never from the optimistically-set applied state. Spec Sprint 2 / FINDINGS Defect 1 +
/// Defect 3: before this, a failing helper or verification read collapsed straight into
/// a confident `OFF`, contradicting the menu-bar's own red error dot at the exact moment
/// the app had no evidence about the real state.
enum SleepStateObservation: Equatable {
    case on, off, unknown

    /// `lastConfirmed` is the last CONFIRMED value (`nil` before the first confirming
    /// read has ever landed); `helperFailing` mirrors whether the helper call or its
    /// verification read is currently failing. A failing helper always wins to
    /// `.unknown` regardless of `lastConfirmed` — a past confirmation describes the
    /// past, not now.
    static func from(lastConfirmed: Bool?, helperFailing: Bool) -> SleepStateObservation {
        guard !helperFailing else { return .unknown }
        switch lastConfirmed {
        case .some(true): return .on
        case .some(false): return .off
        case .none: return .unknown
        }
    }
}

/// One-shot claim shared between `applicationWillTerminate` and the SIGINT/SIGTERM
/// signal handler — proven necessary 2026-07-31: both fired for the same termination
/// and both raced independent `sudo` calls. Backed by `OSAllocatedUnfairLock`, not an
/// actor: the signal handler deliberately runs off the main actor (see
/// `installSignalHandlers`), so a stuck main actor must not be able to make the app
/// unkillable, which an actor hop into this type would reintroduce.
final class ExitRestoreGate: @unchecked Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    /// `true` for the first caller only. Every caller after — including a caller that
    /// arrives while the first is still mid-restore — gets `false` and must not attempt
    /// the restore itself.
    @discardableResult
    func claim() -> Bool {
        claimed.withLock { alreadyClaimed in
            if alreadyClaimed { return false }
            alreadyClaimed = true
            return true
        }
    }
}

/// Which exit path still owes a restore, extracted from the app delegate so the
/// hand-off between `applicationShouldTerminate` (the explicit-Quit flow, the only place
/// termination can still be cancelled) and `applicationWillTerminate` is testable
/// without AppKit.
///
/// The bug this exists to make impossible: the explicit-Quit flow marked itself handled
/// so that `applicationWillTerminate` would not repeat the restore, but a termination
/// the user then CANCELLED (the alert's "Copy command" branch) left that mark standing
/// for the rest of the process's life — so the next termination, arriving through
/// `applicationWillTerminate`, skipped the restore entirely and left `disablesleep=1`
/// with nobody to clear it. A cancelled termination must put the debt back.
struct QuitRestoreLedger: Equatable {
    private(set) var handledForPendingTermination = false

    /// The explicit-Quit flow ran the restore for the termination now in progress.
    mutating func markHandled() {
        handledForPendingTermination = true
    }

    /// The user cancelled that termination. The app keeps running, so the next
    /// termination — whichever path it arrives on — owes a fresh restore.
    mutating func terminationCancelled() {
        handledForPendingTermination = false
    }

    /// Whether `applicationWillTerminate` should perform the restore itself.
    var shouldRestoreOnWillTerminate: Bool {
        !handledForPendingTermination
    }
}

/// Extracted so the exit-code decision (D5) is testable without invoking the real
/// SIGINT/SIGTERM handler, which really does call `exit()` and would kill the test
/// process.
enum ExitRestoreOutcome {
    /// 0 for a confirmed or unneeded restore (the helper call itself reports success,
    /// whether because it actively turned `disablesleep` back off or because it was
    /// already off), 1 for a failed one. The Quit path never uses this — it never exits
    /// non-zero, because a user Quit does not want the app resurrected behind them.
    static func exitCode(helperStatus: Int32) -> Int32 {
        helperStatus == 0 ? 0 : 1
    }
}

/// The exit-time reliability breadcrumb (spec Design Decision D3/D4). Stored as a JSON
/// file, not `UserDefaults` — this machine has an observed `UserDefaults` regression
/// across a hard death (`KeepAwakeMode` silently reverted to a stale on-disk value
/// after an unflushed cfprefsd write was lost), and a safety breadcrumb whose whole job
/// is to survive exactly that kind of event must not ride the mechanism that lost data
/// in exactly that kind of event.
struct SleepStateBreadcrumb: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let generation: Int
    let owned: Bool
    /// What `SleepStateReader.isDisabled()` read immediately before Capsomnia's first
    /// helper call to turn `disablesleep` on this cycle — `nil` when that read itself
    /// failed. This is what lets a later reconciliation tell "Capsomnia's own on-state"
    /// apart from "someone else already had this on."
    let priorSleepDisabled: Bool?
    let setAt: String
    let pid: Int32
}

/// Reads and writes `SleepStateBreadcrumb` to
/// `~/Library/Application Support/Capsomnia/sleep-state.json`. All writes go through a
/// temp file in the SAME directory, `fsync`, then `rename()` over the target — a plain
/// `Data.write(to:options:.atomic)` does not fsync, so the rename can still be atomic
/// while the bytes behind it never reached disk before a hard death.
enum SleepStateBreadcrumbStore {
    static let directoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Capsomnia")
    static let fileURL = directoryURL.appendingPathComponent("sleep-state.json")

    /// `nil` for "no file" and "unparsable" alike — both mean the same thing to every
    /// caller: there is no live claim of ownership to reconcile against.
    static func read(file: URL = fileURL) -> SleepStateBreadcrumb? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SleepStateBreadcrumb.self, from: data)
    }

    /// Marks that Capsomnia is ABOUT TO turn `disablesleep` on, before the helper call
    /// that does it — the dirty bit must be raised before the risky operation, not
    /// after, or a crash between the two leaves the system dirty and the bit clean.
    ///
    /// Claims OWNERSHIP only when `priorSleepDisabled` is a confirmed `false` (the read
    /// that ran immediately before this call actually saw `disablesleep=0`). If it was
    /// already `true` — `disablesleep` was on before Capsomnia acted at all — this
    /// transition is not the one that turned sleep off; claiming ownership anyway would
    /// let a later reconciliation clear a setting Capsomnia never set, which is the exact
    /// class of bug D4 exists to prevent. An unreadable prior state (`nil`) fails
    /// ownership the same way: not knowing the prior state is not knowing it was
    /// Capsomnia's to begin with.
    ///
    /// It still WRITES the breadcrumb in all three cases, with `owned` recording which
    /// one happened. Refusing to write at all was the first implementation and it was
    /// wrong: the file has two jobs, and only one of them is ownership. The other is to
    /// be the record that a process was mid-`disablesleep=on` when it died — and the
    /// case where that record is most needed is precisely the case where
    /// `SleepStateReader.isDisabled()` is returning `nil`, i.e. this machine's observed
    /// `poll sleep_state_unavailable` episodes. A store that goes silent exactly when the
    /// system is flaky is a store that reports "clean exit" for every unclean one.
    ///
    /// Returns whether OWNERSHIP was claimed, not whether the write succeeded.
    @discardableResult
    static func markAttemptingOn(
        priorSleepDisabled: Bool?,
        pid: Int32 = getpid(),
        now: Date = Date(),
        directory: URL = directoryURL,
        file: URL = fileURL
    ) -> Bool {
        let owned = priorSleepDisabled == false

        let breadcrumb = SleepStateBreadcrumb(
            version: SleepStateBreadcrumb.currentVersion,
            generation: (read(file: file)?.generation ?? 0) + 1,
            owned: owned,
            priorSleepDisabled: priorSleepDisabled,
            setAt: ISO8601DateFormatter().string(from: now),
            pid: pid
        )
        let wrote = write(breadcrumb, directory: directory, file: file)
        return owned && wrote
    }

    /// Clears ownership after a confirmed off (poll-time `markSleepStateConfirmed`) or a
    /// successful exit-time restore. Best-effort: a leftover file after this just means
    /// the next launch logs a reconciliation finding that turns out to be harmless.
    @discardableResult
    static func clear(directory: URL = directoryURL, file: URL = fileURL) -> Bool {
        (try? FileManager.default.removeItem(at: file)) != nil
    }

    private static func write(_ breadcrumb: SleepStateBreadcrumb, directory: URL, file: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(breadcrumb) else { return false }
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )) != nil else {
            return false
        }

        // Same directory as the target: `rename()` is only atomic within one filesystem.
        let tempURL = directory.appendingPathComponent(".sleep-state.\(UUID().uuidString).tmp")
        let fd = Darwin.open(tempURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }

        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return buffer.count == 0 }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base + written, buffer.count - written)
                guard n > 0 else { return false }
                written += n
            }
            return true
        }

        guard wroteAll, fsync(fd) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        close(fd)

        guard rename(tempURL.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        return true
    }
}

enum ClamshellStateReader {
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        return (value as? NSNumber)?.boolValue
    }
}

enum ExternalDisplayReader {
    static func isConnected() -> Bool? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
            return nil
        }

        guard displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }

        return displays.prefix(Int(displayCount)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

enum DisplaySleepPolicy {
    static func shouldRequestDisplaySleep(externalDisplayConnected: Bool?) -> Bool {
        externalDisplayConnected == false
    }
}

/// While the lid is closed the built-in keyboard cannot be pressed, so a Caps Lock
/// turn-off observed in that window comes from an external source — the measured case is
/// a remote desktop client syncing its own keyboard state onto this Mac. Honoring it
/// releases sleep prevention in the middle of exactly the session it was protecting.
///
/// Ported from upstream v3.1.0 (fuji-mak/Capsomnia PR #76, `ExternalCapsLockOffPolicy`),
/// reshaped for this fork's poll-driven engine. Upstream RE-ASSERTS Caps Lock through its
/// 2.x toggle coordinator; this fork's base predates that machinery, so the guard HOLDS
/// THE INTENT instead: sleep prevention stays on while the lid is closed, and when the
/// lid opens the flag (still off) is followed again — which fails toward normal sleep
/// exactly when a human is back at the keyboard. Two upstream parameters are gone
/// because their subjects do not exist here: `autoOffInProgress` (no auto-off timer) and
/// `recentUserAction` (this fork's menu switches the MODE, never the caps flag, so a
/// user turn-off from the menu leaves `.capsLock` mode and the guard with it).
///
/// `clamshellClosed == nil` (state unavailable) fails open: the turn-off is honored.
///
/// `clamshellClosed` is an `@autoclosure` on purpose. The caller passes
/// `ClamshellStateReader.isClosed()`, an IOKit registry lookup, from the 250ms poll — and
/// a plain parameter is evaluated BEFORE the call, so that lookup ran four times a second
/// for as long as Caps Lock was off, no matter how the cheap conditions stood. Behind
/// `&&` (whose own right-hand side is already `@autoclosure`) it is reached only when
/// preference, mode, flag and last-applied state have all already agreed, which is the
/// rare poll the call site's comment describes.
enum ClosedLidCapsLockGuard {
    static func shouldHoldIntent(
        preferenceEnabled: Bool,
        mode: KeepAwakeMode,
        capsLockFlagOn: Bool,
        lastAppliedKeepAwake: Bool?,
        clamshellClosed: @autoclosure () -> Bool?
    ) -> Bool {
        preferenceEnabled
            && mode == .capsLock
            && !capsLockFlagOn
            && lastAppliedKeepAwake == true
            && clamshellClosed() == true
    }
}

/// A point-in-time read of the power source, via IOKit power sources (no subprocess).
enum BatteryReader {
    struct Snapshot {
        /// True when running on wall power (AC / adapter).
        let onAC: Bool
        /// Charge percentage 0-100, or nil when no internal battery reading is available.
        let percent: Int?
    }

    static func read() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        let providingType = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let onAC = providingType == kIOPSACPowerValue

        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }
            // Only the built-in battery. The list can also carry a UPS, and taking the
            // first source with a capacity would let the floor act on the UPS's charge
            // instead of the Mac's.
            guard description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else {
                continue
            }
            guard let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0 else {
                continue
            }
            percent = Int((Double(current) / Double(maximum) * 100).rounded())
            break
        }

        return Snapshot(onAC: onAC, percent: percent)
    }
}

/// Turns whatever the user typed into the battery-floor field into a usable percentage.
/// A floor of 0 would defeat the safety it exists for, and one near 100 would never let
/// the Mac stay awake on battery at all, so values outside the band are pulled back in
/// rather than rejected — typing 99 means "as high as it goes", not a silent no-op.
enum BatteryFloorInput {
    static let range = 5...90

    /// Returns nil when the text is not a number at all; the caller keeps the old value.
    static func parse(_ raw: String) -> Int? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let value = Int(trimmed) else {
            return nil
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Why the Mac is, or is not, being kept awake. A reasoned state rather than a Bool:
/// "not awake because you chose Off" and "not awake because the battery is low" collapse
/// to the same Bool, and that collapse is precisely what made the released state read as
/// the app misbehaving — the mode still showed as selected with no reason given.
enum KeepAwakeStatus: Equatable {
    /// The mode wants the Mac awake and nothing is holding it off.
    case awake
    /// The mode does not want the Mac awake. Normal macOS sleep.
    case normal
    /// The mode wants the Mac awake; the battery floor released it.
    case heldByFloor(percent: Int)
    /// The floor would release, and the user explicitly consented to stay awake anyway.
    case overriding(percent: Int)
    /// Awake, but the power source could not be read, so the floor cannot be enforced.
    case awakePowerUnknown

    var isHeldByFloor: Bool {
        if case .heldByFloor = self { return true }
        return false
    }

    var isOverriding: Bool {
        if case .overriding = self { return true }
        return false
    }

    /// The charge the state was decided on, when the state carries one.
    var percent: Int? {
        switch self {
        case .heldByFloor(let percent), .overriding(let percent):
            return percent
        case .awake, .normal, .awakePowerUnknown:
            return nil
        }
    }
}

/// Pure, deterministic keep-awake decision: user intent with a battery-floor safety
/// override and hysteresis latch. Extracted from the app delegate so it is unit-testable.
enum BatteryFloorPolicy {
    /// Below this charge the floor cannot be overridden. The override exists so the user
    /// can consent to running low on purpose (lid closed, reachable over SSH); it is not
    /// a way to drive the Mac to a hard shutdown. It is a mitigation, not a guarantee:
    /// releasing keep-awake only restores normal sleep, it does not force the Mac to
    /// sleep, so load and other assertions can still drain what is left.
    static let criticalPercent = 10

    struct Decision: Equatable {
        /// Whether to keep the Mac awake right now.
        let keepAwake: Bool
        /// The hysteresis latch to carry into the next decision.
        let latched: Bool
        /// Why, for the UI and the log.
        let status: KeepAwakeStatus

        var heldByFloor: Bool {
            if case .heldByFloor = status { return true }
            return false
        }

        var overriding: Bool {
            if case .overriding = status { return true }
            return false
        }
    }

    /// The charge at which a latched floor lets go again.
    static func recoverPercent(floorPercent: Int, recoverMargin: Int) -> Int {
        floorPercent + recoverMargin
    }

    /// Whether taking the override would actually change anything right now. The floor
    /// refuses it at or below the critical charge, so offering it there produces a
    /// control that silently does nothing — which is the exact failure this feature was
    /// built to remove. Note this is permanently false for any floor at or below the
    /// critical charge (the held region is `percent <= floorPercent` by construction),
    /// which is why a floor that low simply never shows the control.
    static func overrideCanApply(
        percent: Int?,
        criticalPercent: Int = BatteryFloorPolicy.criticalPercent
    ) -> Bool {
        guard let percent else { return false }
        return percent > criticalPercent
    }

    /// - Parameters:
    ///   - intent: whether the current mode wants the Mac awake.
    ///   - batteryReadable: false when the power source could not be read at all.
    ///   - percent: charge 0-100, or nil when unknown (but power source WAS readable).
    ///   - latched: whether keep-awake is currently released because of a prior low-battery hit.
    ///   - overrideActive: the user explicitly asked to stay awake below the floor.
    /// - Returns: the keep-awake decision, the next latch state, and why.
    static func decide(
        intent: Bool,
        floorEnabled: Bool,
        floorPercent: Int,
        recoverMargin: Int,
        onAC: Bool,
        percent: Int?,
        batteryReadable: Bool,
        latched: Bool,
        overrideActive: Bool = false,
        criticalPercent: Int = BatteryFloorPolicy.criticalPercent
    ) -> Decision {
        // 1. The latch first, from the battery alone. It describes the battery's
        //    trajectory, not what the user wants, so nothing about intent may touch it:
        //    letting `intent == false` clear it meant a Caps Lock tap (or a mode change,
        //    or a relaunch) silently reset the hysteresis and the same charge could then
        //    read as either released or awake.
        let nextLatched: Bool
        if !floorEnabled {
            nextLatched = false
        } else if !batteryReadable {
            nextLatched = latched
        } else if onAC {
            nextLatched = false
        } else if let percent {
            nextLatched = latched
                ? percent < recoverPercent(floorPercent: floorPercent, recoverMargin: recoverMargin)
                : percent <= floorPercent
        } else {
            nextLatched = latched
        }

        // 2. Then intent, which can only ever subtract.
        guard intent else {
            return Decision(keepAwake: false, latched: nextLatched, status: .normal)
        }
        guard floorEnabled else {
            return Decision(keepAwake: true, latched: false, status: .awake)
        }
        guard batteryReadable else {
            // Reachability is the priority: an unreadable power source must not put the
            // Mac to sleep. The latch survives so a readable-again low battery still holds.
            return Decision(keepAwake: true, latched: nextLatched, status: .awakePowerUnknown)
        }
        if onAC {
            return Decision(keepAwake: true, latched: false, status: .awake)
        }
        guard let percent else {
            return Decision(keepAwake: true, latched: nextLatched, status: .awakePowerUnknown)
        }
        guard nextLatched else {
            return Decision(keepAwake: true, latched: false, status: .awake)
        }
        if overrideActive, percent > criticalPercent {
            return Decision(keepAwake: true, latched: true, status: .overriding(percent: percent))
        }
        return Decision(keepAwake: false, latched: true, status: .heldByFloor(percent: percent))
    }
}
