import AppKit
import UniformTypeIdentifiers

/// Files you drop on the notch. Real files are remembered by location only —
/// nothing is copied or uploaded. Things that aren't files yet (like the
/// floating screenshot preview) are saved into the app's own shelf folder.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let key = "shelfItems"

    /// ~/Library/Application Support/Notch Island/Shelf
    nonisolated static let importsFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Notch Island/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
        prune()
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(url) {
            items.insert(url, at: 0)
        }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        // Files we created ourselves (from drops) are cleaned up too.
        if url.path.hasPrefix(Self.importsFolder.path) { try? FileManager.default.removeItem(at: url) }
        save()
    }

    func clear() {
        for url in items { remove(url) }
    }

    /// Forget files that were moved or deleted.
    func prune() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive != items { items = alive; save() }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if service.canPerform(withItems: urls) { service.perform(withItems: urls) }
    }

    // MARK: Dropping

    static let dropTypes: [UTType] = [.fileURL, .image, .movie, .pdf]

    /// Handles both normal files and "promised" content (screenshot preview,
    /// images dragged from a browser, …).
    func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add([url]) }
                }
            } else if let type = [UTType.image, .movie, .pdf].first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                let suggested = provider.suggestedName
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tmp, _ in
                    // The temporary file is deleted when this returns, so copy now.
                    guard let tmp, let saved = Self.importCopy(of: tmp, name: suggested) else { return }
                    Task { @MainActor in self.add([saved]) }
                }
            }
        }
    }

    nonisolated private static func importCopy(of tmp: URL, name: String?) -> URL? {
        let ext = tmp.pathExtension
        var base = (name?.isEmpty == false ? name! : tmp.deletingPathExtension().lastPathComponent)
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        }
        var dest = importsFolder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = importsFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}
