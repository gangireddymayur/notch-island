import Foundation
import IOKit.hid

/// Battery for Logitech wireless headsets on a LIGHTSPEED USB receiver
/// (G733, G533, G633, G933, G935, G Pro X …). These aren't Bluetooth, so
/// macOS never shows their battery. We ask the headset directly using
/// Logitech's HID++ 2.0 protocol, feature 0x1F20 "ADC measurement" — the same
/// method the Linux kernel driver uses. Read-only: we only ever send the
/// "what is your battery voltage?" question.
/// No permission needed (the receiver isn't a keyboard). We only ever open
/// Logitech HID++ devices.
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
    /// Kept for the Settings UI; the headset's HID++ channel turned out not to need Input Monitoring.
    let hasPermission = true

    /// Fires when the headset is switched on / off (after launch).
    var onConnectionChange: ((Headset) -> Void)?
    /// Fires once at each low-battery level chosen in Settings.
    var onLowBattery: ((Headset) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var featureIndex: UInt8?
    private var reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var poll: Timer?
    private var ready = false        // ignore the first reading after launch
    private var warned: Set<Int> = []
    private var badReadings = 0
    private var recent: [Int] = []
    /// The on/off state we last told you about. A card only appears once the
    /// headset has stayed in a new state for a few seconds (switching on makes
    /// the receiver reconnect and briefly report errors).
    private var announced: Bool?
    private var announceWork: DispatchWorkItem?
    private var lastName = "Logitech Headset"

    func setEnabled(_ on: Bool) {
        stop()
        guard on else { return }

        DebugLog.write("headset: service starting")
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
        DebugLog.write("headset: HID open \(String(format: "0x%08x", result))")
        manager = m

        // Battery changes slowly; this also notices the headset being switched on.
        poll = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.query() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.ready = true
            self.announced = self.headset?.online ?? false
        }
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
        announced = nil
        announceWork?.cancel(); announceWork = nil
    }

    // MARK: Device lifecycle

    private func attach(_ d: IOHIDDevice) {
        device = d
        featureIndex = nil
        DebugLog.write("headset: receiver found")
        let product = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "Logitech Headset"
        let name = product.replacingOccurrences(of: " Gaming Headset", with: "")
        lastName = "Logitech \(name)"
        headset = Headset(name: lastName, online: false, percent: nil, charging: false, full: false)

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
        headset = nil
        recent = []
        DebugLog.write("headset: receiver/headset disconnected")
        scheduleAnnounce()
    }

    private func scheduleAnnounce() {
        guard ready else { return }
        announceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let online = self.headset?.online ?? false
            guard online != self.announced else { return }
            self.announced = online
            var snap = self.headset ?? Headset(name: self.lastName, online: false, percent: nil, charging: false, full: false)
            snap.online = online
            DebugLog.write("headset: announce \(online ? "connected" : "turned off")")
            self.onConnectionChange?(snap)
        }
        announceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
        if featureIndex == nil {
            DebugLog.write("headset: <- " + r.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        guard r.count >= 7, r[0] == 0x11 else { return }

        // Error reply (e.g. headset switched off): 11 FF FF …
        if r[2] == 0xFF {
            if featureIndex != nil { badReading() }
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
        guard (3000...4500).contains(voltage), [0x01, 0x03, 0x07].contains(flags) else {
            // The receiver sometimes returns a garbled reading; only treat it as
            // "switched off" if it keeps happening.
            badReading()
            return
        }
        badReadings = 0
        // Voltage wobbles with volume / lights; average the last few readings.
        recent.append(voltage)
        if recent.count > 5 { recent.removeFirst() }
        update(online: true, voltage: recent.reduce(0, +) / recent.count, flags: flags)
    }

    private func badReading() {
        badReadings += 1
        if badReadings >= 3 { update(online: false, voltage: 0, flags: 0) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.query() } }
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
        DebugLog.write("headset: \(h.name) online=\(h.online) battery=\(h.percent.map { "\($0)%" } ?? "-") charging=\(h.charging)")

        if !online { recent = [] }
        if wasOnline != online {
            if online { warned = [] }
            if ready { scheduleAnnounce() } else { announced = online }
        }
        if online, !h.charging, let p = h.percent {
            let levels = [AppSettings.shared.headsetAlert1, AppSettings.shared.headsetAlert2].filter { $0 > 0 }
            for level in levels where p <= level && !warned.contains(level) {
                warned.insert(level)
                if ready { onLowBattery?(h) }
            }
        }
        if h.charging { warned = [] }
    }

    /// Voltage → percent for the G733 family, matched to Logitech G HUB.
    /// Based on HeadsetControl's G633/G733 calibration, plus one point measured
    /// against G HUB (3726 mV = 30%). Linear between points.
    private static let curve: [(mv: Int, pct: Int)] = [
        (4100, 100), (3950, 80), (3850, 60), (3775, 40), (3726, 30),
        (3650, 20), (3500, 10), (3300, 5), (3150, 0),
    ]

    static func percent(forMillivolts mv: Int) -> Int {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if mv >= first.mv { return 100 }
        if mv <= last.mv { return 0 }
        for (hi, lo) in zip(curve, curve.dropFirst()) where mv <= hi.mv && mv >= lo.mv {
            let t = Double(mv - lo.mv) / Double(hi.mv - lo.mv)
            return Int((Double(lo.pct) + t * Double(hi.pct - lo.pct)).rounded())
        }
        return 0
    }
}
