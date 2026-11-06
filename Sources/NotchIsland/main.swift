import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = NotchViewModel()
    private var controller: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchWindowController(model: model)
        controller?.start()
        model.start()
        setUpMenuBarIcon()
        enableLaunchAtLoginOnFirstRun()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.media.stop()
    }

    // MARK: Menu bar icon

    private func setUpMenuBarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        item.button?.image?.size = NSSize(width: 18, height: 10)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Notch Island", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))

        let preview = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(item("Charging", #selector(previewCharging)))
        sub.addItem(item("Low Battery", #selector(previewLowBattery)))
        sub.addItem(item("Fully Charged", #selector(previewFull)))
        sub.addItem(item("Notification", #selector(previewNotification)))
        sub.addItem(item("Bluetooth Device", #selector(previewBluetooth)))
        sub.addItem(item("Volume HUD", #selector(previewVolume)))
        sub.addItem(item("Timer Finished", #selector(previewTimer)))
        preview.submenu = sub
        menu.addItem(preview)

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: model.settings, calendar: model.calendar))
            let w = NSWindow(contentViewController: host)
            w.title = "Notch Island Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Previews (handy for trying each card)

    @objc private func previewCharging() { model.show(.charging, for: 4.5) }
    @objc private func previewLowBattery() { model.show(.lowBattery(19), for: 5) }
    @objc private func previewFull() { model.show(.fullyCharged, for: 5) }
    @objc private func previewNotification() {
        model.show(.notification(IslandNotification(appName: "Messages", title: "Notch Island",
                                                    body: "This is how notifications look in the island.",
                                                    appURL: URL(fileURLWithPath: "/System/Applications/Messages.app"))), for: 5.5)
    }
    @objc private func previewBluetooth() {
        model.show(.bluetooth(BluetoothEvent(name: "Earbuds", connected: true, symbol: "headphones",
                                             left: 82, right: 78, caseLevel: 40)), for: 4)
    }
    @objc private func previewVolume() {
        model.show(.hud(.volume, level: SystemAudio.volume() ?? 0.5, muted: SystemAudio.isMuted()), for: 1.6)
    }
    @objc private func previewTimer() { model.show(.timerDone("Focus"), for: 6) }

    // MARK: Launch at login

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("NotchIsland: login item change failed: \(error)")
        }
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didAskLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
