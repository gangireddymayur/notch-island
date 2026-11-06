import AppKit
import Combine
import SwiftUI

// MARK: - State types

enum IslandPage: String, CaseIterable, Identifiable {
    case media, calendar, shelf, timer
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .media: "music.note"
        case .calendar: "calendar"
        case .shelf: "tray.full.fill"
        case .timer: "timer"
        }
    }
    var title: String { rawValue.capitalized }
}

/// Small persistent states shown as "wings" beside the notch.
enum CompactKind: Equatable { case music, timer, meeting }

enum HUDKind: Equatable { case volume, brightness }

/// Short-lived cards that pop out of the notch, shown one at a time.
enum ActivityKind: Equatable {
    case charging
    case lowBattery(Int)
    case fullyCharged
    case notification(IslandNotification)
    case bluetooth(BluetoothEvent)
    case hud(HUDKind, level: Float, muted: Bool)
    case timerDone(String)
    case meeting(CalendarEvent)

    var isHUD: Bool { if case .hud = self { return true } else { return false } }
}

struct Activity: Equatable, Identifiable {
    var id = UUID()
    var kind: ActivityKind
    var duration: TimeInterval
}

enum IslandMode: Equatable {
    case closed
    case compact(CompactKind)
    case activity(Activity)
    case expanded
}

// MARK: - View model

@MainActor
final class NotchViewModel: ObservableObject {
    let settings = AppSettings.shared
    let media = NowPlayingService()
    let battery = BatteryService()
    let timer = TimerService()
    let shelf = ShelfStore()
    let screenshots = ScreenshotWatcher()
    let calendar = CalendarService()
    let bluetooth = BluetoothService()
    let keys = MediaKeysService()
    let notifications = NotificationsService()

    @Published private(set) var mode: IslandMode = .closed
    @Published var page: IslandPage = .media
    @Published var isHovering = false { didSet { if isHovering != oldValue { hoverChanged() } } }
    @Published var isDraggingFile = false {
        didSet {
            guard isDraggingFile != oldValue else { return }
            if isDraggingFile, settings.shelfEnabled { page = .shelf }
            recompute()
        }
    }

    /// Hardware notch size in points (from the screen, with a fallback).
    @Published var notchSize = CGSize(width: 185, height: 32)

    /// Opens the Settings window (set by the app delegate).
    var openSettings: () -> Void = {}

    @Published private(set) var activity: Activity?
    private var queue: [Activity] = []
    private var activityTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    var pages: [IslandPage] {
        IslandPage.allCases.filter {
            switch $0 {
            case .media: true
            case .calendar: settings.calendarEnabled
            case .shelf: settings.shelfEnabled
            case .timer: settings.timerEnabled
            }
        }
    }

    init() {
        // Any service change may change what the island shows.
        let sources: [AnyPublisher<Void, Never>] = [
            media.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            battery.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            timer.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            shelf.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            screenshots.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            calendar.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recompute(); self?.objectWillChange.send() }
            .store(in: &bag)

        battery.onChange = { [weak self] old, new in self?.batteryChanged(old: old, new: new) }
        timer.onFinish = { [weak self] label in
            NSSound(named: AppSettings.shared.timerSound)?.play()
            self?.show(.timerDone(label), for: 6)
        }
        calendar.onStartingSoon = { [weak self] event in self?.show(.meeting(event), for: 7) }
        bluetooth.onEvent = { [weak self] event in self?.show(.bluetooth(event), for: 4) }
        notifications.onNotification = { [weak self] n in
            self?.show(.notification(n), for: AppSettings.shared.notificationSeconds)
        }
        keys.onHUD = { [weak self] kind, level, muted in self?.show(.hud(kind, level: level, muted: muted), for: 1.6) }
    }

    func start() {
        media.start()
        battery.start()
        settings.$calendarEnabled.removeDuplicates()
            .sink { [weak self] in self?.calendar.setEnabled($0) }.store(in: &bag)
        settings.$recentScreenshots.combineLatest(settings.$shelfEnabled)
            .map { $0 && $1 }.removeDuplicates()
            .sink { [weak self] in self?.screenshots.setEnabled($0) }.store(in: &bag)
        settings.$screenshotCount.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.screenshots.rescan() } }.store(in: &bag)
        settings.$bluetoothEnabled.removeDuplicates()
            .sink { [weak self] in self?.bluetooth.setEnabled($0) }.store(in: &bag)
        settings.$notificationsEnabled.removeDuplicates()
            .sink { [weak self] in self?.notifications.setEnabled($0) }.store(in: &bag)
        settings.$volumeHUD.combineLatest(settings.$replaceSystemHUD)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] show, replace in self?.keys.configure(showHUD: show, replaceSystem: show && replace) }
            .store(in: &bag)
    }

    func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // MARK: Activities

    func show(_ kind: ActivityKind, for duration: TimeInterval) {
        if kind.isHUD {
            if isHovering || isDraggingFile { return }
            // Update a visible HUD in place so the level bar slides smoothly.
            if let a = activity, a.kind.isHUD {
                activity = Activity(id: a.id, kind: kind, duration: duration)
                recompute()
                scheduleEnd(after: duration)
                return
            }
            // HUDs jump the queue; a card being shown waits behind it.
            if let a = activity { queue.insert(a, at: 0); activity = nil }
            queue.insert(Activity(kind: kind, duration: duration), at: 0)
        } else {
            queue.append(Activity(kind: kind, duration: duration))
        }
        pump()
    }

    func dismissActivity() {
        activityTask?.cancel()
        activity = nil
        recompute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.pump() }
    }

    private func pump() {
        guard activity == nil, !isHovering, !isDraggingFile, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        activity = next
        if !next.kind.isHUD { haptic(.levelChange) }
        recompute()
        scheduleEnd(after: next.duration)
    }

    private func scheduleEnd(after duration: TimeInterval) {
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissActivity()
        }
    }

    private func hoverChanged() {
        if isHovering, activity != nil {
            // Hovering opens the full island instead of the card.
            activityTask?.cancel()
            activity = nil
        }
        recompute()
        if !isHovering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pump() }
        }
    }

    // MARK: Battery

    private func batteryChanged(old: BatteryState, new: BatteryState) {
        if new.onAC && !old.onAC, settings.chargingCard { show(.charging, for: settings.chargingSeconds) }
        if !new.onAC, settings.lowBatteryAlerts {
            for level in [20, 10] where old.percent > level && new.percent <= level {
                show(.lowBattery(new.percent), for: 6)
            }
        }
        if new.onAC, old.percent < 100, new.percent >= 100, settings.fullChargeCard {
            show(.fullyCharged, for: 5)
        }
    }

    // MARK: Mode

    private func recompute() {
        if !pages.contains(page) { page = .media }
        let new: IslandMode
        if isHovering || isDraggingFile { new = .expanded }
        else if let a = activity { new = .activity(a) }
        else if settings.timerEnabled && timer.isActive { new = .compact(.timer) }
        else if calendar.soonEvent != nil { new = .compact(.meeting) }
        else if settings.showMusic && media.anyPlaying { new = .compact(.music) }
        else { new = .closed }
        if new != mode { mode = new }
    }

    // MARK: Geometry

    static let earRadius: CGFloat = 8

    /// Size of the island body (without the top "ears").
    var bodySize: CGSize {
        let n = notchSize
        switch mode {
        case .closed:
            return CGSize(width: n.width - 2 * Self.earRadius, height: n.height)
        case .compact(.music):
            return CGSize(width: n.width + 2 * (n.height + 12), height: n.height)
        case .compact:
            return CGSize(width: n.width + 2 * 70, height: n.height)
        case .expanded:
            // Each page gets just the height it needs — no empty black space.
            let content: CGFloat = switch page {
            case .media: 120
            case .calendar: 124
            case .shelf: 132
            case .timer: 112
            }
            let extra = settings.islandWidth.extra
            return CGSize(width: max(n.width + extra, extra + 240), height: n.height + content)
        case .activity(let a):
            switch a.kind {
            case .hud: return CGSize(width: n.width + 2 * 110, height: n.height)
            case .charging: return CGSize(width: max(n.width + 220, 420), height: n.height + 92)
            case .notification: return CGSize(width: max(n.width + 260, 460), height: n.height + 84)
            default: return CGSize(width: max(n.width + 220, 420), height: n.height + 80)
            }
        }
    }

    /// Full shape size including the ears on both sides.
    var shapeSize: CGSize {
        CGSize(width: bodySize.width + 2 * Self.earRadius, height: bodySize.height)
    }

    var isDropDown: Bool { bodySize.height > notchSize.height + 1 }
    var bottomRadius: CGFloat { isDropDown ? 26 : 12 }
}
