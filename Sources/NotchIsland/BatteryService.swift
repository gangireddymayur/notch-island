import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var percent: Int = 100
    var isCharging = false
    var onAC = false
    var hasBattery = false
    /// Minutes until full while charging; nil while macOS is still estimating.
    var minutesToFull: Int?
}

/// Watches the power source with IOKit (public API, no permissions) and
/// reports when the charger is plugged in.
@MainActor
final class BatteryService: ObservableObject {
    @Published private(set) var state = BatteryState()
    /// Called on the main actor when the power adapter is connected.
    var onPluggedIn: (() -> Void)?

    private var source: CFRunLoopSource?

    func start() {
        state = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { service.update() }
        }, context)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private func update() {
        let new = Self.read()
        let wasOnAC = state.onAC
        state = new
        if new.onAC && !wasOnAC { onPluggedIn?() }
    }

    private static func read() -> BatteryState {
        var s = BatteryState()
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return s }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            s.hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            s.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if let m = d[kIOPSTimeToFullChargeKey] as? Int, m > 0 { s.minutesToFull = m }
        }
        return s
    }
}
