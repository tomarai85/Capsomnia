import XCTest
@testable import Capsomnia

/// Sprint 1b — the defects an adversarial Codex review found in Sprint 1's own fix.
/// Full triage, including the one finding deliberately deferred and why:
/// `.harness/evidence-2026-08-20/sprint1b-triage.md`.
final class ExitCoordinationTests: XCTestCase {
    // MARK: The losing exit path must not return into silence

    /// The regression Sprint 1 introduced: the gate was a one-shot Bool and the loser
    /// returned WITHOUT calling `exit()`, so a winner that stalled meant every later
    /// SIGTERM was swallowed and only SIGKILL could end the process — which skips the
    /// restore entirely, i.e. strictly worse than the race the gate was added to remove.
    /// Deleting `complete(status:)`'s `broadcast()` (or its call sites) makes this hang
    /// to the timeout and return nil instead of the winner's status.
    func testTheLoserLearnsTheWinnersStatusInsteadOfWaitingForever() {
        let gate = ExitRestoreGate()
        XCTAssertTrue(gate.claim(), "the first caller must win")
        XCTAssertFalse(gate.claim(), "the second caller must lose")

        let publisher = expectation(description: "winner published")
        DispatchQueue.global().async {
            gate.complete(status: 7)
            publisher.fulfill()
        }

        XCTAssertEqual(
            gate.awaitCompletion(timeout: 5),
            7,
            "the loser must leave with the winner's real outcome, not a guess"
        )
        wait(for: [publisher], timeout: 5)
    }

    /// ...and it must still leave when the winner never publishes anything at all — a
    /// hung `sudo`, a stuck main actor. Returning nil is what lets the caller exit
    /// non-zero rather than hold the process open. Removing the deadline from
    /// `awaitCompletion` makes this test hang instead of failing.
    func testTheLoserGivesUpOnAWinnerThatNeverFinishes() {
        let gate = ExitRestoreGate()
        XCTAssertTrue(gate.claim())

        let started = Date()
        XCTAssertNil(
            gate.awaitCompletion(timeout: 0.3),
            "a winner that never publishes must not hold the process open"
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the wait must be bounded")
    }

    /// A published status must stay readable — the loser can arrive after the winner has
    /// already finished, which is the ordinary case when the restore is fast.
    func testAStatusPublishedBeforeTheWaitIsStillReturned() {
        let gate = ExitRestoreGate()
        XCTAssertTrue(gate.claim())
        gate.complete(status: 0)

        XCTAssertEqual(gate.awaitCompletion(timeout: 0.3), 0)
    }

    // MARK: Nothing may be turned back ON once the exit restore has begun

    /// The Critical finding: the main actor issues `helper on`, SIGTERM lands mid-call,
    /// the signal handler runs `helper off`, sees status 0, deletes the breadcrumb and
    /// exits 0 — and the earlier `on` lands last. Clean exit, `helper_status=0` in the
    /// log, no breadcrumb, and `disablesleep=1` still on the machine. The latch is what
    /// stops an `on` that has not started yet from ever starting; deleting
    /// `beginTermination()`'s body makes this assert a false where true is required.
    func testTerminationLatchesAndNeverUnlatches() {
        let coordinator = HelperCoordinator()
        XCTAssertFalse(coordinator.isTerminating, "a fresh process is not terminating")

        coordinator.beginTermination()
        XCTAssertTrue(coordinator.isTerminating)

        // No API un-latches it, and none should: there is no path back from termination,
        // and a flag that could be cleared could be cleared by the wrong path.
        XCTAssertTrue(coordinator.isTerminating, "the latch must survive re-reading")
    }

    /// The bounded half of the same fix. The exit path waits for an in-flight helper
    /// call, but only for `priorityWait` — waiting forever would put the signal handler
    /// back behind main-actor work, which is what made the app unkillable before this
    /// whole line of work started. `contended` is what makes a hurried exit visible in
    /// the log instead of indistinguishable from a clean one. Reverting `withPriority`
    /// to a plain blocking `lock()` makes this test hang; reverting it to report
    /// `contended: false` unconditionally fails the assert.
    func testPriorityRunsAnywayAndReportsContentionWhenTheLockIsHeld() {
        let coordinator = HelperCoordinator(priorityWait: 0.2)
        let holderHasLock = expectation(description: "holder acquired")
        let releaseHolder = expectation(description: "holder released")

        DispatchQueue.global().async {
            coordinator.serialized {
                holderHasLock.fulfill()
                // Held well past `priorityWait`, so the priority caller cannot get it.
                _ = XCTWaiter.wait(for: [releaseHolder], timeout: 2)
            }
        }
        wait(for: [holderHasLock], timeout: 5)

        var ran = false
        let (_, contended) = coordinator.withPriority { ran = true }

        XCTAssertTrue(ran, "the exit restore must run even when it cannot get the lock")
        XCTAssertTrue(contended, "and it must say so, so a hurried exit is visible in the log")
        releaseHolder.fulfill()
    }

    /// Uncontended is the ordinary case and must NOT be reported as contended, or the
    /// signal loses all value.
    func testPriorityReportsNoContentionWhenTheLockIsFree() {
        let coordinator = HelperCoordinator(priorityWait: 0.2)
        let (value, contended) = coordinator.withPriority { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(contended)
    }

    // MARK: A definite failure must give the ownership claim back

    /// The claim is written BEFORE the helper call, so a call that definitely changed
    /// nothing leaves a claim to something that never happened. Left standing, the next
    /// attempt sees `owned == true`, skips re-reading the prior state, and keeps claiming
    /// a setting Capsomnia never set — which a later reconciliation would then clear.
    /// Making `releaseClaim` a no-op makes the second assert below find the stale claim.
    func testReleaseClaimRemovesAClaimAFailedAttemptNeverEarned() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitCoordinationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        XCTAssertTrue(
            SleepStateBreadcrumbStore.markAttemptingOn(
                priorSleepDisabled: false, directory: directory, file: file
            ),
            "a confirmed prior-off state claims ownership"
        )
        XCTAssertEqual(SleepStateBreadcrumbStore.read(file: file)?.owned, true)

        SleepStateBreadcrumbStore.releaseClaim(directory: directory, file: file)

        XCTAssertNil(
            SleepStateBreadcrumbStore.read(file: file),
            "a definite failure must not leave a claim behind"
        )
    }

    /// `clear()` on an already-absent file is success, not failure — the caller's
    /// question is "is there a claim to reconcile", and the answer is no either way.
    /// Reverting to `(try? removeItem) != nil` alone makes this report failure.
    func testClearReportsSuccessWhenThereWasNothingToClear() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitCoordinationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep-state.json")

        XCTAssertTrue(SleepStateBreadcrumbStore.clear(directory: directory, file: file))
    }
}
