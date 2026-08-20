import Foundation
import XCTest
@testable import Capsomnia

/// Sprint 1 (spec `.harness/spec.md`, "Design Decisions — RESOLVED" D2-D6): exit-time
/// restore reliability. `applicationWillTerminate` and the SIGINT/SIGTERM handler
/// proved capable of racing the same `sudo` call (2026-07-31), a failed restore left no
/// record surviving the process, and the breadcrumb meant to fix that had to survive the
/// exact kind of hard death that lost a `UserDefaults` write on this machine before.
final class ExitRestoreTests: XCTestCase {

    // MARK: - ExitRestoreGate

    /// Pins the entire point of the gate: under real concurrent access, exactly one
    /// caller ever gets `true`. Reverting `ExitRestoreGate` to something that does not
    /// serialize the check-and-set (e.g. a plain, unsynchronized `Bool`) makes this
    /// flaky-to-always-fail under `-parallel` / TSan, which is the same shape of bug
    /// that let two `sudo -n … off` calls race for real on 2026-07-31.
    func testExactlyOneClaimantWinsUnderConcurrentAccess() {
        let gate = ExitRestoreGate()
        let iterations = 500
        let winners = OSAllocatedUnfairLockBox(0)

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            if gate.claim() {
                winners.increment()
            }
        }

        XCTAssertEqual(winners.value, 1, "more than one caller believed it owned the restore")
    }

    /// The sequential case, which is what `applicationWillTerminate` and the signal
    /// handler actually do: claim, and only the first claim proceeds. Reverting the
    /// `guard … claim() else { return }` at either exit call site (removing the
    /// de-dup, not just breaking the gate itself) would let both paths run the helper
    /// for one termination — exactly what the 2026-07-31 log shows happened.
    func testSecondClaimAfterAFirstSuccessIsRefused() {
        let gate = ExitRestoreGate()
        XCTAssertTrue(gate.claim(), "the first caller must be allowed to proceed")
        XCTAssertFalse(gate.claim(), "a second caller for the same termination must not proceed")
        XCTAssertFalse(gate.claim(), "claim() must stay refused, not just refuse once")
    }

    // MARK: - ExitRestoreOutcome (D5: exit-code split)

    /// D5: the signal path must report a failed restore as a failed process exit, not a
    /// clean one — `KeepAlive={SuccessfulExit=false}` only brings the agent back and
    /// lets the next startup's reconciliation clear a stuck flag if this exit code is
    /// honest. Reverting to an unconditional `exit(0)` (the pre-Sprint-1 behavior) would
    /// make this assert 1 == 0 for the failing case.
    func testExitCodeIsZeroOnSuccessAndOneOnFailure() {
        XCTAssertEqual(ExitRestoreOutcome.exitCode(helperStatus: 0), 0)
        XCTAssertEqual(ExitRestoreOutcome.exitCode(helperStatus: 1), 1)
        XCTAssertEqual(ExitRestoreOutcome.exitCode(helperStatus: -2), 1, "a timeout must count as failure, not success")
    }

    // MARK: - SleepStateBreadcrumbStore (D3: atomic file, D4: prior-state ownership)

    /// The core round-trip through the real fsync+rename write path (D3): a plain
    /// `Data.write(to:options:.atomic)` would also pass a test that merely checks the
    /// bytes come back, so this asserts every field survives, not just "some file
    /// exists" — reverting the encoder/decoder pairing (e.g. dropping a field from
    /// `Codable`) fails this even though the file would still be written.
    func testBreadcrumbRoundTripsThroughARealTempDirectoryIncludingFsyncAndRename() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        XCTAssertNil(SleepStateBreadcrumbStore.read(file: file), "must start absent")

        let wrote = SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: false,
            pid: 4242,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            directory: directory,
            file: file
        )
        XCTAssertTrue(wrote, "a confirmed prior-off state must be allowed to claim ownership")

        // The write goes through a temp file in the SAME directory, then rename() over
        // the target — assert no temp file is left behind and the target is the only
        // thing on disk, which is what proves the rename actually ran (a write that
        // stopped short after fsync but before rename would leave a `.tmp` instead).
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.map(\.lastPathComponent), ["sleep-state.json"])

        let breadcrumb = try XCTUnwrap(SleepStateBreadcrumbStore.read(file: file))
        XCTAssertEqual(breadcrumb.version, SleepStateBreadcrumb.currentVersion)
        XCTAssertEqual(breadcrumb.generation, 1)
        XCTAssertTrue(breadcrumb.owned)
        XCTAssertEqual(breadcrumb.priorSleepDisabled, false)
        XCTAssertEqual(breadcrumb.pid, 4242)
        XCTAssertFalse(breadcrumb.setAt.isEmpty)

        // A second claim on top of an already-owned breadcrumb bumps generation —
        // proves the file is genuinely re-read, not just overwritten blind.
        _ = SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: false, pid: 4242, directory: directory, file: file
        )
        XCTAssertEqual(SleepStateBreadcrumbStore.read(file: file)?.generation, 2)

        XCTAssertTrue(SleepStateBreadcrumbStore.clear(directory: directory, file: file))
        XCTAssertNil(SleepStateBreadcrumbStore.read(file: file), "clear() must remove the file, not blank it")
    }

    /// D4's exact pin: clearing a `disablesleep=1` that Capsomnia never set is itself a
    /// destructive change to someone else's system setting, so the breadcrumb must not
    /// claim ownership when the read taken immediately before the helper call already
    /// showed the system was disabled. Reverting `let owned = priorSleepDisabled ==
    /// false` to an unconditional `owned: true` makes this assert `owned == false` on a
    /// record that now says `true`.
    func testDoesNotClaimOwnershipWhenPriorSleepDisabledWasAlreadyTrue() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        let claimed = SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: true, directory: directory, file: file
        )

        XCTAssertFalse(claimed, "must not claim when disablesleep was already on before Capsomnia acted")
        let breadcrumb = SleepStateBreadcrumbStore.read(file: file)
        XCTAssertEqual(breadcrumb?.owned, false, "the record must say it does not own the setting")
        XCTAssertEqual(breadcrumb?.priorSleepDisabled, true, "and must preserve what it actually saw")
    }

    /// Same non-claim, for the unreadable case. Not knowing the prior state is not
    /// knowing it was Capsomnia's to begin with — ownership fails closed the same
    /// direction as the confirmed-true case above. Reverting the ownership rule from
    /// `== false` to `!= true` (treating "unknown" as claimable) makes this fail.
    func testDoesNotClaimOwnershipWhenPriorSleepStateIsUnreadable() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        let claimed = SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: nil, directory: directory, file: file
        )

        XCTAssertFalse(claimed)
        XCTAssertEqual(SleepStateBreadcrumbStore.read(file: file)?.owned, false)
        XCTAssertNil(SleepStateBreadcrumbStore.read(file: file)?.priorSleepDisabled)
    }

    /// The regression that matters more than ownership: the FIRST implementation
    /// returned early WITHOUT writing anything whenever it could not claim ownership.
    /// The breadcrumb's other job is to be the record that a process was mid-`on` when
    /// it died — and the case where that record is most needed is exactly the case where
    /// `SleepStateReader.isDisabled()` returns `nil`, i.e. this machine's observed
    /// `poll sleep_state_unavailable` episodes. Restoring the `guard priorSleepDisabled
    /// == false else { return false }` early-return makes both asserts below fail: no
    /// file exists at all, so every unclean exit during a flaky spell reports as clean.
    func testRecordsAnUncleanExitSignalEvenWhenItCannotClaimOwnership() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: nil, directory: directory, file: file
        )

        XCTAssertNotNil(
            SleepStateBreadcrumbStore.read(file: file),
            "an unreadable prior state must still leave the unclean-exit record behind"
        )

        SleepStateBreadcrumbStore.markAttemptingOn(
            priorSleepDisabled: true, directory: directory, file: file
        )

        XCTAssertNotNil(
            SleepStateBreadcrumbStore.read(file: file),
            "a foreign-owned prior state must still leave the unclean-exit record behind"
        )
    }

    /// The bug: the explicit-Quit flow marked itself handled so `applicationWillTerminate`
    /// would not repeat the restore — but a termination the user then CANCELLED left that
    /// mark standing for the life of the process, so the NEXT termination arriving through
    /// `applicationWillTerminate` skipped the restore entirely and left `disablesleep=1`
    /// with nobody to clear it. Deleting `terminationCancelled()`'s body (or its call site
    /// in `performExplicitQuitRestore`) makes the final assert below fail.
    func testACancelledTerminationHandsTheRestoreDebtBack() {
        var ledger = QuitRestoreLedger()
        XCTAssertTrue(ledger.shouldRestoreOnWillTerminate, "a fresh process owes the restore")

        ledger.markHandled()
        XCTAssertFalse(
            ledger.shouldRestoreOnWillTerminate,
            "the quit flow already ran it; willTerminate must not repeat it"
        )

        ledger.terminationCancelled()
        XCTAssertTrue(
            ledger.shouldRestoreOnWillTerminate,
            "the user cancelled, so the next termination owes a fresh restore"
        )
    }

    /// `read()` must treat "no file" and "unparsable file" identically — both mean "no
    /// live claim to reconcile against" to every caller. Reverting to a `try!`-style
    /// decode (crashing or throwing out) instead of `try?` would make this test crash
    /// instead of asserting nil.
    func testReadReturnsNilForBothAMissingAndAnUnparsableFile() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        XCTAssertNil(SleepStateBreadcrumbStore.read(file: file), "missing file")

        try Data("not json".utf8).write(to: file)
        XCTAssertNil(SleepStateBreadcrumbStore.read(file: file), "unparsable file")
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitRestoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// A tiny lock-backed counter for the concurrency test above — not `ExitRestoreGate`
/// itself, so the test does not validate the gate by reusing the gate's own machinery.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ value: Int) { _value = value }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
