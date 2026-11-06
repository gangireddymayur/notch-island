import Foundation

/// Tiny local log at ~/Library/Logs/Notch Island.log (a few lines, for
/// troubleshooting devices). Never leaves the Mac.
enum DebugLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Notch Island.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            // Keep it small.
            if (try? h.seekToEnd()) ?? 0 > 200_000 { try? h.truncate(atOffset: 0) }
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
