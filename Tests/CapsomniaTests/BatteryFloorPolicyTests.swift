import XCTest
@testable import Capsomnia

final class BatteryFloorPolicyTests: XCTestCase {
    private func decide(
        intent: Bool = true,
        floorEnabled: Bool = true,
        floor: Int = 15,
        margin: Int = 5,
        onAC: Bool = false,
        percent: Int? = 50,
        batteryReadable: Bool = true,
        latched: Bool = false,
        overrideActive: Bool = false,
        critical: Int = BatteryFloorPolicy.criticalPercent
    ) -> BatteryFloorPolicy.Decision {
        BatteryFloorPolicy.decide(
            intent: intent,
            floorEnabled: floorEnabled,
            floorPercent: floor,
            recoverMargin: margin,
            onAC: onAC,
            percent: percent,
            batteryReadable: batteryReadable,
            latched: latched,
            overrideActive: overrideActive,
            criticalPercent: critical
        )
    }

    func testNoIntentNeverKeepsAwake() {
        let result = decide(intent: false, latched: true)
        XCTAssertFalse(result.keepAwake)
        XCTAssertEqual(result.status, .normal)
        // Charge is back above the recover threshold, so the latch is cleared by the
        // battery — not by the absence of intent.
        XCTAssertFalse(result.latched)
    }

    /// The regression this whole change exists for: the latch belongs to the battery, so
    /// nothing about what the user wants may reset it. It used to be cleared whenever
    /// intent went false (a Caps Lock tap, switching to Off) and in the three preference
    /// setters, which is why the same charge could read as released or awake depending on
    /// whether the user had touched a control since.
    func testLatchSurvivesIntentGoingAway() {
        let result = decide(intent: false, percent: 17, latched: true)
        XCTAssertFalse(result.keepAwake)
        XCTAssertTrue(result.latched, "intent must not reset the hysteresis latch")
    }

    func testLatchSurvivesAModeThatWantsAwakeAgain() {
        // auto -> capsLock(off) -> auto at an unchanged 17%: still released, both times.
        let released = decide(intent: true, percent: 17, latched: true)
        let viaIntentOff = decide(intent: false, percent: 17, latched: released.latched)
        let backOn = decide(intent: true, percent: 17, latched: viaIntentOff.latched)
        XCTAssertFalse(backOn.keepAwake)
        XCTAssertTrue(backOn.latched)
        XCTAssertEqual(backOn.status, .heldByFloor(percent: 17))
    }

    func testACClearsTheLatchEvenWithoutIntent() {
        let result = decide(intent: false, onAC: true, percent: 8, latched: true)
        XCTAssertFalse(result.latched)
    }

    func testFloorDisabledKeepsAwakeEvenWhenEmpty() {
        let result = decide(floorEnabled: false, percent: 3)
        XCTAssertTrue(result.keepAwake)
        XCTAssertFalse(result.latched)
    }

    func testUnreadablePowerStaysAwakeAndPreservesLatch() {
        let result = decide(percent: nil, batteryReadable: false, latched: true)
        XCTAssertTrue(result.keepAwake)
        XCTAssertTrue(result.latched)
    }

    func testOnACAlwaysKeepsAwakeAndClearsLatch() {
        let result = decide(onAC: true, percent: 5, latched: true)
        XCTAssertTrue(result.keepAwake)
        XCTAssertFalse(result.latched)
    }

    func testUnknownPercentOnBatteryStaysAwake() {
        let result = decide(percent: nil)
        XCTAssertTrue(result.keepAwake)
    }

    func testAboveFloorKeepsAwake() {
        let result = decide(percent: 16)
        XCTAssertTrue(result.keepAwake)
        XCTAssertFalse(result.latched)
    }

    func testAtFloorReleasesAndLatches() {
        let result = decide(percent: 15)
        XCTAssertFalse(result.keepAwake)
        XCTAssertTrue(result.latched)
    }

    func testBelowFloorReleasesAndLatches() {
        let result = decide(percent: 10)
        XCTAssertFalse(result.keepAwake)
        XCTAssertTrue(result.latched)
    }

    func testHysteresisHoldsBetweenFloorAndRecover() {
        // latched at 17% (> floor 15 but < recover 20) must stay released -> no oscillation
        let result = decide(percent: 17, latched: true)
        XCTAssertFalse(result.keepAwake)
        XCTAssertTrue(result.latched)
    }

    func testHysteresisReleasesAtRecoverThreshold() {
        let result = decide(percent: 20, latched: true)
        XCTAssertTrue(result.keepAwake)
        XCTAssertFalse(result.latched)
    }

    // MARK: Reasoned status

    func testStatusSeparatesChosenOffFromHeldOff() {
        // Both stop keeping the Mac awake; only one of them is the app overruling the user.
        XCTAssertEqual(decide(intent: false, percent: 80).status, .normal)
        XCTAssertEqual(decide(intent: true, percent: 10).status, .heldByFloor(percent: 10))
    }

    func testStatusIsAwakeWhenNothingIsHoldingItBack() {
        XCTAssertEqual(decide(percent: 80).status, .awake)
        XCTAssertEqual(decide(onAC: true, percent: 3).status, .awake)
        XCTAssertEqual(decide(floorEnabled: false, percent: 3).status, .awake)
    }

    func testStatusReportsUnreadablePower() {
        XCTAssertEqual(decide(percent: nil, batteryReadable: false).status, .awakePowerUnknown)
        XCTAssertEqual(decide(percent: nil).status, .awakePowerUnknown)
    }

    // MARK: Override

    func testOverrideKeepsAwakeBelowTheFloor() {
        let result = decide(percent: 12, overrideActive: true, critical: 10)
        XCTAssertTrue(result.keepAwake)
        XCTAssertEqual(result.status, .overriding(percent: 12))
    }

    /// The override is consent to run low, not consent to run flat.
    func testOverrideIsRefusedAtAndBelowCritical() {
        XCTAssertFalse(decide(percent: 10, overrideActive: true, critical: 10).keepAwake)
        XCTAssertFalse(decide(percent: 4, overrideActive: true, critical: 10).keepAwake)
        XCTAssertEqual(decide(percent: 10, overrideActive: true, critical: 10).status,
                       .heldByFloor(percent: 10))
    }

    /// Dropping the override has to land back on the floor's decision, so the latch it
    /// would need must have been maintained the whole time it was overridden.
    func testOverrideDoesNotDisturbTheLatch() {
        let overridden = decide(percent: 12, latched: true, overrideActive: true, critical: 10)
        XCTAssertTrue(overridden.latched)
        let dropped = decide(percent: 12, latched: overridden.latched, overrideActive: false)
        XCTAssertFalse(dropped.keepAwake)
        XCTAssertEqual(dropped.status, .heldByFloor(percent: 12))
    }

    func testOverrideIsIrrelevantAboveTheFloor() {
        XCTAssertEqual(decide(percent: 60, overrideActive: true).status, .awake)
    }

    // MARK: Typed battery-floor input

    func testParseAcceptsPlainNumber() {
        XCTAssertEqual(BatteryFloorInput.parse("35"), 35)
    }

    func testParseToleratesPercentSignAndWhitespace() {
        XCTAssertEqual(BatteryFloorInput.parse("  40 % "), 40)
    }

    func testParseClampsInsteadOfRejectingOutOfRange() {
        XCTAssertEqual(BatteryFloorInput.parse("99"), BatteryFloorInput.range.upperBound)
        XCTAssertEqual(BatteryFloorInput.parse("0"), BatteryFloorInput.range.lowerBound)
    }

    func testParseRejectsNonNumericSoTheOldValueSurvives() {
        XCTAssertNil(BatteryFloorInput.parse(""))
        XCTAssertNil(BatteryFloorInput.parse("   "))
        XCTAssertNil(BatteryFloorInput.parse("abc"))
        XCTAssertNil(BatteryFloorInput.parse("1.5"))
        XCTAssertNil(BatteryFloorInput.parse("-10"))
    }
}
