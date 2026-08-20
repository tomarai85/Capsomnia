import AppKit
import XCTest
@testable import Capsomnia

/// The menu header and the battery-floor row are single-line and fixed-width, so a
/// translation that is a few characters too long does not wrap — it silently truncates,
/// and what gets dropped is the end of the sentence: the charge it resumes at. Both
/// strings were written twice before they fit, in English and again in Japanese, which
/// is exactly the kind of thing a measurement should hold instead of an eye.
final class MenuHeaderFitTests: XCTestCase {
    // Mirrors CapsomniaMenuView: menuWidth, the header's paddings/spacings, and the
    // battery-floor row's. Kept as constants here so a layout change breaks this test
    // loudly rather than letting the text quietly clip again.
    private let menuWidth: CGFloat = 300
    private let headerHorizontalPadding: CGFloat = 16 * 2
    private let headerStackGaps: CGFloat = 11 * 3
    private let ledDotWidth: CGFloat = 12
    private let headerSpacerMinimum: CGFloat = 8
    private let pillHorizontalPadding: CGFloat = 9 * 2

    private let floorRowPadding: CGFloat = (12 + 8) * 2
    private let floorIconWidth: CGFloat = 16
    private let floorRowGaps: CGFloat = 10 + 4
    private let chipHorizontalPadding: CGFloat = 9 * 2

    private func width(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
            .width
            .rounded(.up)
    }

    /// Widest values these strings can actually carry: the floor tops out at 90, a held
    /// charge is by definition at or below the floor, and recovery is floor + 5. Nothing
    /// here ever reaches three digits, so testing 100 would be inventing a case and
    /// forcing the copy shorter than it needs to be.
    private let widestFloor = BatteryFloorInput.range.upperBound
    private var widestRecover: Int { widestFloor + 5 }

    func testHeldSubtitleFitsBesideTheStatusPillInEveryLanguage() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)
            let subtitle = TextTemplate.fill(
                strings.batteryFloorHeldFormat, ["battery": widestFloor, "recover": widestRecover]
            )
            let pill = width(strings.statusHeld, size: 11, weight: .semibold) + pillHorizontalPadding
            let available = menuWidth - headerHorizontalPadding - headerStackGaps
                - ledDotWidth - headerSpacerMinimum - pill

            XCTAssertLessThanOrEqual(
                width(subtitle, size: 11), available,
                "\(language): held subtitle \"\(subtitle)\" truncates beside the \"\(strings.statusHeld)\" pill"
            )
        }
    }

    func testOverridingSubtitleFitsBesideTheStatusPillInEveryLanguage() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)
            let subtitle = TextTemplate.fill(
                strings.batteryFloorOverrideSubtitleFormat,
                ["battery": widestFloor, "critical": BatteryFloorPolicy.criticalPercent]
            )
            // Overriding shows the plain ON pill. "OFF" is the wider of the two plain
            // titles, so measuring against it is the conservative bound.
            let pill = width("OFF", size: 11, weight: .semibold) + pillHorizontalPadding
            let available = menuWidth - headerHorizontalPadding - headerStackGaps
                - ledDotWidth - headerSpacerMinimum - pill

            XCTAssertLessThanOrEqual(
                width(subtitle, size: 11), available,
                "\(language): overriding subtitle \"\(subtitle)\" truncates"
            )
        }
    }

    /// Sprint 2 (FINDINGS Defect 1/3): the UNKNOWN pill can appear beside the ordinary
    /// mode-label subtitle — `heldByFloor` and `unknown` are mutually exclusive
    /// (`StatusPillPresentation.choose` always prefers held), so that pairing is the
    /// realistic worst case to measure, using the exact envelope formula
    /// `testHeldSubtitleFitsBesideTheStatusPillInEveryLanguage` established. The widest of
    /// the three mode labels is used, matching the file's convention of testing worst-case
    /// values rather than whichever mode a human happened to be looking at.
    func testUnknownPillFitsBesideTheLEDDotInEveryLanguage() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)
            let modeLabels = [strings.modeOff, strings.modeCapsLock, strings.modeAuto]
            let widestMode = modeLabels.max { width($0, size: 11) < width($1, size: 11) } ?? ""
            let subtitle = "\(strings.keepAwakeHeading) · \(widestMode)"
            let pill = width(strings.statusUnknown, size: 11, weight: .semibold) + pillHorizontalPadding
            let available = menuWidth - headerHorizontalPadding - headerStackGaps
                - ledDotWidth - headerSpacerMinimum - pill

            XCTAssertLessThanOrEqual(
                width(subtitle, size: 11), available,
                "\(language): subtitle \"\(subtitle)\" truncates beside the \"\(strings.statusUnknown)\" pill"
            )
        }
    }

    /// Sprint 3 (FINDINGS Defect 4, gated by Design Decision D8): the foreign-blockers
    /// subtitle only ever shows beside the plain `"OFF"` pill — it requires `observed ==
    /// .off` with no floor state active (`HeaderSubtitleKind.choose`), so `"OFF"` is the
    /// exact pill to measure against, not a conservative stand-in. Count 9 matches the
    /// file's own convention of not inventing a 3-digit case; D8 itself flags the copy as
    /// sized "by eye" and defers the real check to this test — a failure here means
    /// shorten that language's copy, never weaken the envelope.
    func testForeignBlockersSubtitleFitsBesideTheStatusPillInEveryLanguage() {
        // The realistic worst case, not a synthetic one: the longest process name that
        // actually turns up holding a system-sleep assertion (`WindowServer`, 12) plus a
        // two-digit remainder. A name of all-wide glyphs would still overrun any
        // character cap — `.lineLimit(1)` on the subtitle is the backstop for that, and
        // widening this envelope to accommodate a string macOS does not produce would
        // make the test stop pinning the case that has to look right.
        let worstCaseBlockers = ForeignBlockerSummary.render(
            names: ["WindowServer"] + (1...20).map { "p\($0)" }
        )
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)
            let subtitle = TextTemplate.fill(
                strings.foreignSleepBlockersSubtitleFormat,
                ["blockers": worstCaseBlockers ?? ""]
            )
            let pill = width("OFF", size: 11, weight: .semibold) + pillHorizontalPadding
            let available = menuWidth - headerHorizontalPadding - headerStackGaps
                - ledDotWidth - headerSpacerMinimum - pill

            XCTAssertLessThanOrEqual(
                width(subtitle, size: 11), available,
                "\(language): foreign-blockers subtitle \"\(subtitle)\" truncates beside the \"OFF\" pill"
            )
        }
    }

    func testOverrideChipFitsBesideTheBatteryFloorLabelInEveryLanguage() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)
            let label = width(strings.batteryFloorMenu, size: 13)
            let available = menuWidth - floorRowPadding - floorIconWidth - floorRowGaps - label

            for chip in [strings.batteryFloorOverride, strings.batteryFloorOverrideActive] {
                XCTAssertLessThanOrEqual(
                    width(chip, size: 11.5, weight: .semibold) + chipHorizontalPadding, available,
                    "\(language): chip \"\(chip)\" does not fit beside \"\(strings.batteryFloorMenu)\""
                )
            }
        }
    }
}
