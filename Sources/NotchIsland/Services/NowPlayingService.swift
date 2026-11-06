import AppKit
import Combine

struct NowPlaying: Equatable, Identifiable {
    var bundleId: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var timestamp: Date = Date()
    var rate: Double = 0
    var isPlaying: Bool = false
    var artwork: NSImage?

    var id: String { bundleId }
    var hasContent: Bool { !title.isEmpty }

    /// Elapsed time right now, extrapolated from the last snapshot.
    func currentElapsed(at now: Date = Date()) -> Double {
        guard isPlaying else { return elapsed }
        let t = elapsed + now.timeIntervalSince(timestamp) * max(rate, 1)
        return duration > 0 ? min(t, duration) : t
    }
}

enum MediaCommand: Int {
    case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
}

/// Runs the bundled adapter inside /usr/bin/perl and turns its JSON lines
/// into a list of players (one per app: Spotify, Chrome, Music, …).
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var players: [NowPlaying] = []
    /// The player shown in the island.
    @Published private(set) var current: NowPlaying?

    /// Player the user picked in the switcher; cleared when another app starts playing.
    private var pinnedId: String?
    /// Player macOS considers "now playing".
    private var systemActiveId: String?

    private var process: Process?
    private var buffer = Data()
    private var artworkIds: [String: String] = [:]
    private var artworks: [String: NSImage] = [:]
    private var artworkTitles: [String: String] = [:]
    private var stopped = false

    private var dylibPath: String? { Bundle.main.path(forResource: "NowPlayingAdapter", ofType: "dylib") }
    private var scriptPath: String? { Bundle.main.path(forResource: "adapter", ofType: "pl") }

    var anyPlaying: Bool { players.contains { $0.isPlaying } }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    // MARK: Switching

    func select(_ id: String) {
        pinnedId = id
        recomputeCurrent()
    }

    func selectNext(offset: Int) {
        guard players.count > 1, let cur = current,
              let i = players.firstIndex(where: { $0.id == cur.id }) else { return }
        let n = players.count
        select(players[((i + offset) % n + n) % n].id)
    }

    private func recomputeCurrent() {
        if let pinned = pinnedId, !players.contains(where: { $0.id == pinned }) { pinnedId = nil }
        let pick = players.first { $0.id == pinnedId }
            ?? players.first { $0.id == systemActiveId && $0.isPlaying }
            ?? players.first { $0.isPlaying }
            ?? players.first { $0.id == systemActiveId }
            ?? players.first
        if pick != current { current = pick }
    }

    // MARK: Commands

    /// Sends play / pause / next / previous to the player shown in the island.
    ///
    /// macOS only lets its own apps aim a media command at a *specific* app;
    /// for everyone else it silently goes to whichever app macOS considers
    /// "current" (that's how pausing Spotify used to start Chrome). So:
    /// - Spotify / Apple Music: their own AppleScript commands (always exact).
    /// - Other apps: the media command only when that app IS macOS's current
    ///   player; otherwise we bring the app to the front instead of risking
    ///   the wrong one.
    /// Play/pause is always explicit — never "toggle" — so a stray command can
    /// never start a different app.
    func send(_ command: MediaCommand) {
        guard let target = current else { return }
        let explicit: MediaCommand = command == .toggle ? (target.isPlaying ? .pause : .play) : command

        if let verb = Self.scriptVerb(explicit), Self.scriptableApps.contains(target.bundleId) {
            runScript("tell application id \"\(target.bundleId)\" to \(verb)")
        } else if target.bundleId == systemActiveId {
            sendMediaRemote(explicit)
        } else {
            // Can't target it safely: open the app instead.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }

        // Optimistic UI so the button feels instant.
        if explicit == .play || explicit == .pause, let i = players.firstIndex(where: { $0.id == target.id }) {
            players[i].elapsed = players[i].currentElapsed()
            players[i].timestamp = Date()
            players[i].isPlaying = explicit == .play
            pinnedId = target.id   // keep showing the player you just controlled
            recomputeCurrent()
        }
    }

    private static let scriptableApps: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private static func scriptVerb(_ c: MediaCommand) -> String? {
        switch c {
        case .play: "play"
        case .pause: "pause"
        case .next: "next track"
        case .previous: "previous track"
        case .toggle: "playpause"
        }
    }

    private let scriptQueue = DispatchQueue(label: "notchisland.applescript")

    private func runScript(_ source: String) {
        scriptQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { DebugLog.write("media: AppleScript error \(error[NSAppleScript.errorNumber] ?? "?")") }
        }
    }

    private func sendMediaRemote(_ command: MediaCommand) {
        guard let dylib = dylibPath, let script = scriptPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, dylib, "command"]
        p.environment = ["PATH": "/usr/bin:/bin", "NIS_CMD": String(command.rawValue)]
        try? p.run()
    }

    // MARK: Adapter process

    private func launch() {
        guard !stopped, let dylib = dylibPath, let script = scriptPath else {
            NSLog("NotchIsland: adapter files missing from app bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, dylib, "stream"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self, !self.stopped else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.launch()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("NotchIsland: failed to start adapter: \(error)")
        }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let list = obj["players"] as? [[String: Any]] else { return }
        systemActiveId = obj["active"] as? String

        let wasPlaying = Set(players.filter(\.isPlaying).map(\.id))
        var parsed: [NowPlaying] = []
        var seen: Set<String> = []
        for p in list {
            guard let bid = p["bundleId"] as? String else { continue }
            seen.insert(bid)
            var n = NowPlaying()
            n.bundleId = bid
            n.title = p["title"] as? String ?? ""
            n.artist = p["artist"] as? String ?? ""
            n.album = p["album"] as? String ?? ""
            n.duration = p["duration"] as? Double ?? 0
            n.elapsed = p["elapsed"] as? Double ?? 0
            n.rate = p["rate"] as? Double ?? 0
            n.isPlaying = p["playing"] as? Bool ?? false
            if let ts = p["timestamp"] as? Double { n.timestamp = Date(timeIntervalSince1970: ts) }

            // While you pause/resume, apps briefly publish info without artwork.
            // Keep the last picture as long as it's the same track, so the
            // island doesn't flicker to the app icon.
            let sameTrack = artworkTitles[bid] == n.title
            let artId = p["artworkId"] as? String ?? ""
            if let b64 = p["artwork"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                artworks[bid] = img
                artworkTitles[bid] = n.title
            } else if !sameTrack {
                artworks[bid] = nil
            }
            if !artId.isEmpty { artworkIds[bid] = artId }
            n.artwork = artworks[bid]
            parsed.append(n)
        }
        for gone in Set(artworks.keys).subtracting(seen) {
            artworks[gone] = nil
            artworkIds[gone] = nil
            artworkTitles[gone] = nil
        }

        // If a different app just started playing, follow it (like iPhone does).
        if AppSettings.shared.followNewPlayer,
           parsed.contains(where: { $0.isPlaying && !wasPlaying.contains($0.id) && $0.id != pinnedId }) {
            pinnedId = nil
        }
        players = parsed
        recomputeCurrent()
    }
}
