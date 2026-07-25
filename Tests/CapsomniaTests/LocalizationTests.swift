import XCTest
@testable import Capsomnia

final class LocalizationTests: XCTestCase {
    func testPreferredLanguageSelectsSupportedLanguage() {
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "en-US"), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "ja-JP"), .japanese)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "ko-KR"), .korean)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "ko_KR"), .korean)
    }

    func testPreferredLanguageFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "fr-FR"), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "kok-IN"), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: "jav-ID"), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(for: nil), .english)
    }

    func testEveryLanguageHasSettingsStrings() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)

            XCTAssertFalse(strings.settingsTitle.isEmpty)
            XCTAssertFalse(strings.showMenuBarIcon.isEmpty)
            XCTAssertFalse(strings.displaySleepOnLidClose.isEmpty)
            XCTAssertFalse(strings.openAtLogin.isEmpty)
            XCTAssertFalse(strings.language.isEmpty)
            XCTAssertFalse(strings.done.isEmpty)
        }
    }

    /// The held state has to be sayable in every language, or the floor goes back to
    /// being a silent override for three quarters of the users.
    func testEveryLanguageExplainsTheHeldState() {
        for language in AppLanguage.allCases {
            let strings = AppStrings.localized(for: language)

            XCTAssertFalse(strings.statusHeld.isEmpty, "\(language)")
            XCTAssertFalse(strings.batteryFloorOverride.isEmpty, "\(language)")
            XCTAssertFalse(strings.batteryFloorOverrideActive.isEmpty, "\(language)")
            XCTAssertFalse(strings.tooltipKeepAwakeOn.isEmpty, "\(language)")
            XCTAssertFalse(strings.tooltipKeepAwakeOff.isEmpty, "\(language)")
            XCTAssertFalse(strings.tooltipPowerUnknown.isEmpty, "\(language)")

            // Every placeholder must be filled, in every language — a template that kept
            // a "{battery}" would ship the token to the menu bar verbatim.
            let held = TextTemplate.fill(strings.batteryFloorHeldFormat, ["battery": 10, "recover": 20])
            let tooltip = TextTemplate.fill(
                strings.tooltipHeldFormat, ["battery": 10, "floor": 15, "recover": 20]
            )
            let overriding = TextTemplate.fill(
                strings.batteryFloorOverrideDetailFormat, ["battery": 12, "critical": 10]
            )
            for filled in [held, tooltip, overriding] {
                XCTAssertFalse(filled.contains("{"), "\(language): unfilled placeholder in \(filled)")
                XCTAssertTrue(filled.contains("10"), "\(language): numbers missing from \(filled)")
            }
        }
    }

    func testTemplateFillsEveryOccurrenceAndLeavesTheRest() {
        XCTAssertEqual(TextTemplate.fill("{a} then {a} then {b}", ["a": 1, "b": 2]), "1 then 1 then 2")
        XCTAssertEqual(TextTemplate.fill("no tokens", ["a": 1]), "no tokens")
    }

    func testSimplifiedChineseStrings() {
        let strings = AppStrings.localized(for: .simplifiedChinese)

        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName, "简体中文")
        XCTAssertEqual(strings.language, "语言")
        XCTAssertEqual(strings.settingsTitle, "设置")
        XCTAssertEqual(strings.getStarted, "开始使用")
    }

    func testKoreanStrings() {
        let strings = AppStrings.localized(for: .korean)

        XCTAssertEqual(AppLanguage.korean.displayName, "한국어")
        XCTAssertEqual(strings.language, "언어")
        XCTAssertEqual(strings.settingsTitle, "설정")
        XCTAssertEqual(strings.explainerOnTitle, "Caps Lock 켜기")
        XCTAssertEqual(strings.explainerOffTitle, "Caps Lock 끄기")
    }

    func testLanguagePopUpTracksSelectedLanguage() {
        let popUp = LanguagePopUpButton(
            items: AppLanguage.allCases.map { (title: $0.displayName, value: $0.rawValue) },
            selected: AppLanguage.japanese.rawValue
        )

        XCTAssertEqual(popUp.itemTitles, ["English", "日本語", "简体中文", "한국어"])
        XCTAssertEqual(popUp.selectedValue, AppLanguage.japanese.rawValue)

        popUp.setSelected(AppLanguage.korean.rawValue)

        XCTAssertEqual(popUp.selectedValue, AppLanguage.korean.rawValue)
        XCTAssertEqual(popUp.titleOfSelectedItem, AppLanguage.korean.displayName)
    }
}
