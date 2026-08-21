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
    /// The bound on every privileged helper call, ordinary or exit-time. Every such call in
    /// a month of logs answered in milliseconds; the ceiling only matters when `sudo` is
    /// wedged, and at that point a longer wait buys nothing but a smaller chance of the
    /// exit-time restore happening at all. `HelperCoordinator` sizes its lock wait against
    /// this, so the two cannot drift apart into a race.
    static let helperTimeout: TimeInterval = 2.0
    /// The most a timed-out child can cost on top of its timeout: one polite terminate
    /// window plus one kill window.
    static let maximumKillCost: TimeInterval = terminationGrace * 2
    /// How long a timed-out child gets to die politely before it is killed outright.
    static let terminationGrace: TimeInterval = 1
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

/// Reads `pmset -g assertions` to find OTHER processes preventing SYSTEM sleep — never
/// Capsomnia itself: it works by flipping `disablesleep`, not by holding an
/// `IOPMAssertion`, so every name this returns belongs to something else. Spec Sprint 3
/// / FINDINGS Defect 4: when Capsomnia is confirmed OFF and the Mac still won't idle-
/// sleep, this is what lets the popover say why instead of looking like it is lying.
///
/// On-demand only. `foreignBlockers()` has exactly one caller in the app,
/// `togglePopover()`'s opening branch — never the 0.25s poll, never
/// `applyCurrentCapsLockState`, never a verification tick. A real subprocess read must
/// only run where the code already proves it is rare, the same reasoning that keeps
/// `ClamshellStateReader.isClosed()` behind `ClosedLidCapsLockGuard`'s `@autoclosure`.
enum SleepAssertionReader {
    /// Only these two actually stop SYSTEM sleep. `PreventUserIdleDisplaySleep`,
    /// `InternalPreventDisplaySleep`, `UserIsActive`, `NetworkClientActive`,
    /// `BackgroundTask`, `ApplePushServiceTask`, `SoftwareUpdateTask`, `ExternalMedia`
    /// describe something else and must not be reported as "blocking sleep" (D8 rule 1).
    private static let systemSleepAssertionTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep"
    ]

    /// D8 rule 2: excluded entirely, not filtered by assertion type. `powerd` holds
    /// `PreventUserIdleSystemSleep` whenever the display is on — essentially always while
    /// a human is at the machine — so it describes the machine's own state, not another
    /// app's request, and it is the one owner guaranteed present in exactly the
    /// situation this subtitle exists to explain. Counting it would make the new
    /// subtitle read "1 app blocking sleep" permanently: a warning about nothing, the
    /// same class of defect this whole harness run exists to fix, pointed the other way.
    private static let excludedProcessNames: Set<String> = ["powerd"]

    /// `nil` means the read itself failed — distinct from an empty array, which means
    /// the read succeeded and found nothing. Callers must never render either as "0 apps
    /// blocking sleep" (D8 rule 4): fail-closed, absence of evidence is not shown as
    /// evidence of absence.
    static func foreignBlockers() -> [String]? {
        let result = CommandRunner.run("/usr/bin/pmset", ["-g", "assertions"])
        guard result.status == 0 else { return nil }
        return parse(result.stdout)   // nil also when rows exist but none are readable
    }

    /// Pure function over `pmset -g assertions` text, so it is testable directly against
    /// a captured real sample (D8 rule 5) instead of only through a live subprocess call.
    /// Returns de-duplicated PROCESS NAMES, not one entry per assertion (D8 rule 3): three
    /// `caffeinate` processes are one answer to "what is keeping this awake", not three.
    static func parse(_ output: String) -> [String]? {
        var seen = Set<String>()
        var names: [String] = []
        var ownerRows = 0
        var parsedRows = 0

        for line in output.split(whereSeparator: { $0.isNewline }) {
            guard line.contains("pid ") else { continue }
            ownerRows += 1
            guard let processName = processName(in: line),
                  let type = assertionType(in: line) else { continue }
            parsedRows += 1

            guard !excludedProcessNames.contains(processName) else { continue }
            guard systemSleepAssertionTypes.contains(type) else { continue }
            guard let safeName = displaySafeName(processName) else { continue }
            guard seen.insert(safeName).inserted else { continue }
            names.append(safeName)
        }

        // Rows existed and NONE of them parsed: the format is not what this code expects
        // (a localized build, a truncated read, a future macOS). Returning an empty array
        // there would tell the user "nothing is holding your Mac awake", which is a claim
        // about the system made from a failure to read it — the same shape as the defect
        // this whole change exists to remove. `nil` means "cannot say".
        if ownerRows > 0 && parsedRows == 0 { return nil }
        return names
    }

    /// These names are rendered into the app's own UI. A process can be named with control
    /// or bidirectional-override characters, which lets an attacker-chosen name reorder or
    /// mask the text around it — a spoofing surface, not a code-execution one. Anything
    /// carrying them is dropped rather than sanitised: a blocker that cannot be named
    /// honestly is better left unnamed than shown as something it is not.
    private static func displaySafeName(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        for scalar in name.unicodeScalars {
            if scalar.properties.isBidiControl { return nil }
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            if (0x200B...0x200F).contains(scalar.value) { return nil }
            if (0x2028...0x202E).contains(scalar.value) { return nil }
            if (0x2066...0x2069).contains(scalar.value) { return nil }
        }
        return name
    }

    /// The owner field is `pid <n>(<name>)` and is terminated by `"): "`. Anchoring on
    /// that pair rather than the FIRST `)` keeps a process name that itself contains
    /// parentheses intact instead of truncating it at the first one.
    private static func processName(in line: Substring) -> String? {
        guard let pidRange = line.range(of: "pid ") else { return nil }
        let afterPid = line[pidRange.upperBound...]
        guard let openParen = afterPid.firstIndex(of: "("),
              let closeRange = afterPid.range(of: "): ") else { return nil }
        let start = afterPid.index(after: openParen)
        guard start < closeRange.lowerBound else { return nil }
        return String(afterPid[start..<closeRange.lowerBound])
    }

    /// The assertion type is the whitespace-delimited token immediately before
    /// ` named:`. Scanning the WHOLE line for the type instead — which is what this did
    /// first — matches the type appearing anywhere, including inside the quoted
    /// human-readable assertion name that follows, so a display-only assertion whose
    /// name happened to mention system sleep would be reported as a system-sleep
    /// blocker. Comparing the captured token makes that impossible rather than unlikely.
    private static func assertionType(in line: Substring) -> String? {
        guard let namedRange = line.range(of: " named:") else { return nil }
        return line[line.startIndex..<namedRange.lowerBound]
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map(String.init)
    }
}

/// What the last assertion read actually established. Three cases, not an array, because
/// "the read failed" and "there is nothing holding the Mac awake" are different facts and
/// collapsing them is how a fail-closed design turns fail-open: the header would render
/// its ordinary subtitle either way, so a `pmset` failure would be indistinguishable from
/// a clean answer — on a machine where that command is measured to fail intermittently.
enum ForeignBlockerReading: Equatable {
    /// The read succeeded and found these (already filtered and de-duplicated).
    case known([String])
    /// The read succeeded and found nothing.
    case none
    /// The read itself failed. Claim nothing.
    case unavailable

    var names: [String] {
        if case .known(let names) = self { return names }
        return []
    }
}

/// Turns the blocker list into the short phrase the header can actually fit. A COUNT was
/// the first version and it answered the wrong question: the user opening this menu is
/// asking "what is keeping my Mac awake", and "3 apps" does not answer it — on this
/// machine the answer is `caffeinate`, which points straight at the terminal sessions
/// responsible. The remainder stays a count because the header is one line.
enum ForeignBlockerSummary {
    /// Long enough for every real process name observed on this machine (`caffeinate`
    /// and `coreaudiod` are 10, `WindowServer` is 12) plus headroom, short enough that a
    /// long one cannot run away with the line. This is a CHARACTER cap, so it cannot by
    /// itself guarantee a pixel width — a name of all-wide glyphs still overruns. The
    /// view's `.lineLimit(1)` truncation is the backstop for that; `MenuHeaderFitTests`
    /// pins the realistic worst case, which is what actually has to look right.
    static let maxNameLength = 14

    /// `nil` when there is nothing to say — no blockers, or a read that failed. The
    /// caller must render nothing at all in that case, never a zero (D8 rule 4).
    static func render(names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let name = first.count > maxNameLength
            ? String(first.prefix(maxNameLength - 1)) + "\u{2026}"
            : first
        let others = names.count - 1
        return others > 0 ? "\(name) +\(others)" : name
    }
}

/// Which of the header's four subtitle reasons is showing, in priority order. Pure over
/// values the caller already computes — the popover can never invent a reason the
/// underlying booleans/counts don't support. Mirrors `StatusPillPresentation`: one enum
/// drives the decision so a future edit to one branch can't silently disagree with
/// another.
enum HeaderSubtitleKind: Equatable {
    case heldByFloor, overridingFloor, foreignBlockers(count: Int), modeLabel

    /// Floor states keep the precedence Sprint 2 already established (checked first,
    /// unconditionally win). Foreign blockers (Sprint 3, FINDINGS Defect 4) only ever
    /// explain a CONFIRMED off — showing them while Capsomnia is ON would blame
    /// something else for what Capsomnia itself is doing, and showing them while the
    /// state is `.unknown` would dress up an unconfirmed state with a confident
    /// explanation, which is exactly what Sprint 2 exists to prevent. A zero count never
    /// surfaces the reason (D8 rule 4): that is `.modeLabel`, the ordinary fallback.
    static func choose(
        observed: SleepStateObservation,
        heldByFloor: Bool,
        overridingFloor: Bool,
        foreignBlockerCount: Int
    ) -> HeaderSubtitleKind {
        // `.unknown` first, exactly as `StatusPillPresentation.choose` does it. Without
        // this the popover rendered a red UNKNOWN pill and, immediately beside it, the
        // battery floor's confident "held — battery at N%, resumes at M%" — a specific
        // claim about system behaviour made at the moment the app has no evidence for
        // any of it. That is Defect 1's exact symptom, reintroduced in the one header
        // surface Sprint 2 did not touch.
        if observed == .unknown { return .modeLabel }
        if heldByFloor { return .heldByFloor }
        if overridingFloor { return .overridingFloor }
        if observed == .off, foreignBlockerCount > 0 { return .foreignBlockers(count: foreignBlockerCount) }
        return .modeLabel
    }
}

/// Serialises every privileged `on`/`off` call in the process, so the exit-time `off` is
/// always the LAST mutation.
///
/// Without this, the app could exit reporting success while leaving the machine awake:
/// the main actor issues `helper on`, SIGTERM lands mid-call, the signal handler runs
/// `helper off`, sees status 0, deletes the breadcrumb and exits 0 — and the earlier
/// `on` lands after it. Clean exit, `restore_off helper_status=0` in the log, no
/// breadcrumb, `disablesleep=1` on the machine. That is the exact failure this whole
/// change exists to remove, reproduced through its own fix.
///
/// Two mechanisms, because a lock alone is not enough:
/// - `beginTermination()` latches a flag that makes every subsequent `on` refuse. An
///   `on` that has not started yet can simply never start.
/// - `withPriority` bounds how long the exit path will wait for an `on` that HAS already
///   started. Every helper call in a month of logs returned in milliseconds; the 5s
///   ceiling only matters when `sudo` is hung, and a hung `sudo` means the exit is lost
///   anyway. Waiting forever would be worse than the race: it would put the signal
///   handler back behind main-actor work, which is what made the app unkillable before.
final class HelperCoordinator: @unchecked Sendable {
    /// The one the app uses. Tests build their own, because `beginTermination` latches
    /// permanently by design and a shared latch flipped by one test would leak into
    /// every test after it.
    static let shared = HelperCoordinator()

    private let lock = NSLock()
    private let terminating = OSAllocatedUnfairLock(initialState: false)
    private let priorityWait: TimeInterval

    init(priorityWait: TimeInterval = 2.0) {
        self.priorityWait = priorityWait
    }

    /// Latches "we are on the way out", refusing every subsequent `on`.
    ///
    /// Only call this once termination is COMMITTED. It was originally called before every
    /// explicit-Quit restore attempt, including the ones the user then cancelled — so a
    /// single failed Quit followed by "Copy command" left a live app that could never turn
    /// keep-awake on again, for the rest of its life, with no way for the user to tell.
    /// A quit being *considered* is not a quit.
    func beginTermination() {
        terminating.withLock { $0 = true }
    }

    var isTerminating: Bool {
        terminating.withLock { $0 }
    }

    /// Runs `body` holding the helper lock. Used by the ordinary poll-driven path.
    func serialized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Runs `body` holding the helper lock if it can be had within `priorityWait`, and
    /// runs it anyway if it cannot — reporting which happened, so a contended exit is
    /// visible in the log instead of being indistinguishable from a clean one.
    func withPriority<T>(_ body: () -> T) -> (value: T, contended: Bool) {
        let acquired = lock.lock(before: Date().addingTimeInterval(priorityWait))
        defer { if acquired { lock.unlock() } }
        return (body(), !acquired)
    }
}

/// Coordinates the two exit paths — `applicationWillTerminate` and the SIGINT/SIGTERM
/// handler — that both fire for one termination (proven 2026-07-31: both ran in the same
/// second and both raced independent `sudo` calls).
///
/// Three states, not a one-shot Bool. A Bool made the loser return into silence, and a
/// winner that then hung or stalled meant every later SIGTERM was swallowed too: the app
/// became killable only by SIGKILL, which skips the restore entirely — strictly worse
/// than the race the gate was added to remove. The loser now waits, bounded, for the
/// winner's result and exits with it.
///
/// Lock-backed rather than actor-backed on purpose: the signal handler deliberately runs
/// off the main actor, and an actor hop would put it back behind a main actor that may
/// be exactly what is stuck.
final class ExitRestoreGate: @unchecked Sendable {
    private let state = NSCondition()
    private var claimedFlag = false
    private var completion: Int32?

    /// `true` for the first caller only.
    @discardableResult
    func claim() -> Bool {
        state.lock()
        defer { state.unlock() }
        if claimedFlag { return false }
        claimedFlag = true
        return true
    }

    /// Publishes the winner's helper status and wakes every waiter.
    /// Publishes the winner's helper status. The FIRST publication wins: a second one —
    /// from a path that lost the claim, or a late duplicate — must not be able to replace
    /// a success with a failure and turn a clean exit into an `exit(1)` that KeepAlive
    /// would act on.
    func complete(status: Int32) {
        state.lock()
        defer { state.unlock() }
        guard completion == nil else { return }
        completion = status
        state.broadcast()
    }

    /// Blocks until the winner publishes a status or `timeout` elapses. `nil` means the
    /// winner never finished — the caller must then act on its own rather than hang.
    func awaitCompletion(timeout: TimeInterval) -> Int32? {
        state.lock()
        defer { state.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while completion == nil {
            if !state.wait(until: deadline) { return nil }
        }
        return completion
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
        guard (try? FileManager.default.removeItem(at: file)) != nil else {
            // Already gone counts as cleared; anything else is a real failure the
            // caller has to be able to see.
            return !FileManager.default.fileExists(atPath: file.path)
        }
        // The unlink is not durable until the DIRECTORY entry is. Without this, a power
        // loss right after a successful restore can resurrect the breadcrumb and make
        // the next launch report an unclean exit that never happened. Returning true
        // when that sync failed would report a clear this code cannot actually promise.
        return syncDirectory(directory)
    }

    /// `fsync` on a file persists its CONTENTS; it says nothing about the directory
    /// entry that names it. A `rename()` or `unlink()` that has not been followed by an
    /// `fsync` of the containing directory can be lost in a power failure — which is
    /// precisely the event this file exists to survive.
    @discardableResult
    private static func syncDirectory(_ directory: URL) -> Bool {
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    /// Gives an ownership claim back after a helper call that DEFINITELY changed nothing
    /// (a real non-zero exit status, not a timeout — a timed-out call may well have
    /// applied). Without this, a claim written before a failed `on` stands forever: the
    /// next attempt sees `owned == true`, skips re-reading the prior state, and keeps
    /// claiming a setting Capsomnia never actually set.
    @discardableResult
    static func releaseClaim(directory: URL = directoryURL, file: URL = fileURL) -> Bool {
        clear(directory: directory, file: file)
    }

    private static func write(_ breadcrumb: SleepStateBreadcrumb, directory: URL, file: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(breadcrumb) else { return false }
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )) != nil else {
            return false
        }

        // A crash between create and rename leaves the temp behind; over a long-lived
        // install those accumulate silently. Cheap to sweep here, where the directory is
        // already being written to.
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for url in stale where url.lastPathComponent.hasPrefix(".sleep-state.")
                && url.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: url)
            }
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
        syncDirectory(directory)
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
