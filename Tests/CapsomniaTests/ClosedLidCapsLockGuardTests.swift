import XCTest
@testable import Capsomnia

/// The closed-lid guard, ported from upstream v3.1.0 (PR #76) and reshaped for this
/// fork's poll-driven engine: it HOLDS the intent instead of re-asserting Caps Lock.
/// The rows pin the boundaries that make it safe, not just the happy path.
final class ClosedLidCapsLockGuardTests: XCTestCase {
    private func hold(
        pref: Bool = true,
        mode: KeepAwakeMode = .capsLock,
        flagOn: Bool = false,
        lastApplied: Bool? = true,
        clamshell: Bool? = true
    ) -> Bool {
        ClosedLidCapsLockGuard.shouldHoldIntent(
            preferenceEnabled: pref,
            mode: mode,
            capsLockFlagOn: flagOn,
            lastAppliedKeepAwake: lastApplied,
            clamshellClosed: clamshell
        )
    }

    func testHoldsWhenExternalOffArrivesWithLidClosed() {
        XCTAssertTrue(hold())
    }

    func testDisabledPreferenceNeverHolds() {
        XCTAssertFalse(hold(pref: false))
    }

    /// The guard exists for Caps Lock mode only: in Auto the flag is not what decides,
    /// and in Off there is nothing to protect. Mode changes from the menu are also the
    /// intentional way OUT of a hold — leaving .capsLock must end it.
    func testOtherModesNeverHold() {
        XCTAssertFalse(hold(mode: .auto))
        XCTAssertFalse(hold(mode: .off))
    }

    func testFlagOnMeansNothingToHold() {
        XCTAssertFalse(hold(flagOn: true))
    }

    /// A hold may only continue a keep-awake that was actually running. From a cold
    /// start (nothing applied yet) or from an applied OFF, an off-flag is just an
    /// off-flag — resurrecting sleep prevention the user never had would be the guard
    /// inventing state.
    func testNeverResurrectsFromColdOrOffState() {
        XCTAssertFalse(hold(lastApplied: nil))
        XCTAssertFalse(hold(lastApplied: false))
    }

    /// Unavailable clamshell state fails OPEN (the turn-off is honored) — upstream's
    /// own rule, kept: guessing "closed" would hold sleep prevention on a machine
    /// whose lid may be wide open with the user watching the flag do nothing.
    func testUnknownClamshellFailsOpen() {
        XCTAssertFalse(hold(clamshell: nil))
    }

    func testOpenLidFollowsTheFlag() {
        XCTAssertFalse(hold(clamshell: false))
    }

    /// Interaction pin: the guard shapes INTENT only. The battery floor keeps final
    /// authority — a held intent below the floor must still release, or the guard
    /// would quietly disable the safety that keeps charge in reserve.
    func testBatteryFloorStillOverridesAHeldIntent() {
        let decision = BatteryFloorPolicy.decide(
            intent: true, // what the guard produces while holding
            floorEnabled: true,
            floorPercent: 15,
            recoverMargin: 5,
            onAC: false,
            percent: 10,
            batteryReadable: true,
            latched: true,
            overrideActive: false
        )
        XCTAssertFalse(decision.keepAwake)
    }
}
