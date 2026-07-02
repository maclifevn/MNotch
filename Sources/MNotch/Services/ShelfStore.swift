import AppKit
import Observation

/// File shelf backed by ~/Library/Application Support/MNotch/Shelf.
/// Dropped files are copied in; dragging out hands over the stored URL.
@MainActor
@Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var items: [URL] = []

    private static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appending(path: "MNotch/Shelf")
    }

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true
        )
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
            return da > db
        }
    }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            var destination = Self.directory.appending(path: url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                destination = Self.directory.appending(
                    path: "\(stem)-\(Int(Date().timeIntervalSince1970))\(suffix)"
                )
            }
            try? fm.copyItem(at: url, to: destination)
        }
        reload()
    }

    func remove(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    func clear() {
        for item in items {
            try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
        reload()
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop)
        else { return }
        service.perform(withItems: urls)
    }
}
