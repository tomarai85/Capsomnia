import XCTest
@testable import Capsomnia

/// These calls are made synchronously from the main actor, and the signal handlers that
/// put system sleep back used to share it. A child that never answers therefore froze
/// the app and made it unkillable short of SIGKILL — which skips the restore. Both
/// properties below are what stop that, so both are pinned here.
final class CommandRunnerTests: XCTestCase {
    func testReturnsOutputAndStatusForAWellBehavedCommand() {
        let result = CommandRunner.run("/bin/echo", ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "")
    }

    func testNonZeroExitIsReportedNotSwallowed() {
        let result = CommandRunner.run("/usr/bin/false", [])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertNotEqual(result.status, CommandRunner.timedOutStatus)
    }

    func testAHangingCommandIsKilledAndReportedAsTimedOut() {
        let started = ContinuousClock.now
        let result = CommandRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        let elapsed = started.duration(to: ContinuousClock.now)

        XCTAssertEqual(result.status, CommandRunner.timedOutStatus)
        XCTAssertTrue(result.stderr.contains("timed out"))
        // Generous, but far below the 30s the child asked for: the point is that it
        // returned at all rather than that it returned fast.
        XCTAssertLessThan(elapsed, .seconds(10), "the caller was not released")
    }

    /// The old implementation waited on the process and only then read the pipes, which
    /// deadlocks the moment a child fills a 64KB pipe buffer. It survived in production
    /// purely because pmset says so little.
    func testOutputLargerThanAPipeBufferDoesNotDeadlock() {
        let result = CommandRunner.run(
            "/bin/dd", ["if=/dev/zero", "bs=1024", "count=128"], timeout: 20
        )
        XCTAssertEqual(result.status, 0, "a child writing 128KB must still complete")
        XCTAssertGreaterThan(result.stdout.count, 64 * 1024)
    }
}
