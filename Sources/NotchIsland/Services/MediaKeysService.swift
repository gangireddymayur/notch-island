import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// Volume & brightness HUD.
///
/// - "Show island HUD" (no permission): listens for volume changes with
///   CoreAudio and shows the island HUD next to Apple's.
/// - "Replace system HUD" (Accessibility): catches ONLY the volume, mute and
///   brightness keys (no other keystrokes are delivered to this tap), changes
///   the level itself and swallows the key so Apple's HUD doesn't appear.
@MainActor
final class MediaKeysService {
    var onHUD: ((HUDKind, Float, Bool) -> Void)?

    private var showHUD = false
    private var replaceSystem = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustPoll: Timer?
    private var audioDevice: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var lastKeyChange = Date.distantPast

    func configure(showHUD: Bool, replaceSystem: Bool) {
        self.showHUD = showHUD
        self.replaceSystem = replaceSystem
        if showHUD { startAudioListening() } else { stopAudioListening() }
        if replaceSystem { enableTap() } else { disableTap() }
    }

    // MARK: Volume change listening (no permission)

    private func startAudioListening() {
        guard defaultDeviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        defaultDeviceListener = block
        var addr = SystemAudio.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        attachToDefaultDevice()
    }

    private func stopAudioListening() {
        detachFromDevice()
        if let block = defaultDeviceListener {
            var addr = SystemAudio.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
        defaultDeviceListener = nil
    }

    private func attachToDefaultDevice() {
        detachFromDevice()
        guard let device = SystemAudio.defaultOutputDevice() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volumeChangedExternally() }
        }
        var vol = SystemAudio.volumeAddress, mute = SystemAudio.muteAddress
        AudioObjectAddPropertyListenerBlock(device, &vol, .main, block)
        AudioObjectAddPropertyListenerBlock(device, &mute, .main, block)
        audioDevice = device
        volumeListener = block
    }

    private func detachFromDevice() {
        guard let device = audioDevice, let block = volumeListener else { return }
        var vol = SystemAudio.volumeAddress, mute = SystemAudio.muteAddress
        AudioObjectRemovePropertyListenerBlock(device, &vol, .main, block)
        AudioObjectRemovePropertyListenerBlock(device, &mute, .main, block)
        audioDevice = nil
        volumeListener = nil
    }

    private func volumeChangedExternally() {
        // Key presses already showed the HUD; this catches other changes.
        guard showHUD, Date().timeIntervalSince(lastKeyChange) > 0.3 else { return }
        onHUD?(.volume, SystemAudio.volume() ?? 0, SystemAudio.isMuted())
    }

    // MARK: Key capture (Accessibility)

    private func enableTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            // Start as soon as you allow it in System Settings.
            trustPoll?.invalidate()
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.replaceSystem else { t.invalidate(); return }
                    if AXIsProcessTrusted() { t.invalidate(); self.enableTap() }
                }
            }
            return
        }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media & brightness keys only
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeysService>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.handle(event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: refcon) else { return }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func disableTap() {
        trustPoll?.invalidate(); trustPoll = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Returns true when the key was handled (and should be swallowed).
    private func handle(_ event: CGEvent) -> Bool {
        guard event.type.rawValue == 14,
              let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let state = (ns.data1 & 0xFF00) >> 8
        let isDown = state == 0xA
        let fine = ns.modifierFlags.contains([.option, .shift])
        let step: Float = fine ? 1 / 64 : 1 / 16

        switch code {
        case 0, 1: // volume up / down
            if isDown {
                let muted = SystemAudio.isMuted()
                let v = min(1, max(0, (SystemAudio.volume() ?? 0) + (code == 0 ? step : -step)))
                lastKeyChange = Date()
                SystemAudio.setVolume(v)
                if muted && code == 0 { SystemAudio.setMuted(false) }
                onHUD?(.volume, v, false)
            }
            return true
        case 7: // mute
            if isDown {
                lastKeyChange = Date()
                let m = !SystemAudio.isMuted()
                SystemAudio.setMuted(m)
                onHUD?(.volume, SystemAudio.volume() ?? 0, m)
            }
            return true
        case 2, 3: // brightness up / down
            guard let current = DisplayBrightness.get() else { return false }
            if isDown {
                let b = min(1, max(0, current + (code == 2 ? step : -step)))
                DisplayBrightness.set(b)
                onHUD?(.brightness, b, false)
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - CoreAudio helpers

enum SystemAudio {
    static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultDeviceAddress
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    static func volume() -> Float? {
        guard let d = defaultOutputDevice() else { return nil }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size), addr = volumeAddress
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ value: Float) {
        guard let d = defaultOutputDevice() else { return }
        var v = Float32(value), addr = volumeAddress
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted() -> Bool {
        guard let d = defaultOutputDevice() else { return false }
        var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size), addr = muteAddress
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let d = defaultOutputDevice() else { return }
        var m = UInt32(muted ? 1 : 0), addr = muteAddress
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}

// MARK: - Built-in display brightness (DisplayServices)

enum DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getFn, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setFn, let display = builtInDisplay else { return }
        _ = setFn(display, value)
    }
}
