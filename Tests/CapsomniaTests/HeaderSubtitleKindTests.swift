import XCTest
@testable import Capsomnia

/// Spec Sprint 3 / FINDINGS Defect 4, gated by Design Decision D8: pins the precedence
/// `HeaderSubtitleKind.choose` uses to decide the header's fourth subtitle reason.
final class HeaderSubtitleKindTests: XCTestCase {
    /// This is the core correctness pin for Defect 4's "only when a correct OFF would
    /// otherwise look like a lie" framing. Reverting the `observed == .off` guard would
    /// show "blocking sleep" copy while Capsomnia itself is the reason the Mac is awake —
    /// confusing, not informative.
    func testChooseOnlySurfacesForeignBlockersWhenConfirmedOff() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .on, heldByFloor: false, overridingFloor: false, foreignBlockerCount: 3
            ),
            .modeLabel
        )
    }

    func testChooseSuppressesForeignBlockersAtZeroCount() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: false, overridingFloor: false, foreignBlockerCount: 0
            ),
            .modeLabel
        )
    }

    /// Matches the precedence Sprint 2's `StatusPillPresentation` already established
    /// (floor state always wins) and pins that it doesn't regress when this second,
    /// independent piece of state is added.
    func testChooseStillPrefersFloorStatesOverForeignBlockers() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: true, overridingFloor: false, foreignBlockerCount: 5
            ),
            .heldByFloor
        )
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: false, overridingFloor: true, foreignBlockerCount: 5
            ),
            .overridingFloor
        )
    }

    func testChooseSurfacesForeignBlockersWhenConfirmedOffWithNoFloorStateAndACount() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: false, overridingFloor: false, foreignBlockerCount: 2
            ),
            .foreignBlockers(count: 2)
        )
    }

    /// An unconfirmed state must never gain a confident explanation of who is to blame —
    /// the same principle that makes `.unknown` outrank `heldByFloor` in
    /// `StatusPillPresentation`. Reverting the `observed == .off` guard (e.g. loosening
    /// it to `observed != .on`) would let this wrongly return `.foreignBlockers`.
    func testChooseNeverSurfacesForeignBlockersWhenObservedIsUnknown() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .unknown, heldByFloor: false, overridingFloor: false, foreignBlockerCount: 4
            ),
            .modeLabel
        )
    }
}

/// The subtitle is the third status surface, and it was the one Sprint 2 did not touch.
/// An Evaluator pass found it still rendering the battery floor's confident
/// "held — battery at N%, resumes at M%" right beside the red UNKNOWN pill: a specific
/// claim about system behaviour made at the exact moment the app has no evidence for any
/// of it, which is Defect 1's symptom reintroduced through an unguarded path.
final class HeaderSubtitleUnknownGateTests: XCTestCase {
    /// Removing the `if observed == .unknown` line from `HeaderSubtitleKind.choose` makes
    /// every case below return the confident reason instead of the neutral mode label.
    func testAnUnconfirmedStateGetsNoConfidentExplanation() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .unknown, heldByFloor: true, overridingFloor: false,
                foreignBlockerCount: 0
            ),
            .modeLabel,
            "the floor's 'resumes at N%' is a claim about the system, not about policy alone"
        )
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .unknown, heldByFloor: false, overridingFloor: true,
                foreignBlockerCount: 0
            ),
            .modeLabel
        )
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .unknown, heldByFloor: false, overridingFloor: false,
                foreignBlockerCount: 3
            ),
            .modeLabel,
            "and we cannot name a culprit for a state we have not established"
        )
    }

    /// The gate must not swallow the confident reasons when the state IS confirmed —
    /// otherwise the fix above would silently delete the feature it is protecting.
    func testAConfirmedStateStillGetsItsReason() {
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: true, overridingFloor: false,
                foreignBlockerCount: 0
            ),
            .heldByFloor
        )
        XCTAssertEqual(
            HeaderSubtitleKind.choose(
                observed: .off, heldByFloor: false, overridingFloor: false,
                foreignBlockerCount: 2
            ),
            .foreignBlockers(count: 2)
        )
    }
}

/// "The read failed" and "there is nothing holding the Mac awake" render identically, so
/// the type has to keep them apart — collapsing them to `[]` was a fail-open on a command
/// this machine is measured to fail intermittently.
final class ForeignBlockerReadingTests: XCTestCase {
    func testUnavailableIsNotTheSameAsEmpty() {
        XCTAssertNotEqual(ForeignBlockerReading.unavailable, .none)
        XCTAssertEqual(ForeignBlockerReading.unavailable.names, [])
        XCTAssertEqual(ForeignBlockerReading.none.names, [])
        XCTAssertEqual(ForeignBlockerReading.known(["caffeinate"]).names, ["caffeinate"])
    }
}
