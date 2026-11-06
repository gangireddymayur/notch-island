import AppKit
import SwiftUI

enum HoverDelay: String, CaseIterable, Identifiable {
    case instant, short, relaxed
    var id: String { rawValue }
    var seconds: Double { switch self { case .instant: 0; case .short: 0.12; case .relaxed: 0.35 } }
    var title: String { rawValue.capitalized }
}

enum IslandWidth: String, CaseIterable, Identifiable {
    case compact, regular, wide
    var id: String { rawValue }
    var extra: CGFloat { switch self { case .compact: 280; case .regular: 320; case .wide: 400 } }
    var title: String { rawValue.capitalized }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, white, green, pink, orange, purple
    var id: String { rawValue }
    var title: String { self == .system ? "System accent" : rawValue.capitalized }
    var color: Color {
        switch self {
        case .system: .accentColor
        case .white: .white
        case .green: .green
        case .pink: .pink
        case .orange: .orange
        case .purple: .purple
        }
    }
}

/// User preferences, saved in UserDefaults. Anything that needs a macOS
/// permission starts OFF and is switched on by you in Settings.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // General
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var hoverDelay: HoverDelay { didSet { save(hoverDelay.rawValue, "hoverDelay") } }
    @Published var expandOnClick: Bool { didSet { save(expandOnClick, "expandOnClick") } }
    @Published var islandWidth: IslandWidth { didSet { save(islandWidth.rawValue, "islandWidth") } }
    @Published var showGearInIsland: Bool { didSet { save(showGearInIsland, "showGearInIsland") } }

    // Music
    @Published var showMusic: Bool { didSet { save(showMusic, "showMusic") } }
    @Published var accent: AccentChoice { didSet { save(accent.rawValue, "accent") } }
    @Published var followNewPlayer: Bool { didSet { save(followNewPlayer, "followNewPlayer") } }
    @Published var swipeToSwitch: Bool { didSet { save(swipeToSwitch, "swipeToSwitch") } }

    // Battery
    @Published var chargingCard: Bool { didSet { save(chargingCard, "chargingCard") } }
    @Published var chargingSeconds: Double { didSet { save(chargingSeconds, "chargingSeconds") } }
    @Published var lowBatteryAlerts: Bool { didSet { save(lowBatteryAlerts, "lowBatteryAlerts") } }
    @Published var fullChargeCard: Bool { didSet { save(fullChargeCard, "fullChargeCard") } }

    // Shelf
    @Published var shelfEnabled: Bool { didSet { save(shelfEnabled, "shelfEnabled") } }
    @Published var recentScreenshots: Bool { didSet { save(recentScreenshots, "recentScreenshots") } } // folder access
    @Published var screenshotCount: Int { didSet { save(screenshotCount, "screenshotCount") } }

    // Timer
    @Published var timerEnabled: Bool { didSet { save(timerEnabled, "timerEnabled") } }
    @Published var timerSound: String { didSet { save(timerSound, "timerSound") } }

    // Volume & brightness
    @Published var volumeHUD: Bool { didSet { save(volumeHUD, "volumeHUD") } }
    @Published var replaceSystemHUD: Bool { didSet { save(replaceSystemHUD, "replaceSystemHUD") } }   // Accessibility

    // Notifications
    @Published var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } } // Accessibility
    @Published var notificationSeconds: Double { didSet { save(notificationSeconds, "notificationSeconds") } }

    // Calendar
    @Published var calendarEnabled: Bool { didSet { save(calendarEnabled, "calendarEnabled") } }       // Calendars
    @Published var meetingLeadMinutes: Int { didSet { save(meetingLeadMinutes, "meetingLeadMinutes") } }

    // Bluetooth & headsets
    @Published var bluetoothEnabled: Bool { didSet { save(bluetoothEnabled, "bluetoothEnabled") } }    // Bluetooth
    @Published var logitechHeadset: Bool { didSet { save(logitechHeadset, "logitechHeadset") } }        // no permission

    static let timerSounds = ["Glass", "Ping", "Hero", "Submarine", "Funk", "Purr", "Tink"]

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func n(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        func s(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }

        haptics = b("haptics", true)
        hoverDelay = HoverDelay(rawValue: s("hoverDelay", "short")) ?? .short
        expandOnClick = b("expandOnClick", false)
        islandWidth = IslandWidth(rawValue: s("islandWidth", "regular")) ?? .regular
        showGearInIsland = b("showGearInIsland", true)

        showMusic = b("showMusic", true)
        accent = AccentChoice(rawValue: s("accent", "system")) ?? .system
        followNewPlayer = b("followNewPlayer", true)
        swipeToSwitch = b("swipeToSwitch", true)

        chargingCard = b("chargingCard", true)
        chargingSeconds = n("chargingSeconds", 4.5)
        lowBatteryAlerts = b("lowBatteryAlerts", true)
        fullChargeCard = b("fullChargeCard", true)

        shelfEnabled = b("shelfEnabled", true)
        recentScreenshots = b("recentScreenshots", true)
        screenshotCount = i("screenshotCount", 12)

        timerEnabled = b("timerEnabled", true)
        timerSound = s("timerSound", "Glass")

        volumeHUD = b("volumeHUD", false)
        replaceSystemHUD = b("replaceSystemHUD", false)

        notificationsEnabled = b("notificationsEnabled", false)
        notificationSeconds = n("notificationSeconds", 5.5)

        calendarEnabled = b("calendarEnabled", false)
        meetingLeadMinutes = i("meetingLeadMinutes", 10)

        bluetoothEnabled = b("bluetoothEnabled", false)
        logitechHeadset = b("logitechHeadset", true)
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
