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
