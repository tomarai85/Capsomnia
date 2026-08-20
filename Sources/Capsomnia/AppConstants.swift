import AppKit
import Foundation

let appName = "Capsomnia"
let appLabel = "com.github.fuji-mak.capsomnia"
let helperPath = "/Library/PrivilegedHelperTools/capsomnia-pmset"
let displaySleepHelperMode = "display-sleep"
let logDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Capsomnia")
let logPath = logDirectoryURL
    .appendingPathComponent("capsomnia.log")
    .path
let openSettingsNotificationName = Notification.Name("\(appLabel).openSettings")
/// Shown verbatim in the exit-restore-failure alert (D6). Not localized — it is a shell
/// command, not prose.
let sleepRestoreCommand = "sudo pmset -a disablesleep 0"

/// Colors lifted straight from the landing page (docs/styles.css :root).
enum Brand {
    static func srgb(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    static let bg = srgb(0x000000)
    static let surface = srgb(0x0A0A0A)
    static let surface2 = srgb(0x111111)
    static let border = srgb(0x1F1F1F)
    static let borderStrong = srgb(0x2A2A2A)
    static let text = srgb(0xF2F4EC)
    static let textDim = srgb(0xA7AD9C)
    static let textFaint = srgb(0x6F7466)
    static let led = srgb(0xB8FF1F)
    static let ledBright = srgb(0xD8FF63)
    static let offDot = srgb(0x2C2C2C)
    static let offDotBorder = srgb(0x3A3A3A)
}

/// How Capsomnia decides whether to keep the Mac awake.
/// - off:      never override sleep (normal macOS behavior).
/// - capsLock: keep awake while Caps Lock is ON (upstream Capsomnia behavior).
/// - auto:     keep awake automatically (reachability mode) — for closing the lid and
///             remote-controlling from a phone; the battery floor still releases it near empty.
enum KeepAwakeMode: String, CaseIterable {
    case off
    case capsLock
    case auto
}

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"

    static var defaultLanguage: AppLanguage {
        defaultLanguage(for: Locale.preferredLanguages.first)
    }

    static func defaultLanguage(for preferredLanguage: String?) -> AppLanguage {
        let languageCode = preferredLanguage?
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first?
            .lowercased()

        if languageCode == "ja" {
            return .japanese
        }
        if languageCode == "zh" {
            return .simplifiedChinese
        }
        if languageCode == "ko" {
            return .korean
        }
        return .english
    }

    var displayName: String {
        switch self {
        case .english:
            "English"
        case .japanese:
            "日本語"
        case .simplifiedChinese:
            "简体中文"
        case .korean:
            "한국어"
        }
    }
}

/// Fills `{token}` placeholders in a localized template. Templates beat `String(format:)`
/// here because two of these strings carry two numbers, and the order they read in
/// differs by language — positional `%d` would silently swap them.
enum TextTemplate {
    static func fill(_ template: String, _ values: [String: Int]) -> String {
        values.reduce(template) { partial, pair in
            partial.replacingOccurrences(of: "{\(pair.key)}", with: "\(pair.value)")
        }
    }
}

struct AppStrings {
    let showMenuBarIcon: String
    let showMenuBarIconDesc: String
    let language: String
    let openAtLogin: String
    let openAtLoginDesc: String
    let displaySleepOnLidClose: String
    let displaySleepOnLidCloseDesc: String
    let ignoreExternalCapsLockOffWhileLidClosed: String
    let ignoreExternalCapsLockOffWhileLidClosedDesc: String
    let openCapsomnia: String
    let quit: String
    let settingsTitle: String
    let initialSettingsNote: String
    let welcomeTitle: String
    let explainerOnTitle: String
    let explainerOnDesc: String
    let explainerOffTitle: String
    let explainerOffDesc: String
    let preferencesHeading: String
    let done: String
    let getStarted: String
    let tooltipOn: String
    let tooltipOff: String
    let tooltipError: String
    let keepAwakeHeading: String
    let modeOff: String
    let modeCapsLock: String
    let modeAuto: String
    let batteryFloorMenu: String
    let keepAwakeModeDesc: String
    let batteryFloorDesc: String
    /// Mode-neutral wording for Off / Auto, where "Caps Lock" is not what is deciding.
    let tooltipKeepAwakeOn: String
    let tooltipKeepAwakeOff: String
    /// The held state: the mode wants the Mac awake, the battery floor is releasing it.
    /// Awake, but the power source could not be read, so the floor is not being
    /// enforced. Every other status reaches a surface; without this one it existed only
    /// in the log.
    let tooltipPowerUnknown: String
    let statusHeld: String
    let batteryFloorHeldFormat: String
    let tooltipHeldFormat: String
    let batteryFloorOverride: String
    let batteryFloorOverrideActive: String
    /// Menu header: short, the chip beside the floor row already says "overriding".
    let batteryFloorOverrideSubtitleFormat: String
    /// Tooltip: no chip beside it, so it has to name what it is on its own.
    let batteryFloorOverrideDetailFormat: String
    /// D6: shown in a plain `NSAlert` (not the glass popover) when the explicit Quit
    /// path's restore-at-exit fails.
    let exitRestoreFailedTitle: String
    let exitRestoreFailedMessage: String
    let copyCommand: String
    let tryAgain: String
    let quitAnyway: String

    static func current() -> AppStrings {
        localized(for: Preferences.language)
    }

    static func localized(for language: AppLanguage) -> AppStrings {
        switch language {
        case .english:
            AppStrings(
                showMenuBarIcon: "Show menu bar icon",
                showMenuBarIconDesc: "Display the LED status dot in the menu bar.",
                language: "Language",
                openAtLogin: "Open at login",
                openAtLoginDesc: "Launch Capsomnia automatically after you sign in.",
                displaySleepOnLidClose: "Turn display off when lid closes",
                displaySleepOnLidCloseDesc: "When Caps Lock is on, let the display sleep after closing the lid only if no external display is connected.",
                ignoreExternalCapsLockOffWhileLidClosed: "Ignore Caps Lock turn-offs while the lid is closed",
                ignoreExternalCapsLockOffWhileLidClosedDesc: "While the lid is closed, sleep prevention stays on even if Caps Lock is turned off — for example by a remote desktop client syncing its keyboard state. Opening the lid or switching the mode from the menu turns it off as usual.",
                openCapsomnia: "Open Capsomnia",
                quit: "Quit",
                settingsTitle: "Settings",
                initialSettingsNote: "macOS may show “Taketo Fujimaki” as a background item. Open Capsomnia again any time to change these settings.",
                welcomeTitle: "Welcome to Capsomnia",
                explainerOnTitle: "Caps Lock on",
                explainerOnDesc: "System sleep is disabled — work keeps running, lid open or closed.",
                explainerOffTitle: "Caps Lock off",
                explainerOffDesc: "Normal sleep behavior resumes.",
                preferencesHeading: "Preferences",
                done: "Done",
                getStarted: "Get started",
                tooltipOn: "Caps Lock ON: processes stay awake",
                tooltipOff: "Caps Lock OFF: normal sleep",
                tooltipError: "Capsomnia could not update the sleep setting — retrying",
                keepAwakeHeading: "Keep awake",
                modeOff: "Off",
                modeCapsLock: "Caps Lock",
                modeAuto: "Auto (always)",
                batteryFloorMenu: "Battery floor",
                keepAwakeModeDesc: "Off = normal sleep. Caps Lock = awake while Caps Lock is on. Auto = always keep awake (for closing the lid and working remotely).",
                batteryFloorDesc: "On battery, allow sleep at or below this level, so there is charge left in reserve instead of running the battery flat.",
                tooltipKeepAwakeOn: "Keep awake ON: processes stay awake",
                tooltipKeepAwakeOff: "Keep awake OFF: normal sleep",
                tooltipPowerUnknown: "Keep awake ON — the power source cannot be read, so the battery floor is not being applied",
                statusHeld: "PAUSED",
                batteryFloorHeldFormat: "Battery {battery}% · resumes {recover}%",
                tooltipHeldFormat: "Paused by the battery floor: {battery}% is at or below {floor}%. Resumes at {recover}% or on AC.",
                batteryFloorOverride: "Stay awake",
                batteryFloorOverrideActive: "Overriding",
                batteryFloorOverrideSubtitleFormat: "{battery}% · sleeps at {critical}%",
                batteryFloorOverrideDetailFormat: "Floor overridden · {battery}%, sleeps at {critical}%",
                exitRestoreFailedTitle: "Couldn't restore sleep",
                exitRestoreFailedMessage: "System sleep is still disabled. Run this command to fix it:",
                copyCommand: "Copy Command",
                tryAgain: "Try Again",
                quitAnyway: "Quit Anyway"
            )
        case .korean:
            AppStrings(
                showMenuBarIcon: "메뉴 막대에 표시",
                showMenuBarIconDesc: "메뉴 막대에 LED 상태 표시를 보여 줍니다.",
                language: "언어",
                openAtLogin: "로그인할 때 열기",
                openAtLoginDesc: "로그인하면 Capsomnia를 자동으로 실행합니다.",
                displaySleepOnLidClose: "덮개를 닫을 때 화면 끄기",
                displaySleepOnLidCloseDesc: "Caps Lock이 켜져 있으면 외부 디스플레이가 연결되지 않은 경우에만 덮개를 닫을 때 화면을 끕니다.",
                ignoreExternalCapsLockOffWhileLidClosed: "덮개를 닫은 동안 Caps Lock에 의한 끄기 무시",
                ignoreExternalCapsLockOffWhileLidClosedDesc: "덮개가 닫혀 있는 동안에는 Caps Lock이 꺼져도 잠자기 방지를 유지합니다. 원격 데스크톱 연결 등으로 의도치 않게 해제되는 것을 방지합니다. 덮개를 열거나 메뉴에서 모드를 바꾸면 평소대로 꺼집니다.",
                openCapsomnia: "Capsomnia 열기",
                quit: "종료",
                settingsTitle: "설정",
                initialSettingsNote: "macOS에 ‘Taketo Fujimaki’ 백그라운드 항목이 표시될 수 있습니다. 이 설정은 나중에 언제든 바꿀 수 있습니다.",
                welcomeTitle: "Capsomnia 시작하기",
                explainerOnTitle: "Caps Lock 켜기",
                explainerOnDesc: "시스템 잠자기를 막습니다. 덮개를 닫아도 작업은 계속됩니다.",
                explainerOffTitle: "Caps Lock 끄기",
                explainerOffDesc: "평소 잠자기 동작으로 돌아갑니다.",
                preferencesHeading: "기본 설정",
                done: "완료",
                getStarted: "시작하기",
                tooltipOn: "Caps Lock 켜짐: 잠자기 방지 중",
                tooltipOff: "Caps Lock 꺼짐: 평소 잠자기",
                tooltipError: "잠자기 설정을 바꾸지 못했습니다. 다시 시도 중입니다.",
                keepAwakeHeading: "잠자기 방지",
                modeOff: "끄기",
                modeCapsLock: "Caps Lock",
                modeAuto: "자동 (항상)",
                batteryFloorMenu: "배터리 하한",
                keepAwakeModeDesc: "끄기 = 평소 잠자기. Caps Lock = Caps Lock이 켜져 있는 동안 깨어 있음. 자동 = 항상 깨어 있음(덮개를 닫고 원격 작업할 때).",
                batteryFloorDesc: "배터리 사용 중에는 이 수준 이하에서 잠자기를 허용해 잔량을 남겨 둡니다.",
                tooltipKeepAwakeOn: "잠자기 방지 켜짐: 작업이 계속 실행됩니다",
                tooltipKeepAwakeOff: "잠자기 방지 꺼짐: 평소 잠자기",
                tooltipPowerUnknown: "잠자기 방지 켜짐 — 전원 상태를 읽을 수 없어 배터리 하한이 적용되지 않습니다",
                statusHeld: "일시 중지",
                batteryFloorHeldFormat: "{battery}% · {recover}%에서 재개",
                tooltipHeldFormat: "배터리 하한으로 중지됨: {battery}%가 {floor}% 이하입니다. {recover}% 또는 전원 연결 시 재개합니다.",
                batteryFloorOverride: "그래도 유지",
                batteryFloorOverrideActive: "무시 중",
                batteryFloorOverrideSubtitleFormat: "{battery}% · {critical}%에서 잠자기",
                batteryFloorOverrideDetailFormat: "하한 무시 중 · {battery}%, {critical}%에서 잠자기",
                exitRestoreFailedTitle: "절전 모드를 되돌리지 못했습니다",
                exitRestoreFailedMessage: "시스템 절전이 아직 비활성화되어 있습니다. 아래 명령을 실행하세요:",
                copyCommand: "명령 복사",
                tryAgain: "다시 시도",
                quitAnyway: "그래도 종료"
            )
        case .japanese:
            AppStrings(
                showMenuBarIcon: "メニューバーに表示",
                showMenuBarIconDesc: "メニューバーにLEDステータスを表示します。",
                language: "言語",
                openAtLogin: "ログイン時に起動",
                openAtLoginDesc: "サインイン後にCapsomniaを自動で起動します。",
                displaySleepOnLidClose: "蓋を閉じたら画面をオフ",
                displaySleepOnLidCloseDesc: "Caps Lock ON中は、外部ディスプレイが接続されていない場合のみ、蓋を閉じたら画面を暗くします。",
                ignoreExternalCapsLockOffWhileLidClosed: "蓋を閉じている間はCaps Lockによるオフを無視",
                ignoreExternalCapsLockOffWhileLidClosedDesc: "蓋を閉じている間は、Caps Lockがオフになってもスリープ抑止を維持します。リモートデスクトップ接続などで意図せず解除されるのを防ぎます。蓋を開けるか、メニューでモードを切り替えれば通常どおりオフにできます。",
                openCapsomnia: "Capsomniaを開く",
                quit: "終了",
                settingsTitle: "設定",
                initialSettingsNote: "macOSに「Taketo Fujimakiのバックグラウンド項目」と表示される場合があります。設定はあとからいつでも変更できます。",
                welcomeTitle: "Capsomniaへようこそ",
                explainerOnTitle: "Caps Lock ON",
                explainerOnDesc: "システムスリープを無効化。蓋を閉じても作業が走り続けます。",
                explainerOffTitle: "Caps Lock OFF",
                explainerOffDesc: "通常のスリープ動作に戻ります。",
                preferencesHeading: "環境設定",
                done: "完了",
                getStarted: "はじめる",
                tooltipOn: "Caps Lock ON: スリープ抑止中",
                tooltipOff: "Caps Lock OFF: 通常のスリープ動作",
                tooltipError: "スリープ設定を更新できませんでした — 再試行中",
                keepAwakeHeading: "スリープ防止",
                modeOff: "オフ",
                modeCapsLock: "Caps Lock",
                modeAuto: "自動(常時)",
                batteryFloorMenu: "バッテリー下限",
                keepAwakeModeDesc: "オフ=通常のスリープ / Caps Lock=Caps Lock ON中だけ起きる / 自動=常時起こす(蓋を閉じてリモート作業する用)。",
                batteryFloorDesc: "バッテリー駆動時、この残量以下でスリープを許可。使い切る前に余力を残します。",
                tooltipKeepAwakeOn: "スリープ抑止中: 処理は動き続けます",
                tooltipKeepAwakeOff: "スリープ抑止オフ: 通常のスリープ動作",
                tooltipPowerUnknown: "スリープ抑止中 — 電源状態が読めないため、バッテリー下限は適用されていません",
                statusHeld: "一時停止",
                batteryFloorHeldFormat: "残量{battery}% · {recover}%で再開",
                tooltipHeldFormat: "バッテリー下限で一時停止中: {battery}%は{floor}%以下です。{recover}%か電源接続で再開します。",
                batteryFloorOverride: "無視して起こす",
                batteryFloorOverrideActive: "無視中",
                batteryFloorOverrideSubtitleFormat: "残量{battery}% · {critical}%でスリープ",
                batteryFloorOverrideDetailFormat: "下限を無視中 · {battery}%、{critical}%でスリープ",
                exitRestoreFailedTitle: "スリープを戻せませんでした",
                exitRestoreFailedMessage: "システムスリープがまだ無効です。次のコマンドを実行してください:",
                copyCommand: "コマンドをコピー",
                tryAgain: "もう一度試す",
                quitAnyway: "このまま終了"
            )
        case .simplifiedChinese:
            AppStrings(
                showMenuBarIcon: "显示菜单栏图标",
                showMenuBarIconDesc: "在菜单栏中显示 LED 状态指示灯。",
                language: "语言",
                openAtLogin: "登录时启动",
                openAtLoginDesc: "登录后自动启动 Capsomnia。",
                displaySleepOnLidClose: "合盖时关闭显示屏",
                displaySleepOnLidCloseDesc: "Caps Lock 开启时，仅在未连接外接显示器的情况下，合盖后让显示屏进入睡眠。",
                ignoreExternalCapsLockOffWhileLidClosed: "合盖期间忽略 Caps Lock 的关闭操作",
                ignoreExternalCapsLockOffWhileLidClosedDesc: "合盖期间，即使 Caps Lock 被关闭也会保持防睡眠，防止远程桌面连接等意外解除防睡眠。打开盖子或在菜单中切换模式即可正常关闭。",
                openCapsomnia: "打开 Capsomnia",
                quit: "退出",
                settingsTitle: "设置",
                initialSettingsNote: "macOS 可能会将“Taketo Fujimaki”显示为后台项目。你可以随时重新打开 Capsomnia 更改这些设置。",
                welcomeTitle: "欢迎使用 Capsomnia",
                explainerOnTitle: "Caps Lock 已开启",
                explainerOnDesc: "系统睡眠已停用——无论开盖还是合盖，任务都会继续运行。",
                explainerOffTitle: "Caps Lock 已关闭",
                explainerOffDesc: "已恢复正常睡眠。",
                preferencesHeading: "偏好设置",
                done: "完成",
                getStarted: "开始使用",
                tooltipOn: "Caps Lock 已开启：任务将保持运行",
                tooltipOff: "Caps Lock 已关闭：正常睡眠",
                tooltipError: "Capsomnia 无法更新睡眠设置——正在重试",
                keepAwakeHeading: "防止睡眠",
                modeOff: "关闭",
                modeCapsLock: "Caps Lock",
                modeAuto: "自动（始终）",
                batteryFloorMenu: "电量下限",
                keepAwakeModeDesc: "关闭 = 正常睡眠。Caps Lock = 开启 Caps Lock 时保持唤醒。自动 = 始终保持唤醒（合盖远程工作时）。",
                batteryFloorDesc: "使用电池时，在此电量或以下允许睡眠，为电池保留余量。",
                tooltipKeepAwakeOn: "防止睡眠已开启：任务将保持运行",
                tooltipKeepAwakeOff: "防止睡眠已关闭：正常睡眠",
                tooltipPowerUnknown: "防止睡眠已开启 — 无法读取电源状态，电量下限未生效",
                statusHeld: "已暂停",
                batteryFloorHeldFormat: "电量 {battery}% · {recover}% 恢复",
                tooltipHeldFormat: "已被电量下限暂停：{battery}% 低于或等于 {floor}%。达到 {recover}% 或接通电源后恢复。",
                batteryFloorOverride: "保持唤醒",
                batteryFloorOverrideActive: "忽略中",
                batteryFloorOverrideSubtitleFormat: "电量 {battery}% · {critical}% 时睡眠",
                batteryFloorOverrideDetailFormat: "正在忽略下限 · {battery}%，{critical}% 时睡眠",
                exitRestoreFailedTitle: "未能恢复睡眠",
                exitRestoreFailedMessage: "系统睡眠仍处于禁用状态。请运行以下命令：",
                copyCommand: "复制命令",
                tryAgain: "重试",
                quitAnyway: "仍然退出"
            )
        }
    }
}

private enum PreferenceKey {
    static let showMenuBarIcon = "ShowMenuBarIcon"
    static let language = "Language"
    static let launchAtLogin = "LaunchAtLogin"
    static let displaySleepOnLidClose = "DisplaySleepOnLidClose"
    static let ignoreExternalCapsLockOffWhileLidClosed = "IgnoreExternalCapsLockOffWhileLidClosed"
    static let keepAwakeMode = "KeepAwakeMode"
    static let batteryFloorEnabled = "BatteryFloorEnabled"
    static let batteryFloorPercent = "BatteryFloorPercent"
    static let batteryFloorLatched = "BatteryFloorLatched"
    static let batteryFloorLatchedFloor = "BatteryFloorLatchedFloor"
    static let didCompleteInitialSetup = "DidCompleteInitialSetup"
    static let forceWelcomeOnNextLaunch = "ForceWelcomeOnNextLaunch"
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            PreferenceKey.showMenuBarIcon: true,
            PreferenceKey.language: AppLanguage.defaultLanguage.rawValue,
            PreferenceKey.launchAtLogin: true,
            PreferenceKey.displaySleepOnLidClose: true,
            PreferenceKey.ignoreExternalCapsLockOffWhileLidClosed: false,
            PreferenceKey.keepAwakeMode: KeepAwakeMode.capsLock.rawValue,
            PreferenceKey.batteryFloorEnabled: true,
            PreferenceKey.batteryFloorPercent: 15,
            PreferenceKey.batteryFloorLatched: false,
            PreferenceKey.batteryFloorLatchedFloor: 0,
            PreferenceKey.didCompleteInitialSetup: false,
            PreferenceKey.forceWelcomeOnNextLaunch: false
        ])
    }

    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: PreferenceKey.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: PreferenceKey.showMenuBarIcon) }
    }

    static var language: AppLanguage {
        get {
            AppLanguage(rawValue: defaults.string(forKey: PreferenceKey.language) ?? "")
                ?? AppLanguage.defaultLanguage
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.language) }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: PreferenceKey.launchAtLogin) }
        set { defaults.set(newValue, forKey: PreferenceKey.launchAtLogin) }
    }

    static var displaySleepOnLidClose: Bool {
        get { defaults.bool(forKey: PreferenceKey.displaySleepOnLidClose) }
        set { defaults.set(newValue, forKey: PreferenceKey.displaySleepOnLidClose) }
    }

    /// While the lid is closed the built-in keyboard cannot be pressed, so a Caps Lock
    /// turn-off observed then comes from an external source (a remote desktop client
    /// syncing keyboard state). When enabled, such turn-offs do not release sleep
    /// prevention. Ported from upstream v3.1.0 — see ClosedLidCapsLockGuard.
    static var ignoreExternalCapsLockOffWhileLidClosed: Bool {
        get { defaults.bool(forKey: PreferenceKey.ignoreExternalCapsLockOffWhileLidClosed) }
        set { defaults.set(newValue, forKey: PreferenceKey.ignoreExternalCapsLockOffWhileLidClosed) }
    }

    static var keepAwakeMode: KeepAwakeMode {
        get {
            KeepAwakeMode(rawValue: defaults.string(forKey: PreferenceKey.keepAwakeMode) ?? "")
                ?? .capsLock
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.keepAwakeMode) }
    }

    static var batteryFloorEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKey.batteryFloorEnabled) }
        set { defaults.set(newValue, forKey: PreferenceKey.batteryFloorEnabled) }
    }

    /// Battery percentage at or below which keep-awake is released (0 = fall back to 15).
    static var batteryFloorPercent: Int {
        get {
            let value = defaults.integer(forKey: PreferenceKey.batteryFloorPercent)
            return (value >= 5 && value <= 90) ? value : 15
        }
        set { defaults.set(newValue, forKey: PreferenceKey.batteryFloorPercent) }
    }

    /// The hysteresis latch, persisted. Kept out of memory-only state on purpose: a
    /// relaunch used to clear it, so the same charge could yield "released" or "awake"
    /// depending on whether the app had restarted. Attaching AC always clears it, so a
    /// stale latch cannot outlive the discharge that set it.
    static var batteryFloorLatched: Bool {
        get { defaults.bool(forKey: PreferenceKey.batteryFloorLatched) }
        set { defaults.set(newValue, forKey: PreferenceKey.batteryFloorLatched) }
    }

    /// The floor the stored latch was decided against. A latch taken under a different
    /// threshold describes a policy that no longer exists, so it is discarded rather than
    /// applied to the new one — the same reason editing the floor resets it in-session.
    static var batteryFloorLatchedFloor: Int {
        get { defaults.integer(forKey: PreferenceKey.batteryFloorLatchedFloor) }
        set { defaults.set(newValue, forKey: PreferenceKey.batteryFloorLatchedFloor) }
    }

    static var didCompleteInitialSetup: Bool {
        get { defaults.bool(forKey: PreferenceKey.didCompleteInitialSetup) }
        set { defaults.set(newValue, forKey: PreferenceKey.didCompleteInitialSetup) }
    }

    static func consumeForceWelcomeOnNextLaunch() -> Bool {
        let shouldShowWelcome = defaults.bool(forKey: PreferenceKey.forceWelcomeOnNextLaunch)
        if shouldShowWelcome {
            defaults.set(false, forKey: PreferenceKey.forceWelcomeOnNextLaunch)
        }
        return shouldShowWelcome
    }

}
