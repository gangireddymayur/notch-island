import AppKit
import ApplicationServices
import Combine
import EventKit
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, music, battery, shelf, timer, calendar, notifications, hud, bluetooth, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .music: "Music"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .timer: "Timer"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .hud: "Volume & Brightness"
        case .bluetooth: "Headsets & Bluetooth"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .music: "music.note"
        case .battery: "battery.100.bolt"
        case .shelf: "tray.full.fill"
        case .timer: "timer"
        case .calendar: "calendar"
        case .notifications: "bell.badge.fill"
        case .hud: "speaker.wave.2.fill"
        case .bluetooth: "headphones"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .music: .pink
        case .battery: .green
        case .shelf, .bluetooth: .blue
        case .timer: .orange
        case .calendar, .notifications: .red
        case .hud: .indigo
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: NotchViewModel
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label {
                    Text(s.title)
                } icon: {
                    Image(systemName: s.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(s.tint.gradient))
                }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210)
        } detail: {
            SettingsDetail(section: section, model: model, settings: model.settings, calendar: model.calendar)
                .navigationTitle(section.title)
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}

private struct SettingsDetail: View {
    let section: SettingsSection
    @ObservedObject var model: NotchViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var calendar: CalendarService
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .onReceive(tick) { _ in
                axTrusted = AXIsProcessTrusted()
                loginEnabled = SMAppService.mainApp.status == .enabled
            }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general:
            Section("Startup") {
                Toggle("Open Notch Island at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
            }
            Section("Opening the island") {
                Picker("Open when", selection: $settings.expandOnClick) {
                    Text("Pointer moves onto the notch").tag(false)
                    Text("I click the notch").tag(true)
                }
                Picker("Hover delay", selection: $settings.hoverDelay) {
                    ForEach(HoverDelay.allCases) { Text($0.title).tag($0) }
                }
                .disabled(settings.expandOnClick)
                Picker("Island width", selection: $settings.islandWidth) {
                    ForEach(IslandWidth.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Feel") {
                Toggle("Haptic feedback on the trackpad", isOn: $settings.haptics)
                Toggle("Show a Settings button inside the island", isOn: $settings.showGearInIsland)
            }
            Section("Try it") { previewButtons }

        case .music:
            Section {
                Toggle("Show artwork & equalizer beside the notch while playing", isOn: $settings.showMusic)
                Toggle("Hide them while I\u{2019}m in the app that\u{2019}s playing", isOn: $settings.hideMusicInPlayingApp)
                    .disabled(!settings.showMusic)
                Picker("Equalizer color", selection: $settings.accent) {
                    ForEach(AccentChoice.allCases) { c in Text(c.title).tag(c) }
                }
            }
            Section {
                Text("Spotify and Music are controlled directly (macOS asks once). For YouTube and other sites in Chrome, Edge, Brave or Safari, turn on the browser\u{2019}s \u{201C}Allow JavaScript from Apple Events\u{201D} \u{2014} Chrome: View \u{2192} Developer; Safari: Develop menu. The island then only pauses, plays or skips the page\u{2019}s video.")
                    .font(.callout).foregroundStyle(.secondary)
                if let b = model.media.browserNeedsScripting {
                    Label("\(appName(b) ?? "Your browser") needs \u{201C}Allow JavaScript from Apple Events\u{201D} for the island\u{2019}s buttons",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Play / pause buttons")
            }
            Section("Several apps playing") {
                Toggle("Switch to an app when it starts playing", isOn: $settings.followNewPlayer)
                Toggle("Two-finger swipe on the island switches player", isOn: $settings.swipeToSwitch)
            }
            Section {
                Text("Works with Spotify, YouTube in Chrome/Safari, Apple Music, podcasts \u{2014} anything that appears in Control Center.")
                    .foregroundStyle(.secondary)
            }

        case .battery:
            Section("MacBook \u{00B7} plugging in") {
                Toggle("Charging animation", isOn: $settings.chargingCard)
                LabeledContent("Show for \(settings.chargingSeconds, specifier: "%.1f") s") {
                    Slider(value: $settings.chargingSeconds, in: 2...10, step: 0.5).frame(width: 220)
                }
                .disabled(!settings.chargingCard)
                Toggle("\u{201C}Fully charged\u{201D} card", isOn: $settings.fullChargeCard)
            }
            Section("MacBook \u{00B7} low battery") {
                Toggle("Low battery warnings", isOn: $settings.lowBatteryAlerts)
                alertPicker("First warning at", $settings.macAlert1).disabled(!settings.lowBatteryAlerts)
                alertPicker("Second warning at", $settings.macAlert2).disabled(!settings.lowBatteryAlerts)
            }
            Section("Logitech headset") {
                Toggle("Show Logitech G headset battery", isOn: $settings.logitechHeadset)
                Toggle("Charging animation when the headset is plugged in", isOn: $settings.headsetChargingCard)
                    .disabled(!settings.logitechHeadset)
                headsetStatus
                alertPicker("First warning at", $settings.headsetAlert1).disabled(!settings.logitechHeadset)
                alertPicker("Second warning at", $settings.headsetAlert2).disabled(!settings.logitechHeadset)
            }
            Section("Try it") {
                HStack {
                    Button("Charging") { model.show(.charging, for: settings.chargingSeconds) }
                    Button("Low battery") { model.show(.lowBattery(19), for: 5) }
                    Button("Fully charged") { model.show(.fullyCharged, for: 5) }
                    Button("Headset charging") {
                        model.show(.headsetCharging(model.headsets.headset ?? LogitechHeadsetService.Headset(
                            name: "Logitech G733", online: true, percent: 36, charging: true, full: false)),
                            for: settings.chargingSeconds)
                    }
                }
            }

        case .shelf:
            Section {
                Toggle("File shelf", isOn: $settings.shelfEnabled)
                Text("Drag any file up to the notch to park it there. Drag it back out, double-click to open, or right-click to AirDrop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Screenshots") {
                Toggle("Show recent screenshots on the shelf", isOn: $settings.recentScreenshots)
                    .disabled(!settings.shelfEnabled)
                Picker("How many", selection: $settings.screenshotCount) {
                    Text("6").tag(6)
                    Text("12").tag(12)
                    Text("24").tag(24)
                }
                .disabled(!settings.recentScreenshots || !settings.shelfEnabled)
                LabeledContent("Folder") {
                    Text(ScreenshotWatcher.folder().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                }
                Button("Change screenshot folder\u{2026}") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
                }
            }
            Section("Shelf contents") {
                LabeledContent("Files on shelf", value: "\(model.shelf.items.count)")
                Button("Clear shelf", role: .destructive) { model.shelf.clear() }
                    .disabled(model.shelf.items.isEmpty)
            }

        case .timer:
            Section {
                Toggle("Timer page", isOn: $settings.timerEnabled)
                Picker("Sound when done", selection: $settings.timerSound) {
                    ForEach(AppSettings.timerSounds, id: \.self) { Text($0).tag($0) }
                }
                Button("Play sound") { NSSound(named: settings.timerSound)?.play() }
            }
            Section("Quick start") {
                HStack {
                    Button("Focus 25") { model.timer.start(minutes: 25, label: "Focus") }
                    Button("Break 5") { model.timer.start(minutes: 5, label: "Short break") }
                    Button("Stop") { model.timer.reset() }.disabled(!model.timer.isActive)
                }
            }

        case .calendar:
            Section {
                Toggle("Upcoming events & meeting alerts", isOn: $settings.calendarEnabled)
                Picker("Countdown beside the notch", selection: $settings.meetingLeadMinutes) {
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                }
                .disabled(!settings.calendarEnabled)
            } footer: {
                Text("Read-only. Join buttons appear for Zoom, Google Meet, Teams and Webex links.")
            }
            if settings.calendarEnabled {
                Section("Permission") {
                    if calendar.hasAccess {
                        Label("Calendar access allowed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("Calendar access needed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Privacy Settings") { openPrivacyPane("Privacy_Calendars") }
                        }
                    }
                }
            }

        case .notifications:
            Section {
                Toggle("Show notifications in the island", isOn: $settings.notificationsEnabled)
                Toggle("Close the macOS banner when it\u{2019}s shown in the island", isOn: $settings.hideSystemBanners)
                    .disabled(!settings.notificationsEnabled)
                Picker("When to show in the island", selection: $settings.notificationPower) {
                    ForEach(NotificationPower.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.notificationsEnabled)
                LabeledContent("Show for \(settings.notificationSeconds, specifier: "%.1f") s") {
                    Slider(value: $settings.notificationSeconds, in: 3...12, step: 0.5).frame(width: 220)
                }
                .disabled(!settings.notificationsEnabled)
            } footer: {
                Text("Reads the text of macOS notification banners via Accessibility. Keep banners on in System Settings \u{2192} Notifications \u{2014} Notch Island closes each one as soon as it\u{2019}s in the island, and it stays in Notification Center. Nothing is stored or sent anywhere.")
            }
            if settings.notificationsEnabled { Section("Permission") { accessibilityRow } }
            Section("Try it") {
                Button("Preview a notification") { previewNotification() }
            }

        case .hud:
            Section {
                Toggle("Show volume level in the island", isOn: $settings.volumeHUD)
                Toggle("Replace Apple\u{2019}s volume & brightness HUD", isOn: $settings.replaceSystemHUD)
                    .disabled(!settings.volumeHUD)
            } footer: {
                Text("Replacing Apple\u{2019}s HUD needs Accessibility. Only the volume, mute and brightness keys are captured \u{2014} never anything you type. Hold \u{2325}\u{21E7} for fine steps.")
            }
            if settings.volumeHUD && settings.replaceSystemHUD { Section("Permission") { accessibilityRow } }
            Section("Try it") {
                Button("Preview volume HUD") {
                    model.show(.hud(.volume, level: SystemAudio.volume() ?? 0.5, muted: SystemAudio.isMuted()), for: 1.6)
                }
            }

        case .bluetooth:
            Section {
                Toggle("Logitech G headset battery", isOn: $settings.logitechHeadset)
                headsetStatus
            } header: {
                Text("Logitech G (LIGHTSPEED receiver)")
            } footer: {
                Text("G733, G533, G633, G933, G935, G Pro X and similar. Asks the headset for its battery level directly \u{2014} no G HUB needed. No permission needed; Notch Island only ever talks to the Logitech headset. Shows a card when the headset is switched on or off, its battery beside the Mac\u{2019}s in the island, and a warning at 20% and 10%.")
            }
            Section {
                Toggle("Announce Bluetooth devices connecting and disconnecting", isOn: $settings.bluetoothEnabled)
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Earbuds, AirPods, keyboards and mice \u{2014} with left / right / case battery when the device reports it. macOS asks for Bluetooth access the first time.")
            }
            Section("Try it") {
                Button("Preview a device") { previewBluetooth() }
            }

        case .about:
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notch Island").font(.title2.bold())
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "\u{2013}")")
                            .foregroundStyle(.secondary)
                        Text("A Dynamic Island for your MacBook\u{2019}s notch.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Privacy") {
                Label("No network access", systemImage: "wifi.slash")
                Label("No analytics or tracking", systemImage: "eye.slash")
                Label("No third-party code", systemImage: "shippingbox")
                Label("Permission-based features are off until you switch them on", systemImage: "hand.raised.fill")
            }
            Section {
                Button("Quit Notch Island", role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }

    private var previewButtons: some View {
        HStack {
            Button("Charging") { model.show(.charging, for: settings.chargingSeconds) }
            Button("Notification") { previewNotification() }
            Button("Bluetooth") { previewBluetooth() }
            Button("Timer done") { model.show(.timerDone("Focus"), for: 6) }
        }
    }

    private func alertPicker(_ title: String, _ value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(AppSettings.alertLevels, id: \.self) { Text("\($0)%").tag($0) }
            Text("Off").tag(0)
        }
    }

    @ViewBuilder
    private var headsetStatus: some View {
        if !settings.logitechHeadset {
            EmptyView()
        } else if !model.headsets.hasPermission {
            HStack {
                Label("Input Monitoring needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Open Privacy Settings") { openPrivacyPane("Privacy_ListenEvent") }
            }
        } else if let h = model.headsets.headset {
            if h.online, let p = h.percent {
                LabeledContent(h.name) {
                    Label("\(p)%\(h.charging ? " \u{00B7} Charging" : h.full ? " \u{00B7} Full" : "")",
                          systemImage: h.charging ? "battery.100.bolt" : "headphones")
                        .foregroundStyle(h.charging ? .green : (p <= 20 ? .orange : .primary))
                }
            } else {
                LabeledContent(h.name) { Text("Receiver connected \u{00B7} headset off").foregroundStyle(.secondary) }
            }
        } else {
            Text("No Logitech receiver connected").foregroundStyle(.secondary)
        }
    }

    private func previewNotification() {
        model.show(.notification(IslandNotification(appName: "Messages", title: "Notch Island",
                                                    body: "This is how notifications look in the island.",
                                                    appURL: URL(fileURLWithPath: "/System/Applications/Messages.app"))),
                   for: settings.notificationSeconds)
    }

    private func previewBluetooth() {
        model.show(.bluetooth(BluetoothEvent(name: "Earbuds", connected: true, symbol: "headphones",
                                             left: 82, right: 78, caseLevel: 40)), for: 4)
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        if axTrusted {
            Label("Accessibility allowed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else {
            HStack {
                Label("Accessibility needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Open Privacy Settings") { openPrivacyPane("Privacy_Accessibility") }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NotchIsland: login item change failed: \(error)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}
