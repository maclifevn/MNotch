import AppKit
import Observation

private struct ShelfSnapshot: Sendable {
    let revision: UInt64
    let items: [URL]
}

private struct ShelfClearResult: Sendable {
    let snapshot: ShelfSnapshot
    let failedNames: [String]
}

private actor ShelfFileWorker {
    private enum WorkerError: LocalizedError {
        case capacity(Int)

        var errorDescription: String? {
            switch self {
            case .capacity(let limit): "File Tray can hold up to \(limit) items."
            }
        }
    }

    private static let itemLimit = 100
    private let directory: URL
    private let fm = FileManager.default
    private var revision: UInt64 = 0

    init(directory: URL) {
        self.directory = directory
    }

    func list() throws -> ShelfSnapshot {
        ShelfSnapshot(revision: revision, items: try sortedItems())
    }

    private func sortedItems() throws -> [URL] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        )
        // Read metadata once per item. Doing it inside the sort comparator
        // turns 100 files into hundreds of filesystem/XPC lookups.
        return urls.map { url in
            let date = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    func add(_ urls: [URL]) throws -> ShelfSnapshot {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard existing.count + urls.count <= Self.itemLimit else {
            throw WorkerError.capacity(Self.itemLimit)
        }

        var copied: [URL] = []
        do {
            for url in urls {
                let destination = uniqueDestination(for: url)
                try fm.copyItem(at: url, to: destination)
                copied.append(destination)
            }
        } catch {
            // Keep a failed multi-file drop atomic; no invisible partial batch.
            for destination in copied {
                try? fm.removeItem(at: destination)
            }
            throw error
        }
        revision &+= 1
        return ShelfSnapshot(revision: revision, items: try sortedItems())
    }

    func remove(_ url: URL) throws -> ShelfSnapshot {
        try fm.trashItem(at: url, resultingItemURL: nil)
        revision &+= 1
        return ShelfSnapshot(revision: revision, items: try sortedItems())
    }

    func clear(_ urls: [URL]) throws -> ShelfClearResult {
        var removedAny = false
        var failedNames: [String] = []
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                removedAny = true
            } catch {
                // Continue clearing the remaining files. A single item with a
                // transient permission problem must not leave the whole tray
                // visually stuck, and the resulting snapshot reconciles any
                // partial success exactly.
                failedNames.append(url.lastPathComponent)
            }
        }
        if removedAny { revision &+= 1 }
        return ShelfClearResult(
            snapshot: ShelfSnapshot(revision: revision, items: try sortedItems()),
            failedNames: failedNames
        )
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
    /// Selection belongs to the tray, not to a transient SwiftUI tab. Keeping
    /// it here preserves multi-selection while the notch collapses, another
    /// app becomes active, or ShelfView is reconstructed.
    private(set) var selection: Set<URL> = []
    private(set) var isBusy = false
    private(set) var lastError: String?
    @ObservationIgnored private var activeOperations = 0
    @ObservationIgnored private var lastAppliedRevision: UInt64 = 0
    @ObservationIgnored private var pendingRemovals: Set<URL> = []
    @ObservationIgnored private var retainedAfterDrag: [String: TimeInterval] = [:]
    @ObservationIgnored private var retainedCleanupTask: Task<Void, Never>?
    @ObservationIgnored private let worker: ShelfFileWorker

    private static let retainedDefaultsKey = "shelf.retainedAfterDrag"
    private static let dragRetentionInterval: TimeInterval = 24 * 60 * 60
    private static let failedCleanupRetryInterval: TimeInterval = 60 * 60

    private static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appending(path: "MNotch/Shelf")
    }

    private init() {
        worker = ShelfFileWorker(directory: Self.directory)
        let saved = UserDefaults.standard.dictionary(forKey: Self.retainedDefaultsKey) ?? [:]
        retainedAfterDrag = saved.reduce(into: [:]) { result, entry in
            if let deadline = entry.value as? NSNumber {
                result[entry.key] = deadline.doubleValue
            }
        }
        reload()
        scheduleRetainedCleanup()
    }

    var selectedItems: [URL] {
        items.filter(selection.contains)
    }

    func toggleSelection(_ url: URL) {
        guard items.contains(url) else { return }
        if selection.contains(url) {
            selection.remove(url)
        } else {
            selection.insert(url)
        }
    }

    func selectForDrag(_ url: URL) {
        guard items.contains(url), !selection.contains(url) else { return }
        selection = [url]
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
        guard let originalIndex = items.firstIndex(of: url) else { return }

        // Remove from the observable collection immediately so the delete
        // button feels direct. FileManager work stays on ShelfFileWorker; if
        // Trash fails, restore just this item without undoing other operations.
        items.remove(at: originalIndex)
        selection.remove(url)
        pendingRemovals.insert(url)
        activeOperations += 1
        isBusy = true
        lastError = nil

        Task { [weak self, worker] in
            do {
                let snapshot = try await worker.remove(url)
                guard let self else { return }
                self.pendingRemovals.remove(url)
                self.apply(snapshot)
            } catch {
                guard let self else { return }
                self.pendingRemovals.remove(url)
                if !self.items.contains(url) {
                    self.items.insert(url, at: min(originalIndex, self.items.count))
                }
                self.lastError = error.localizedDescription
                mnotchLog.error("Shelf remove failed: \(error)")
            }
            guard let self else { return }
            self.activeOperations -= 1
            self.isBusy = self.activeOperations > 0
        }
    }

    func clear() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }

        // Match per-item removal: clear the UI on this frame and reconcile the
        // exact filesystem result afterward. This also prevents a slow Trash
        // operation from making the Clear button look unresponsive.
        items.removeAll()
        selection.subtract(snapshot)
        pendingRemovals.formUnion(snapshot)
        activeOperations += 1
        isBusy = true
        lastError = nil

        Task { [weak self, worker] in
            do {
                let result = try await worker.clear(snapshot)
                guard let self else { return }
                self.pendingRemovals.subtract(snapshot)
                self.apply(result.snapshot)
                if !result.failedNames.isEmpty {
                    self.lastError = String(
                        format: L10n.string("Couldn't remove: %@"),
                        result.failedNames.prefix(3).joined(separator: ", ")
                    )
                }
            } catch {
                guard let self else { return }
                self.pendingRemovals.subtract(snapshot)
                self.lastError = error.localizedDescription
                // Listing failed after a possibly partial clear. Queue one
                // authoritative reconciliation instead of restoring a stale
                // all-or-nothing snapshot.
                self.reload()
                mnotchLog.error("Shelf clear failed: \(error)")
            }
            guard let self else { return }
            self.activeOperations -= 1
            self.isBusy = self.activeOperations > 0
        }
    }

    /// Hide successfully dragged items immediately without invalidating file
    /// URLs that a receiving app may still read asynchronously. The backing
    /// copies stay at the same paths for a bounded grace period, then move to
    /// Trash in the background.
    func dismissAfterSuccessfulDrag(_ urls: [URL]) {
        let dismissed = Set(urls).intersection(items)
        guard !dismissed.isEmpty else { return }

        let deadline = Date().timeIntervalSince1970 + Self.dragRetentionInterval
        for url in dismissed {
            retainedAfterDrag[url.path] = deadline
        }
        items.removeAll { dismissed.contains($0) }
        selection.subtract(dismissed)
        persistRetainedItems()
        scheduleRetainedCleanup()
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop)
        else { return }
        service.perform(withItems: urls)
    }

    private func perform(
        _ operation: @escaping @Sendable (ShelfFileWorker) async throws -> ShelfSnapshot
    ) {
        activeOperations += 1
        isBusy = true
        lastError = nil
        Task { [weak self, worker] in
            do {
                let updated = try await operation(worker)
                guard let self else { return }
                self.apply(updated)
            } catch {
                self?.lastError = error.localizedDescription
                mnotchLog.error("Shelf operation failed: \(error)")
            }
            guard let self else { return }
            self.activeOperations -= 1
            self.isBusy = self.activeOperations > 0
        }
    }

    private func apply(_ snapshot: ShelfSnapshot) {
        // Actor operations can finish their filesystem work in one order but
        // resume their MainActor continuations in another. Never publish an
        // older directory view over a newer one, and keep optimistic removals
        // filtered until their Trash operation resolves.
        guard snapshot.revision >= lastAppliedRevision else { return }
        lastAppliedRevision = snapshot.revision
        let pathsOnDisk = Set(snapshot.items.map(\.path))
        let retainedCount = retainedAfterDrag.count
        retainedAfterDrag = retainedAfterDrag.filter { pathsOnDisk.contains($0.key) }
        if retainedAfterDrag.count != retainedCount {
            persistRetainedItems()
            scheduleRetainedCleanup()
        }
        items = snapshot.items.filter {
            !pendingRemovals.contains($0) && retainedAfterDrag[$0.path] == nil
        }
        selection.formIntersection(items)
    }

    private func persistRetainedItems() {
        UserDefaults.standard.set(retainedAfterDrag, forKey: Self.retainedDefaultsKey)
    }

    private func scheduleRetainedCleanup() {
        retainedCleanupTask?.cancel()
        retainedCleanupTask = nil
        guard let nextDeadline = retainedAfterDrag.values.min() else { return }
        let delay = max(0, nextDeadline - Date().timeIntervalSince1970)
        retainedCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.cleanupExpiredRetainedItems()
        }
    }

    private func cleanupExpiredRetainedItems() {
        retainedCleanupTask = nil
        let now = Date().timeIntervalSince1970
        let expiredPaths = retainedAfterDrag.compactMap { path, deadline in
            deadline <= now ? path : nil
        }
        guard !expiredPaths.isEmpty else {
            scheduleRetainedCleanup()
            return
        }

        let expiredURLs = expiredPaths.map { URL(fileURLWithPath: $0) }
        Task { [weak self, worker] in
            do {
                let result = try await worker.clear(expiredURLs)
                guard let self else { return }
                let remainingPaths = Set(result.snapshot.items.map(\.path))
                for path in expiredPaths {
                    if remainingPaths.contains(path) {
                        self.retainedAfterDrag[path] = Date().timeIntervalSince1970
                            + Self.failedCleanupRetryInterval
                    } else {
                        self.retainedAfterDrag[path] = nil
                    }
                }
                self.persistRetainedItems()
                self.apply(result.snapshot)
                self.scheduleRetainedCleanup()
                if !result.failedNames.isEmpty {
                    let names = result.failedNames.prefix(3).joined(separator: ", ")
                    mnotchLog.error(
                        "Shelf deferred cleanup couldn't remove: \(names, privacy: .public)"
                    )
                }
            } catch {
                guard let self else { return }
                let retry = Date().timeIntervalSince1970
                    + Self.failedCleanupRetryInterval
                for path in expiredPaths {
                    self.retainedAfterDrag[path] = retry
                }
                self.persistRetainedItems()
                self.scheduleRetainedCleanup()
                mnotchLog.error("Shelf deferred cleanup failed: \(error)")
            }
        }
    }
}
