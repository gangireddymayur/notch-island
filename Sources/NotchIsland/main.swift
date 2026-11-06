import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchViewModel()
    private var controller: NotchWindowController?
    private var statusItem: NSStatusItem?

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
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = MenuRefresher.shared
        MenuRefresher.shared.loginItem = { [weak self] in self?.loginMenuItem }

        let title = NSMenuItem(title: "Notch Island", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let preview = NSMenuItem(title: "Preview Charging Animation", action: #selector(previewCharging), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private lazy var loginMenuItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    @objc private func previewCharging() { model.flashCharging() }

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

/// Keeps the "Open at Login" checkmark in sync each time the menu opens.
@MainActor
final class MenuRefresher: NSObject, NSMenuDelegate {
    static let shared = MenuRefresher()
    var loginItem: (() -> NSMenuItem?)?

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?()?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
