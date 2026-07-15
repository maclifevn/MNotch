import AppKit
import Observation

private actor ShelfFileWorker {
    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL) {
        self.directory = directory
    }

    func list() throws -> [URL] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
            return da > db
        }
    }

    func add(_ urls: [URL]) throws -> [URL] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            let destination = uniqueDestination(for: url)
            try fm.copyItem(at: url, to: destination)
        }
        return try list()
    }

    func remove(_ url: URL) throws -> [URL] {
        try fm.trashItem(at: url, resultingItemURL: nil)
        return try list()
    }

    func clear(_ urls: [URL]) throws -> [URL] {
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
        return try list()
    }

    private func uniqueDestination(for source: URL) -> URL {
        let original = directory.appending(path: source.lastPathComponent)
        guard fm.fileExists(atPath: original.path) else { return original }

        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        while true {
            let candidate = directory.appending(
                path: "\(stem)-\(UUID().uuidString.prefix(8))\(suffix)"
            )
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
    }
}

/// File shelf backed by ~/Library/Application Support/MNotch/Shelf.
/// Dropped files are copied in; dragging out hands over the stored URL.
@MainActor
@Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var items: [URL] = []
    private(set) var isBusy = false
    private(set) var lastError: String?
    @ObservationIgnored private var activeOperations = 0
    @ObservationIgnored private let worker: ShelfFileWorker

    private static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appending(path: "MNotch/Shelf")
    }

    private init() {
        worker = ShelfFileWorker(directory: Self.directory)
        reload()
    }

    func reload() {
        perform { worker in
            try await worker.list()
        }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform { worker in
            try await worker.add(urls)
        }
    }

    func remove(_ url: URL) {
        perform { worker in
            try await worker.remove(url)
        }
    }

    func clear() {
        let snapshot = items
        perform { worker in
            try await worker.clear(snapshot)
        }
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop)
        else { return }
        service.perform(withItems: urls)
    }

    private func perform(
        _ operation: @escaping @Sendable (ShelfFileWorker) async throws -> [URL]
    ) {
        activeOperations += 1
        isBusy = true
        lastError = nil
        Task { [weak self, worker] in
            do {
                let updated = try await operation(worker)
                guard let self else { return }
                self.items = updated
            } catch {
                self?.lastError = error.localizedDescription
                mnotchLog.error("Shelf operation failed: \(error)")
            }
            guard let self else { return }
            self.activeOperations -= 1
            self.isBusy = self.activeOperations > 0
        }
    }
}
