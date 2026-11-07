import Foundation

/// Optional: reads headset battery from Logitech G HUB, if it's running.
///
/// A Logitech headset only reports its battery *voltage*, which is misleading
/// while charging. G HUB runs Logitech's own estimate and exposes it to its
/// window over a local-only WebSocket on 127.0.0.1:9010. We connect there
/// (never to the internet), ask for the headset's battery and subscribe to
/// changes. Read-only: only GET / SUBSCRIBE messages are ever sent.
@MainActor
final class GHubClient {
    struct Battery: Equatable {
        var deviceName: String
        var percent: Double
        var charging: Bool
        var full: Bool
        var hoursLeft: Double?
        var updated: Date
    }

    private(set) var battery: Battery?
    var onChange: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var headsetId: String?
    private var headsetName = "Headset"
    private var retry: Timer?
    private var refresh: Timer?
    private var enabled = false

    func setEnabled(_ on: Bool) {
        enabled = on
        disconnect()
        retry?.invalidate(); retry = nil
        guard on else { battery = nil; onChange?(); return }
        connect()
        // Reconnect if G HUB starts later or restarts.
        retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.task == nil else { return }
                self.connect()
            }
        }
        retry?.tolerance = 5
    }

    /// Fresh enough to trust (G HUB pushes changes; we also re-ask every minute).
    var current: Battery? {
        guard let b = battery, Date().timeIntervalSince(b.updated) < 600 else { return nil }
        return b
    }

    private func connect() {
        guard let url = URL(string: "ws://127.0.0.1:9010") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("file://", forHTTPHeaderField: "Origin")
        req.setValue("json", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let s = URLSession(configuration: config)
        let t = s.webSocketTask(with: req)
        session = s
        task = t
        t.resume()
        receive()
        send("GET", "/devices/list")
        send("SUBSCRIBE", "/battery/state/changed")
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.headsetId else { return }
                self.send("GET", "/battery/\(id)/state")
            }
        }
    }

    private func disconnect() {
        refresh?.invalidate(); refresh = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        headsetId = nil
    }

    private func send(_ verb: String, _ path: String) {
        let msg = ["msgId": path, "verb": verb, "path": path]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    // G HUB not running / closed: fall back to the headset reading.
                    self.disconnect()
                    if self.battery != nil { self.battery = nil; self.onChange?() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }

        if path == "/devices/list", let list = payload["deviceInfos"] as? [[String: Any]] {
            if let headset = list.first(where: { ($0["deviceType"] as? String) == "HEADSET" }),
               let id = headset["id"] as? String {
                headsetId = id
                headsetName = (headset["displayName"] as? String) ?? "Headset"
                send("GET", "/battery/\(id)/state")
                DebugLog.write("ghub: connected, headset \(headsetName)")
            }
            return
        }

        guard path.hasPrefix("/battery"),
              let id = payload["deviceId"] as? String, id == headsetId,
              let percent = payload["percentage"] as? Double else { return }
        let b = Battery(deviceName: headsetName,
                        percent: percent,
                        charging: payload["charging"] as? Bool ?? false,
                        full: payload["fullyCharged"] as? Bool ?? false,
                        hoursLeft: payload["mileage"] as? Double,
                        updated: Date())
        let changed = battery.map { Int($0.percent.rounded()) != Int(b.percent.rounded()) || $0.charging != b.charging || $0.full != b.full } ?? true
        battery = b
        if changed { onChange?() }
    }
}
