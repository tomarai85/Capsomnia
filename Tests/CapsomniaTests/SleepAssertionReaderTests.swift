import XCTest
@testable import Capsomnia

/// Spec Sprint 3 / FINDINGS Defect 4, gated by Design Decision D8: `powerd` holds
/// `PreventUserIdleSystemSleep` whenever the display is on, so a naive "count every
/// owner" would report "1 app blocking sleep" essentially always — the same defect this
/// whole harness run exists to fix, pointed the other way. These tests pin the filter,
/// the exclusion, and the de-dup, using the REAL `pmset -g assertions` capture from the
/// machine that proved the defect (`.harness/evidence-2026-08-20/pmset-assertions-sample.txt`),
/// not a hand-written string, per D8 rule 5.
final class SleepAssertionReaderTests: XCTestCase {
    /// The test target declares no SPM `resources:`, so this walks up from this file's
    /// own source location to the repo root instead of inventing a bundled fixture.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CapsomniaTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static let capturedSample: String = {
        let url = repoRoot.appendingPathComponent(
            ".harness/evidence-2026-08-20/pmset-assertions-sample.txt"
        )
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    func testParseExtractsDistinctProcessNamesHoldingASystemSleepAssertion() {
        let output = """
           pid 100(caffeinate): [0x1] 00:01:00 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 200(sharingd): [0x2] 00:01:49 PreventUserIdleSystemSleep named: "Handoff"
        """

        XCTAssertEqual(SleepAssertionReader.parse(output), ["caffeinate", "sharingd"])
    }

    /// FINDINGS' own observed evidence: "caffeinate, powerd, caffeinate, caffeinate".
    /// Reverting the `Set`-backed dedup makes the count wrong for exactly the case
    /// already proven to occur on Tom's machine.
    func testParseDedupesRepeatedAssertionsFromTheSameProcess() {
        let output = """
           pid 100(caffeinate): [0x1] 00:02:58 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 200(caffeinate): [0x2] 00:01:49 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 300(caffeinate): [0x3] 00:01:09 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """

        XCTAssertEqual(SleepAssertionReader.parse(output), ["caffeinate"])
    }

    /// A `PreventUserIdleDisplaySleep`-only line (no `PreventUserIdleSystemSleep`/
    /// `PreventSystemSleep`) must not appear — reverting the assertion-type filter would
    /// report a process that only keeps the DISPLAY on as if it were keeping the SYSTEM
    /// from sleeping, a wrong and alarming claim.
    func testParseExcludesDisplayOnlyAssertions() {
        let output = """
           pid 999(SomeHelper): [0x1] 00:00:01 PreventUserIdleDisplaySleep named: "keep screen on"
        """

        XCTAssertEqual(SleepAssertionReader.parse(output), [])
    }

    func testParseReturnsEmptyNotCrashingOnUnexpectedOutput() {
        XCTAssertEqual(SleepAssertionReader.parse(""), [])
        XCTAssertEqual(SleepAssertionReader.parse("not pmset output at all\n%%%garbage###"), [])
    }

    /// D8's exact negative control. The real sample has FOUR separate `caffeinate` pids,
    /// `powerd` holding `PreventUserIdleSystemSleep`, `sharingd`, `coreaudiod`, and
    /// `WindowServer` holding only `UserIsActive` (not a system-sleep-blocking type).
    /// Reverting the `powerd` exclusion in `SleepAssertionReader` must fail this test.
    func testParseOfRealCapturedSampleExcludesPowerdAndDedupesCaffeinate() {
        XCTAssertFalse(Self.capturedSample.isEmpty, "fixture did not load from \(Self.repoRoot)")

        let names = SleepAssertionReader.parse(Self.capturedSample)

        XCTAssertEqual(Set(names), ["caffeinate", "sharingd", "coreaudiod"])
        XCTAssertEqual(names.count, 3, "caffeinate's 4 pids must collapse to 1 entry")
        XCTAssertFalse(names.contains("powerd"))
        XCTAssertFalse(names.contains("WindowServer"), "UserIsActive does not block system sleep")
    }
}

/// The header line has to answer the question the user actually opened the menu with:
/// not "how many things", but "WHICH thing is keeping my Mac awake". On this machine the
/// answer is `caffeinate`, which points straight at the terminal sessions responsible —
/// a bare count points at nothing.
final class ForeignBlockerSummaryTests: XCTestCase {
    /// Reverting `render` to return only a count makes this assert a name where a number
    /// now appears.
    func testNamesTheFirstBlockerAndCountsTheRest() {
        XCTAssertEqual(ForeignBlockerSummary.render(names: ["caffeinate"]), "caffeinate")
        XCTAssertEqual(
            ForeignBlockerSummary.render(names: ["caffeinate", "sharingd", "coreaudiod"]),
            "caffeinate +2"
        )
    }

    /// Nothing to say must render nothing at all — never "0 apps", never an empty
    /// subtitle shell with the surrounding copy still on screen (D8 rule 4).
    func testRendersNothingWhenThereAreNoBlockers() {
        XCTAssertNil(ForeignBlockerSummary.render(names: []))
    }

    /// One long name must not run away with a single-line header. Removing the
    /// truncation makes this return the full 40-character string.
    func testTruncatesAnOverlongNameAtTheCeiling() {
        let rendered = ForeignBlockerSummary.render(names: [String(repeating: "a", count: 40)])

        XCTAssertEqual(rendered?.count, ForeignBlockerSummary.maxNameLength)
        XCTAssertEqual(rendered?.hasSuffix("\u{2026}"), true, "truncation must be visible, not silent")
    }

    /// A name exactly at the ceiling is not truncated — an off-by-one here would put an
    /// ellipsis on a name that fits.
    func testDoesNotTruncateANameThatExactlyFits() {
        let name = String(repeating: "a", count: ForeignBlockerSummary.maxNameLength)

        XCTAssertEqual(ForeignBlockerSummary.render(names: [name]), name)
    }
}

/// The parser used to ask `line.contains(type)`, which matches the type ANYWHERE on the
/// line — including inside the quoted human-readable assertion name that follows it. A
/// display-only assertion whose name merely mentions system sleep was therefore reported
/// as a system-sleep blocker, and a process name containing parentheses was truncated at
/// the first one.
final class SleepAssertionParsingPrecisionTests: XCTestCase {
    /// Restoring the whole-line `contains` check makes this report `diagnosticd`, which
    /// is not preventing system sleep at all.
    func testATypeNameQuotedInsideTheAssertionNameIsNotTreatedAsTheType() {
        let output = """
        Listed by owning process:
           pid 900(diagnosticd): [0x0001] 00:00:10 PreventUserIdleDisplaySleep named: "PreventUserIdleSystemSleep diagnostics"
        """

        XCTAssertEqual(
            SleepAssertionReader.parse(output), [],
            "only the captured type token may decide, never a substring of the name"
        )
    }

    /// ...and the real thing still parses, so the precision fix cannot have been bought
    /// by simply matching nothing.
    func testTheRealTypeTokenStillMatches() {
        let output = """
        Listed by owning process:
           pid 3453(caffeinate): [0x0001] 00:02:58 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """

        XCTAssertEqual(SleepAssertionReader.parse(output), ["caffeinate"])
    }

    /// Anchoring on `"): "` rather than the first `)` keeps a name containing parentheses
    /// whole. Reverting to `firstIndex(of: ")")` reports "Foo" instead.
    func testAProcessNameContainingParenthesesSurvivesIntact() {
        let output = """
        Listed by owning process:
           pid 42(Foo (Helper)): [0x0001] 00:00:05 PreventSystemSleep named: "work"
        """

        XCTAssertEqual(SleepAssertionReader.parse(output), ["Foo (Helper)"])
    }
}
