import AppKit
import Observation
import SQLite3

/// Mirrors newly delivered macOS notifications onto the notch.
///
/// There is no public API to observe other apps' notifications, so this reads
/// the private `usernotificationsd` store at
/// `~/Library/Group Containers/group.com.apple.usernotifications/db2/db`, which
/// requires **Full Disk Access**. The store is a live SQLite/WAL database, so
/// each poll copies it to a temp file first (a read-only open of someone else's
/// WAL database is unreliable) and reads the copy. Undocumented and version
/// fragile by nature — decoding is deliberately defensive and only *new* records
/// are surfaced; history is never replayed.
@MainActor
@Observable
final class NotificationMirrorService {
    enum Access: Equatable { case unknown, granted, denied }
    private(set) var access: Access = .unknown

    struct Item: Equatable, Sendable {
        let bundleID: String
        let appName: String
        let title: String
        let body: String
    }

    @ObservationIgnored var onNotification: ((Item) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Highest `rec_id` already surfaced; seeded to the current max on the first
    /// read so existing notifications aren't replayed as a burst on launch.
    @ObservationIgnored private var lastRecID: Int64 = -1
    @ObservationIgnored private var baselined = false
    /// db + wal modification times; skip the copy/read when nothing changed.
    @ObservationIgnored private var lastSignature: String?

    /// Our own bundle and a few chatty system notifiers never make sense on the
    /// notch (they'd echo MNotch's own pops or spam wake/lock chatter).
    private static let ignoredBundles: Set<String> = [
        "com.mnotch.app",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
    ]

    private nonisolated static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.usernotifications/db2/db")
    }

    func start() {
        guard timer == nil else { return }
        // Re-baseline on every (re)start so notifications delivered while we were
        // stopped (e.g. during display sleep) aren't replayed as a burst.
        baselined = false
        lastSignature = nil
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.requestPoll() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        requestPoll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func openFullDiskAccessSettings() {
        let anchor = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: anchor) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling

    private func requestPoll() {
        guard pollTask == nil else { return }
        let since = lastRecID
        let signature = lastSignature
        pollTask = Task.detached(priority: .utility) {
            let result = Self.readNew(since: since, lastSignature: signature)
            await MainActor.run { [weak self] in self?.apply(result) }
        }
    }

    private struct PollResult: Sendable {
        let access: Access
        let signature: String?
        /// nil when no read happened (no access, or nothing changed).
        let maxRecID: Int64?
        let items: [Item]
    }

    private func apply(_ result: PollResult) {
        pollTask = nil
        access = result.access
        if let signature = result.signature { lastSignature = signature }
        guard let maxRecID = result.maxRecID else { return }

        if !baselined {
            baselined = true
            lastRecID = maxRecID
            return   // adopt the current state silently; only mirror what comes next
        }
        lastRecID = max(lastRecID, maxRecID)
        for item in result.items where !Self.ignoredBundles.contains(item.bundleID) {
            onNotification?(item)
        }
    }

    // MARK: - Database read (off the main actor)

    private nonisolated static func readNew(since: Int64, lastSignature: String?) -> PollResult {
        let db = dbURL
        let signature: String
        do {
            signature = try currentSignature(db)
        } catch {
            // Reading the TCC-protected container throws until Full Disk Access
            // is granted.
            return PollResult(access: .denied, signature: nil, maxRecID: nil, items: [])
        }
        if let lastSignature, lastSignature == signature {
            return PollResult(access: .granted, signature: signature, maxRecID: nil, items: [])
        }
        guard let copy = try? copyDatabase(db) else {
            return PollResult(access: .granted, signature: signature, maxRecID: nil, items: [])
        }
        defer { try? FileManager.default.removeItem(at: copy.dir) }

        let (items, maxID) = readRecords(dbPath: copy.dbPath, since: since)
        return PollResult(access: .granted, signature: signature, maxRecID: maxID, items: items)
    }

    /// db + wal modification times. Throws (EPERM) when Full Disk Access is
    /// missing, which is how access is detected.
    private nonisolated static func currentSignature(_ db: URL) throws -> String {
        let fm = FileManager.default
        let dbDate = (try fm.attributesOfItem(atPath: db.path)[.modificationDate] as? Date)
            ?? .distantPast
        var walStamp = 0.0
        if let attrs = try? fm.attributesOfItem(atPath: db.path + "-wal"),
           let walDate = attrs[.modificationDate] as? Date {
            walStamp = walDate.timeIntervalSince1970
        }
        return "\(dbDate.timeIntervalSince1970)|\(walStamp)"
    }

    /// Copy db (+ -wal/-shm) so we read a consistent snapshot without contending
    /// with usernotificationsd or hitting read-only WAL limitations.
    private nonisolated static func copyDatabase(_ db: URL) throws -> (dir: URL, dbPath: String) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "mnotch-notif-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destDB = dir.appending(path: "db")
        try fm.copyItem(at: URL(fileURLWithPath: db.path), to: destDB)
        for ext in ["-wal", "-shm"] {
            let src = db.path + ext
            if fm.fileExists(atPath: src) {
                try? fm.copyItem(at: URL(fileURLWithPath: src), to: dir.appending(path: "db" + ext))
            }
        }
        return (dir, destDB.path)
    }

    private nonisolated static func readRecords(dbPath: String, since: Int64) -> ([Item], Int64?) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return ([], nil)
        }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT r.rec_id, a.identifier, r.data
        FROM record r JOIN app a ON r.app_id = a.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id ASC LIMIT 30;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            // Schema differs from the known layout — log its shape (names only,
            // no content) so it can be adapted, then skip.
            mnotchLog.error("Notification DB schema unexpected: \(schemaDescription(handle), privacy: .public)")
            return ([], nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)

        var items: [Item] = []
        var maxID = since
        var rowsSeen = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowsSeen += 1
            maxID = max(maxID, sqlite3_column_int64(stmt, 0))
            let bundle = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: length)
            let content = decode(data)
            if rowsSeen == 1, content == nil {
                // First record didn't yield title/body — log the blob's key
                // names (not values) so the real keys can be identified.
                mnotchLog.debug("notif blob keys: \(blobKeyNames(data), privacy: .public)")
            }
            guard let content,
                  !(content.title.isEmpty && content.body.isEmpty)
            else { continue }
            items.append(Item(
                bundleID: bundle,
                appName: displayName(for: bundle),
                title: content.title,
                body: content.body
            ))
        }
        return (items, maxID)
    }

    /// The record blob is a binary plist whose title/subtitle/body live under
    /// short keys (`titl`/`subt`/`body`). Their exact nesting has shifted across
    /// macOS versions, so search the whole tree instead of a fixed path.
    private nonisolated static func decode(_ data: Data) -> (title: String, body: String)? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        var title = "", subtitle = "", body = ""
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                if title.isEmpty, let value = dict["titl"] as? String { title = value }
                if subtitle.isEmpty, let value = dict["subt"] as? String { subtitle = value }
                if body.isEmpty, let value = dict["body"] as? String { body = value }
                for value in dict.values { walk(value) }
            } else if let array = any as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        let fullBody = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " — ")
        guard !(title.isEmpty && fullBody.isEmpty) else { return nil }
        return (title, fullBody)
    }

    /// Table + column names of the record/app tables (no row content), for
    /// diagnosing a schema that no longer matches the query.
    private nonisolated static func schemaDescription(_ handle: OpaquePointer?) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT name, sql FROM sqlite_master WHERE type='table'",
            -1, &stmt, nil
        ) == SQLITE_OK else { return "unreadable" }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "?"
            if ["record", "app"].contains(name) {
                let sql = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                lines.append(sql)
            } else {
                lines.append(name)
            }
        }
        return lines.joined(separator: " ;; ")
    }

    /// Key names inside the record blob (values omitted — never log content).
    private nonisolated static func blobKeyNames(_ data: Data) -> String {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return "not-a-plist" }
        var keys: Set<String> = []
        func walk(_ any: Any, depth: Int) {
            guard depth < 4 else { return }
            if let dict = any as? [String: Any] {
                keys.formUnion(dict.keys)
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let array = any as? [Any] {
                for value in array { walk(value, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return keys.sorted().joined(separator: ",")
    }

    private nonisolated static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
