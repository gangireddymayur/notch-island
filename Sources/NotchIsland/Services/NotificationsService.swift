import AppKit
import ApplicationServices

struct IslandNotification: Equatable {
    var appName: String?
    var title: String
    var body: String
    var appURL: URL?
}

/// Mirrors macOS notification banners into the island.
///
/// macOS has no public API for other apps' notifications. With the
/// Accessibility permission this reads the text of the banners that macOS
/// itself puts on screen (Notification Center process only). Nothing is
/// stored or sent anywhere. Keep macOS banners switched on for this to work.
@MainActor
final class NotificationsService {
    var onNotification: ((IslandNotification) -> Void)?

    private var timer: Timer?
    private var seen: [String: Date] = [:]
    private var primed = false
    private var loggedShape = false
    private var loggedUntrusted = false

    func setEnabled(_ on: Bool) {
        timer?.invalidate(); timer = nil
        primed = false
        seen = [:]
        guard on else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer?.tolerance = 0.2
    }

    private func scan() {
        if !AXIsProcessTrusted() {
            if !loggedUntrusted { loggedUntrusted = true; DebugLog.write("notifications: waiting for Accessibility") }
            return
        }
        loggedUntrusted = false
        guard
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var banners: [AXUIElement] = []
        for window in Self.elements(app, kAXWindowsAttribute) {
            Self.collectBanners(window, depth: 0, into: &banners)
        }
        let parsed = banners.compactMap { el in Self.parse(el).map { (key: $0.key, note: $0.note, element: el) } }

        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        let fresh = parsed.filter { seen[$0.key] == nil }
        for p in parsed { seen[p.key] = now }

        // First scan after enabling: just remember what's already on screen.
        guard primed else { primed = true; return }
        // Many items at once means you opened Notification Center itself.
        guard parsed.count <= 3 else { return }
        if !fresh.isEmpty || !banners.isEmpty && !loggedShape {
            loggedShape = true
            DebugLog.write("notifications: \(banners.count) banner(s) on screen, \(fresh.count) new")
        }
        for p in fresh {
            DebugLog.write("notifications: mirrored banner from \(p.note.appName ?? "unknown app")")
            onNotification?(p.note)
            // Don't show it twice: close Apple's banner (it stays in Notification Center).
            if AppSettings.shared.hideSystemBanners { Self.close(p.element) }
        }
    }

    /// Uses the banner's own "Close" action — never "Clear", which would
    /// delete it from Notification Center.
    private static func close(_ banner: AXUIElement) {
        var names: CFArray?
        AXUIElementCopyActionNames(banner, &names)
        let actions = names as? [String] ?? []
        let isClose: (String) -> Bool = {
            $0.localizedCaseInsensitiveContains("close") && !$0.localizedCaseInsensitiveContains("clear")
        }
        if let action = actions.first(where: isClose) {
            let r = AXUIElementPerformAction(banner, action as CFString)
            DebugLog.write("notifications: closed macOS banner (\(r == .success ? "ok" : "error \(r.rawValue)"))")
            return
        }
        // Some versions put a close button inside the banner instead.
        if let button = findButton(in: banner, depth: 0, matching: isClose) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return
        }
        // Action names only (no notification content) to help troubleshoot.
        DebugLog.write("notifications: no close action; actions=\(actions.map { $0.components(separatedBy: "\n").first ?? $0 })")
    }

    private static func findButton(in el: AXUIElement, depth: Int, matching: (String) -> Bool) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in elements(el, kAXChildrenAttribute) {
            let role: String = attr(child, kAXRoleAttribute) ?? ""
            let label = [attr(child, kAXDescriptionAttribute) as String?, attr(child, kAXTitleAttribute) as String?,
                         attr(child, kAXIdentifierAttribute) as String?].compactMap { $0 }.joined(separator: " ")
            if role == kAXButtonRole as String, matching(label) { return child }
            if let found = findButton(in: child, depth: depth + 1, matching: matching) { return found }
        }
        return nil
    }

    // MARK: AX helpers

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        attr(el, name) as [AXUIElement]? ?? []
    }

    private static func collectBanners(_ el: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        guard depth < 12 else { return }
        let subrole: String = attr(el, kAXSubroleAttribute) ?? ""
        if subrole.contains("Notification") && !subrole.contains("Stack") {
            out.append(el)
            return
        }
        for child in elements(el, kAXChildrenAttribute) {
            collectBanners(child, depth: depth + 1, into: &out)
        }
    }

    private static func texts(_ el: AXUIElement, depth: Int = 0, into out: inout [String]) {
        guard depth < 8 else { return }
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole as String, let v: String = attr(el, kAXValueAttribute) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        for child in elements(el, kAXChildrenAttribute) { texts(child, depth: depth + 1, into: &out) }
    }

    private static func parse(_ banner: AXUIElement) -> (key: String, note: IslandNotification)? {
        var parts: [String] = []
        texts(banner, into: &parts)
        let desc: String = attr(banner, kAXDescriptionAttribute) ?? ""

        // The banner description usually reads "App, Title, Body".
        let descParts = desc.components(separatedBy: ", ")
        var appName: String? = descParts.count >= 2 ? descParts[0] : nil
        if parts.isEmpty { parts = Array(descParts.dropFirst(appName == nil ? 0 : 1)) }
        if let a = appName, parts.first == a, parts.count > 1 { parts.removeFirst() }
        guard let title = parts.first, !title.isEmpty else { return nil }
        let body = parts.dropFirst().joined(separator: " ")

        let url = appName.flatMap(Self.appURL(named:))
        if url == nil, appName != nil, descParts.count < 3 { appName = nil }
        let note = IslandNotification(appName: appName, title: title, body: body, appURL: url)
        return ("\(appName ?? "")|\(title)|\(body)", note)
    }

    private static func appURL(named name: String) -> URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL { return url }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: "\(dir)/\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
