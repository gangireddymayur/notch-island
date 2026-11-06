import AppKit
import Combine
import ApplicationServices
import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var calendar: CalendarService
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                Toggle("Haptic feedback", isOn: $settings.haptics)
            } header: {
                Label("General", systemImage: "gearshape")
            }

            Section {
                Toggle("Show now playing beside the notch", isOn: $settings.showMusic)
                Toggle("Timer page", isOn: $settings.timerEnabled)
                Toggle("File shelf (drag files onto the notch)", isOn: $settings.shelfEnabled)
            } header: {
                Label("Island", systemImage: "capsule.fill")
            }

            Section {
                Toggle("Charging animation when plugged in", isOn: $settings.chargingCard)
                Toggle("Low battery warnings at 20% and 10%", isOn: $settings.lowBatteryAlerts)
                Toggle("\u{201C}Fully charged\u{201D} card", isOn: $settings.fullChargeCard)
            } header: {
                Label("Battery", systemImage: "battery.100.bolt")
            }

            Section {
                Toggle("Show volume HUD in the island", isOn: $settings.volumeHUD)
                Toggle("Replace Apple\u{2019}s volume & brightness HUD", isOn: $settings.replaceSystemHUD)
                    .disabled(!settings.volumeHUD)
                if settings.replaceSystemHUD && settings.volumeHUD { permissionRow(accessibility: true) }
            } header: {
                Label("Volume & Brightness", systemImage: "speaker.wave.2.fill")
            } footer: {
                Text("Replacing Apple\u{2019}s HUD needs Accessibility. Only the volume, mute and brightness keys are captured \u{2014} never other keystrokes.")
            }

            Section {
                Toggle("Show notifications in the island", isOn: $settings.notificationsEnabled)
                if settings.notificationsEnabled { permissionRow(accessibility: true) }
            } header: {
                Label("Notifications", systemImage: "bell.badge.fill")
            } footer: {
                Text("Reads the text of macOS notification banners via Accessibility. Keep banners on in System Settings \u{2192} Notifications. Nothing is stored or sent anywhere.")
            }

            Section {
                Toggle("Upcoming events & meeting alerts", isOn: $settings.calendarEnabled)
                if settings.calendarEnabled && !calendar.hasAccess {
                    HStack {
                        Label("Calendar access not granted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { openPrivacyPane("Privacy_Calendars") }
                    }
                }
            } header: {
                Label("Calendar", systemImage: "calendar")
            }

            Section {
                Toggle("Announce Bluetooth devices connecting", isOn: $settings.bluetoothEnabled)
            } header: {
                Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
            } footer: {
                Text("Earbuds, keyboards and mice \u{2014} with battery levels when the device reports them.")
            }

            Section {
                Text("Notch Island has no network access, no analytics and no third-party code. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            } header: {
                Label("Privacy", systemImage: "lock.shield.fill")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .onReceive(tick) { _ in
            axTrusted = AXIsProcessTrusted()
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder
    private func permissionRow(accessibility: Bool) -> some View {
        HStack {
            if axTrusted {
                Label("Accessibility allowed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label("Accessibility needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") { openPrivacyPane("Privacy_Accessibility") }
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
