import AppKit
import CoreServices

/// Keeps a live list of your most recent screenshots / screen recordings from
/// the folder macOS saves them to (Desktop unless you changed it). Delete one
/// in Finder and it disappears from the shelf too. Read-only.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var recent: [URL] = []

    private var source: DispatchSourceFileSystemObject?
    private var watched: URL?
    private var pending: DispatchWorkItem?
    private let limit = 12

    /// The folder macOS saves screenshots to (`defaults read com.apple.screencapture location`).
    static func folder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func setEnabled(_ on: Bool) {
        stopWatching()
        guard on else { recent = []; return }
        rescan()
    }

    /// Re-reads the folder (also picks up a changed screenshot location).
    func rescan() {
        let folder = Self.folder()
        if folder != watched { startWatching(folder) }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let shots = files.filter(Self.isScreenshot).map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (url, date)
        }
        let newest = shots.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        if newest != recent { recent = newest }
    }

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf", "mov", "mp4"]
    private static let prefixes = ["Screenshot", "Screen Shot", "Screen Recording", "CleanShot"]

    private static func isScreenshot(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()) else { return false }
        let name = url.lastPathComponent
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        // Other languages: macOS tags screenshots in Spotlight.
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return flag
        }
        return false
    }

    // MARK: Folder watching

    private func startWatching(_ folder: URL) {
        stopWatching()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watched = folder
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        watched = nil
    }

    /// Screenshots are written in a few steps; wait for them to settle.
    private func scheduleRescan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
