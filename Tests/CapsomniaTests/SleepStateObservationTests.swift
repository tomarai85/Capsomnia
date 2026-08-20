import XCTest
@testable import Capsomnia

/// Pins the tri-state fix for FINDINGS Defect 1 + Defect 3: the app must never display a
/// state it has not confirmed. `SleepStateObservation.from` is the exact boundary — a
/// failing helper always collapses to `.unknown`, never to a confident on/off borrowed
/// from whatever was last confirmed.
final class SleepStateObservationTests: XCTestCase {
    /// Defect 1's exact pin: reverting `.from` to ignore `helperFailing` (trusting
    /// `lastConfirmed` alone) makes the `lastConfirmed: true` case wrongly return `.on` —
    /// a confident, wrong answer at exactly the moment the app has no evidence.
    func testUnknownWhenHelperIsFailingRegardlessOfLastConfirmed() {
        XCTAssertEqual(
            SleepStateObservation.from(lastConfirmed: true, helperFailing: true), .unknown
        )
        XCTAssertEqual(
            SleepStateObservation.from(lastConfirmed: false, helperFailing: true), .unknown
        )
    }

    /// Pins the cold-start case: before the first confirming read has ever landed, the
    /// app knows nothing, which is not the same fact as "confirmed off". Reverting to
    /// "nil means off" (a plausible naive implementation) fails this.
    func testUnknownWhenNeverConfirmed() {
        XCTAssertEqual(
            SleepStateObservation.from(lastConfirmed: nil, helperFailing: false), .unknown
        )
    }

    func testOnAndOffOnlyWhenConfirmedAndNotFailing() {
        XCTAssertEqual(
            SleepStateObservation.from(lastConfirmed: true, helperFailing: false), .on
        )
        XCTAssertEqual(
            SleepStateObservation.from(lastConfirmed: false, helperFailing: false), .off
        )
    }

    /// Held wins over a CONFIRMED on/off: "off because the floor stepped in" and "off
    /// because you asked for it" are different facts and must not collapse. Removing the
    /// `if heldByFloor` branch makes both cases below report the raw observation instead.
    func testChoosePrefersHeldOverAConfirmedObservation() {
        for observed: SleepStateObservation in [.on, .off] {
            XCTAssertEqual(
                StatusPillPresentation.choose(observed: observed, heldByFloor: true), .held,
                "observed=\(observed)"
            )
        }
    }

    /// ...but NOT over `.unknown`. "Held" also tells the reader the Mac is free to sleep
    /// right now — a claim about the SYSTEM, and precisely the claim the app cannot make
    /// while its helper or verification read is failing. Held winning there also put a
    /// calm "PAUSED" in the popover beside the menu bar's red error dot, i.e. the
    /// two-surfaces-disagreeing defect this sprint exists to remove, moved rather than
    /// fixed. Putting the `if heldByFloor` check back in front of the `.unknown` check
    /// makes this assert `.held` where `.unknown` is required.
    func testUnknownOutranksHeldBecauseHeldIsAlsoAClaimAboutTheSystem() {
        XCTAssertEqual(
            StatusPillPresentation.choose(observed: .unknown, heldByFloor: true), .unknown,
            "an unconfirmed state must not be dressed up as a calm, policy-explained pause"
        )
    }

    /// `.held`/`.unknown` route through the localizable `MenuStrings` object; `.on`/`.off`
    /// stay the existing hardcoded "ON"/"OFF" — matching current behavior, unchanged by
    /// this sprint. Reverting either half of that asymmetry fails.
    func testTitleUsesTheStringsObjectForHeldAndUnknownButFixedTextForOnOff() {
        var strings = MenuStrings(
            appName: "Capsomnia",
            keepAwakeHeading: "Keep awake",
            modeOff: "Off",
            modeCapsLock: "Caps Lock",
            modeAuto: "Auto",
            batteryFloorMenu: "Battery floor",
            showMenuBarIcon: "Show menu bar icon",
            language: "Language",
            openCapsomnia: "Open Capsomnia",
            quit: "Quit",
            statusHeld: "PAUSED-TEST",
            statusUnknown: "UNKNOWN-TEST",
            batteryFloorHeldFormat: "",
            batteryFloorOverride: "",
            batteryFloorOverrideActive: "",
            batteryFloorOverrideSubtitleFormat: "",
            foreignSleepBlockersSubtitleFormat: ""
        )

        XCTAssertEqual(StatusPillPresentation.held.title(strings: strings), "PAUSED-TEST")
        XCTAssertEqual(StatusPillPresentation.unknown.title(strings: strings), "UNKNOWN-TEST")
        XCTAssertEqual(StatusPillPresentation.on.title(strings: strings), "ON")
        XCTAssertEqual(StatusPillPresentation.off.title(strings: strings), "OFF")

        // Changing the strings object must not affect on/off — they are fixed text, not
        // localized lookups.
        strings.statusHeld = "changed"
        strings.statusUnknown = "changed"
        XCTAssertEqual(StatusPillPresentation.on.title(strings: strings), "ON")
        XCTAssertEqual(StatusPillPresentation.off.title(strings: strings), "OFF")
    }
}
