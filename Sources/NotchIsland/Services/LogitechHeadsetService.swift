import Foundation
import IOKit.hid

/// Battery for Logitech wireless headsets on a LIGHTSPEED USB receiver
/// (G733, G533, G633, G933, G935, G Pro X …). These aren't Bluetooth, so
/// macOS never shows their battery. We ask the headset directly using
/// Logitech's HID++ 2.0 protocol, feature 0x1F20 "ADC measurement" — the same
/// method the Linux kernel driver uses. Read-only: we only ever send the
/// "what is your battery voltage?" question.
///
/// macOS puts the headset's HID++ channel on the same USB interface as its
/// media buttons, so reading it needs the Input Monitoring permission (G HUB
/// needs the same). We only ever open Logitech HID++ devices.
@MainActor
final class LogitechHeadsetService: ObservableObject {
    struct Headset: Equatable {
        var name: String
        var online: Bool
        var percent: Int?
        var charging: Bool
        var full: Bool
    }

    @Published private(set) var headset: Headset?
    @Published private(set) var hasPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

    /// Fires when the headset is switched on / off (after launch).
    var onConnectionChange: ((Headset) -> Void)?
    /// Fires once when the battery drops to 20% and again at 10%.
    var onLowBattery: ((Headset) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var featureIndex: UInt8?
    private var reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var poll: Timer?
    private var ready = false        // ignore the first reading after launch
    private var warned: Set<Int> = []
    private var permissionPoll: Timer?

    func setEnabled(_ on: Bool) {
        stop()
        permissionPoll?.invalidate(); permissionPoll = nil
        guard on else { return }

        hasPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard hasPermission else {
            // Shows macOS's Input Monitoring prompt (once); start as soon as it's allowed.
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                        t.invalidate()
                        self.setEnabled(true)
                    }
                }
            }
            return
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Logitech devices that expose the HID++ long-report collection.
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<LogitechHeadsetService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<LogitechHeadsetService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { NSLog("NotchIsland: HID open failed 0x%08x", result) }
        manager = m

        // Battery changes slowly; this also notices the headset being switched on.
        poll = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.query() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.ready = true }
    }

    func stop() {
        poll?.invalidate(); poll = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
        featureIndex = nil
        headset = nil
        ready = false
    }

    // MARK: Device lifecycle

    private func attach(_ d: IOHIDDevice) {
        device = d
        featureIndex = nil
        NSLog("NotchIsland: Logitech receiver found")
        let product = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "Logitech Headset"
        let name = product.replacingOccurrences(of: " Gaming Headset", with: "")
        headset = Headset(name: "Logitech \(name)", online: false, percent: nil, charging: false, full: false)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, reportBuffer, 64, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            let me = Unmanaged<LogitechHeadsetService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(bytes) }
        }, ctx)

        // Root feature: "which index is feature 0x1F20 on this device?"
        send([0x11, 0xFF, 0x00, 0x0A, 0x1F, 0x20])
    }

    private func detach(_ d: IOHIDDevice) {
        guard d == device else { return }
        device = nil
        featureIndex = nil
        if var h = headset, h.online {
            h.online = false
            headset = h
            if ready { onConnectionChange?(h) }
        }
        headset = nil
    }

    // MARK: HID++

    private func query() {
        guard device != nil else { return }
        if let idx = featureIndex {
            send([0x11, 0xFF, idx, 0x0A])          // ADC measurement: function 0
        } else {
            send([0x11, 0xFF, 0x00, 0x0A, 0x1F, 0x20])
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard let device else { return }
        var msg = bytes + Array(repeating: 0, count: max(0, 20 - bytes.count))
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(msg[0]), &msg, msg.count)
    }

    private func handle(_ r: [UInt8]) {
        guard r.count >= 7, r[0] == 0x11 else { return }

        // Error reply (e.g. headset switched off): 11 FF FF …
        if r[2] == 0xFF {
            if featureIndex != nil { update(online: false, voltage: 0, flags: 0) }
            return
        }
        // Reply to our feature lookup.
        if r[2] == 0x00, r[3] == 0x0A {
            if r[4] != 0 {
                featureIndex = r[4]
                query()
            }
            return
        }
        // Battery reply (function 0, our id 0x0A) or spontaneous broadcast (0x00).
        guard let idx = featureIndex, r[2] == idx, r[3] & 0xF0 == 0x00 else { return }
        let voltage = Int(r[4]) << 8 | Int(r[5])
        let flags = r[6]
        update(online: voltage > 0 && [0x01, 0x03, 0x07].contains(flags), voltage: voltage, flags: flags)
    }

    private func update(online: Bool, voltage: Int, flags: UInt8) {
        guard var h = headset else { return }
        let wasOnline = h.online
        h.online = online
        h.charging = flags == 0x03
        h.full = flags == 0x07
        h.percent = online ? Self.percent(forMillivolts: voltage) : nil
        guard h != headset else { return }
        headset = h
        NSLog("NotchIsland: %@ online=%d battery=%@ charging=%d", h.name, h.online ? 1 : 0,
              h.percent.map { "\($0)%" } ?? "-", h.charging ? 1 : 0)

        if wasOnline != online {
            if online { warned = [] }
            if ready { onConnectionChange?(h) }
        }
        if online, !h.charging, let p = h.percent {
            for level in [20, 10] where p <= level && !warned.contains(level) {
                warned.insert(level)
                if ready { onLowBattery?(h) }
            }
        }
        if h.charging { warned = [] }
    }

    /// Voltage → percent curve for these headsets (from the Linux kernel's
    /// hid-logitech-hidpp driver, which adapted it from HeadsetControl).
    private static let curve: [Int] = [
        4030, 4024, 4018, 4011, 4003, 3994, 3985, 3975, 3963, 3951,
        3937, 3922, 3907, 3893, 3880, 3868, 3857, 3846, 3837, 3828,
        3820, 3812, 3805, 3798, 3791, 3785, 3779, 3773, 3768, 3762,
        3757, 3752, 3747, 3742, 3738, 3733, 3729, 3724, 3720, 3716,
        3712, 3708, 3704, 3700, 3696, 3692, 3688, 3685, 3681, 3677,
        3674, 3670, 3667, 3663, 3660, 3657, 3653, 3650, 3646, 3643,
        3640, 3637, 3633, 3630, 3627, 3624, 3620, 3617, 3614, 3611,
        3608, 3604, 3601, 3598, 3595, 3592, 3589, 3585, 3582, 3579,
        3576, 3573, 3569, 3566, 3563, 3560, 3556, 3553, 3550, 3546,
        3543, 3539, 3536, 3532, 3529, 3525, 3499, 3466, 3433, 3399,
    ]

    static func percent(forMillivolts mv: Int) -> Int {
        guard mv > 0 else { return 0 }
        for (i, v) in curve.enumerated() where mv >= v { return curve.count - i }
        return 0
    }
}
