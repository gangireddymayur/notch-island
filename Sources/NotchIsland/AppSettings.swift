import Foundation

/// User preferences, saved in UserDefaults. Anything that needs a macOS
/// permission starts OFF and is switched on by you in Settings.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // No permission needed
    @Published var showMusic: Bool { didSet { save(showMusic, "showMusic") } }
    @Published var chargingCard: Bool { didSet { save(chargingCard, "chargingCard") } }
    @Published var lowBatteryAlerts: Bool { didSet { save(lowBatteryAlerts, "lowBatteryAlerts") } }
    @Published var fullChargeCard: Bool { didSet { save(fullChargeCard, "fullChargeCard") } }
    @Published var timerEnabled: Bool { didSet { save(timerEnabled, "timerEnabled") } }
    @Published var shelfEnabled: Bool { didSet { save(shelfEnabled, "shelfEnabled") } }
    @Published var recentScreenshots: Bool { didSet { save(recentScreenshots, "recentScreenshots") } } // Desktop folder access
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var volumeHUD: Bool { didSet { save(volumeHUD, "volumeHUD") } }

    // Need a permission
    @Published var replaceSystemHUD: Bool { didSet { save(replaceSystemHUD, "replaceSystemHUD") } }   // Accessibility
    @Published var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notificationsEnabled") } } // Accessibility
    @Published var calendarEnabled: Bool { didSet { save(calendarEnabled, "calendarEnabled") } }       // Calendars
    @Published var bluetoothEnabled: Bool { didSet { save(bluetoothEnabled, "bluetoothEnabled") } }    // Bluetooth

    private init() {
        let d = UserDefaults.standard
        func b(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
        showMusic = b("showMusic", true)
        chargingCard = b("chargingCard", true)
        lowBatteryAlerts = b("lowBatteryAlerts", true)
        fullChargeCard = b("fullChargeCard", true)
        timerEnabled = b("timerEnabled", true)
        shelfEnabled = b("shelfEnabled", true)
        recentScreenshots = b("recentScreenshots", true)
        haptics = b("haptics", true)
        volumeHUD = b("volumeHUD", false)
        replaceSystemHUD = b("replaceSystemHUD", false)
        notificationsEnabled = b("notificationsEnabled", false)
        calendarEnabled = b("calendarEnabled", false)
        bluetoothEnabled = b("bluetoothEnabled", false)
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
