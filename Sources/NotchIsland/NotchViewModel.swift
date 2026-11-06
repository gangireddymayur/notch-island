import AppKit
import Combine
import SwiftUI

enum IslandMode: Equatable {
    case closed      // looks exactly like the hardware notch
    case music       // small wings: artwork left, equalizer right
    case charging    // short peek after plugging in
    case expanded    // hovered: full player + battery
}

@MainActor
final class NotchViewModel: ObservableObject {
    let media = NowPlayingService()
    let battery = BatteryService()

    @Published private(set) var mode: IslandMode = .closed
    @Published var isHovering = false { didSet { recompute() } }
    @Published private(set) var showChargingPeek = false

    /// Hardware notch size in points (from the screen, with a fallback).
    @Published var notchSize = CGSize(width: 185, height: 32)

    private var bag = Set<AnyCancellable>()
    private var peekTask: Task<Void, Never>?

    init() {
        media.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.recompute(); self?.objectWillChange.send() }
        }.store(in: &bag)
        battery.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &bag)
        battery.onPluggedIn = { [weak self] in self?.flashCharging() }
    }

    func start() {
        media.start()
        battery.start()
    }

    func flashCharging() {
        peekTask?.cancel()
        showChargingPeek = true
        recompute()
        if !isHovering { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.showChargingPeek = false
            self?.recompute()
        }
    }

    private func recompute() {
        let new: IslandMode
        if isHovering { new = .expanded }
        else if showChargingPeek { new = .charging }
        else if media.anyPlaying { new = .music }
        else { new = .closed }
        if new != mode { mode = new }
    }

    // MARK: Geometry

    static let earRadius: CGFloat = 8

    /// Size of the island body (without the top "ears").
    var bodySize: CGSize {
        let n = notchSize
        switch mode {
        case .closed:   return CGSize(width: n.width - 2 * Self.earRadius, height: n.height)
        case .music:    return CGSize(width: n.width + 2 * (n.height + 12), height: n.height)
        case .charging: return CGSize(width: max(n.width + 220, 420), height: n.height + 92)
        case .expanded: return CGSize(width: max(n.width + 280, 500), height: n.height + 128)
        }
    }

    /// Full shape size including the ears on both sides.
    var shapeSize: CGSize {
        CGSize(width: bodySize.width + 2 * Self.earRadius, height: bodySize.height)
    }

    var bottomRadius: CGFloat { (mode == .expanded || mode == .charging) ? 26 : 12 }
}
