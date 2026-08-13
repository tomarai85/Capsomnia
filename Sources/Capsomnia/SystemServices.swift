import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

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
enum ClosedLidCapsLockGuard {
    static func shouldHoldIntent(
        preferenceEnabled: Bool,
        mode: KeepAwakeMode,
        capsLockFlagOn: Bool,
        lastAppliedKeepAwake: Bool?,
        clamshellClosed: Bool?
    ) -> Bool {
        preferenceEnabled
            && mode == .capsLock
            && !capsLockFlagOn
            && lastAppliedKeepAwake == true
            && clamshellClosed == true
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
