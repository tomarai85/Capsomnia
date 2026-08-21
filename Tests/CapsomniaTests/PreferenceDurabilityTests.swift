import XCTest
@testable import Capsomnia

/// Observed live 2026-08-21: the user picked Auto at 11:46:38, the app logged
/// `preference keep_awake_mode=auto` and acted on it, and a restart eight minutes later came
/// back up in `capsLock` — the value still on disk from the previous day. The choice never
/// left cfprefsd's memory. Same shape as 2026-08-15. From outside, that is "I set it and it
/// did not stay set", which is a large part of what the original "unstable" report meant.
///
/// The keys are written as literals here rather than through `PreferenceKey`, which stays
/// private because exposing it collides with SwiftUI's own `PreferenceKey` protocol. That is
/// a feature for this test: it pins the on-disk names a user's existing plist actually uses,
/// so renaming a constant cannot silently orphan someone's saved settings.
final class PreferenceDurabilityTests: XCTestCase {
    /// The one that actually broke. Removing `keepAwakeMode` from `userChosen` fails here.
    func testTheModeIsTreatedAsAChoiceTheUserCannotAffordToLose() {
        XCTAssertTrue(PreferenceDurability.mustSyncImmediately("KeepAwakeMode"))
        XCTAssertTrue(PreferenceDurability.mustSyncImmediately("BatteryFloorPercent"))
        XCTAssertTrue(PreferenceDurability.mustSyncImmediately("Language"))
    }

    /// The other half, and the one a future edit is most likely to get wrong: these are
    /// written from the 250ms poll. Moving either into `userChosen` makes the app force a
    /// disk write four times a second — a different defect, in the opposite direction.
    func testThePolledLatchIsNeverForcedToDisk() {
        XCTAssertFalse(PreferenceDurability.mustSyncImmediately("BatteryFloorLatched"))
        XCTAssertFalse(PreferenceDurability.mustSyncImmediately("BatteryFloorLatchedFloor"))
        XCTAssertEqual(PreferenceDurability.pollWritten.count, 2)
    }

    /// No key may sit in both lists, and every key the app persists must sit in one — an
    /// unclassified key is how the next preference gets added with nobody deciding which
    /// kind it is. Listed by hand on purpose: a reflection sweep would pass silently at
    /// exactly the moment this test is supposed to speak up.
    func testEveryStoredPreferenceIsClassifiedExactlyOnce() {
        let everyStoredKey: Set<String> = [
            "ShowMenuBarIcon", "Language", "LaunchAtLogin", "DisplaySleepOnLidClose",
            "IgnoreExternalCapsLockOffWhileLidClosed", "KeepAwakeMode", "BatteryFloorEnabled",
            "BatteryFloorPercent", "BatteryFloorLatched", "BatteryFloorLatchedFloor",
            "DidCompleteInitialSetup", "ForceWelcomeOnNextLaunch"
        ]

        XCTAssertTrue(
            PreferenceDurability.userChosen.isDisjoint(with: PreferenceDurability.pollWritten),
            "a key cannot be both a user choice and a poll-written value"
        )
        XCTAssertEqual(
            PreferenceDurability.allStoredKeys, everyStoredKey,
            "a persisted key is unclassified, misspelled, or listed twice"
        )
    }
}
