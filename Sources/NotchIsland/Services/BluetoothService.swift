import Foundation
import IOBluetooth

struct BluetoothEvent: Equatable {
    var name: String
    var connected: Bool
    var symbol: String
    /// Battery levels 0–100 when the device reports them.
    var single: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
}

/// Announces Bluetooth devices (earbuds, keyboards, mice…) connecting and
/// disconnecting. Asks for Bluetooth access the first time it's switched on.
@MainActor
final class BluetoothService: NSObject {
    var onEvent: ((BluetoothEvent) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var startedAt = Date()

    func setEnabled(_ on: Bool) {
        connectNote?.unregister(); connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes = [:]
        guard on else { return }
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        disconnectNotes[address]?.unregister()
        disconnectNotes[address] = device.register(forDisconnectNotification: self,
                                                   selector: #selector(deviceDisconnected(_:device:)))
        // macOS reports already-connected devices right after registering; skip those.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        // Earbuds report battery a moment after connecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onEvent?(Self.describe(device, connected: true))
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString {
            disconnectNotes[address]?.unregister()
            disconnectNotes[address] = nil
        }
        onEvent?(Self.describe(device, connected: false))
    }

    private static func describe(_ device: IOBluetoothDevice, connected: Bool) -> BluetoothEvent {
        let name = device.name ?? "Bluetooth device"
        var e = BluetoothEvent(name: name, connected: connected, symbol: symbol(for: device, name: name))
        if connected {
            e.single = level(device, "batteryPercentSingle")
            e.left = level(device, "batteryPercentLeft")
            e.right = level(device, "batteryPercentRight")
            e.caseLevel = level(device, "batteryPercentCase")
        }
        return e
    }

    /// Battery values are undocumented properties; only read them if present.
    private static func level(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let n = device.value(forKey: key) as? NSNumber else { return nil }
        let v = n.intValue
        return (1...100).contains(v) ? v : nil
    }

    private static func symbol(for device: IOBluetoothDevice, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        switch device.deviceClassMajor {
        case 0x04: // audio/video
            return [0x06, 0x01, 0x02].contains(device.deviceClassMinor) && !lower.contains("speaker")
                ? "headphones" : "hifispeaker.fill"
        case 0x05: // peripheral
            if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
            if lower.contains("mouse") { return "magicmouse.fill" }
            return "keyboard.fill"
        case 0x02: return "iphone"
        case 0x07: return "applewatch"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
