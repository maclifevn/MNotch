// Shared verbatim with MFinder/DropTray/NotchDropBridge.swift.
// Protocol v1 transfers routing metadata only. File/promise intake stays native.
import AppKit
import Darwin
import Observation
import Security

enum NotchDropApp: String, Codable, CaseIterable, Sendable {
    case mnotch, mfinder
    var title: String { self == .mfinder ? "MFinder" : "MNotch" }
    var bundleID: String { self == .mfinder ? "com.maclife.mfinder" : "com.mnotch.app" }
}

enum NotchDropPreference: String, Codable, CaseIterable, Sendable {
    case automatic, mfinder, mnotch, off
    var selectedApp: NotchDropApp? { NotchDropApp(rawValue: rawValue) }
    var unavailableMessage: String {
        switch self {
        case .mfinder: String(localized: "MFinder is not ready. Open it and enable notch file receiving.")
        case .mnotch: String(localized: "MNotch is not ready. Open it and enable File Tray on the target display.")
        default: ""
        }
    }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .mfinder: "MFinder"
        case .mnotch: "MNotch"
        case .off: String(localized: "Off")
        }
    }
}

struct NotchDropPeer: Codable, Equatable, Sendable {
    var app: NotchDropApp
    var instance: UUID
    var pid: Int32
    var launched: TimeInterval
    var displays: [UInt32]
}

struct NotchDropOwner: Codable, Equatable, Sendable {
    var app: NotchDropApp
    var instance: UUID
}

struct NotchDropLease: Codable, Equatable, Sendable {
    var key: String
    var owners: [String: NotchDropOwner]
}

struct NotchDropState: Codable, Equatable, Sendable {
    var schema = 1
    var preference: NotchDropPreference = .automatic
    var peers: [String: NotchDropPeer] = [:]
    var leases: [NotchDropLease] = []

    /// An immutable decision for each display for the entire native gesture.
    /// Removing a crashed peer never changes an existing lease, including one
    /// with no destination. A new process cannot inherit its predecessor's drop.
    mutating func reserve(key: String) {
        guard !leases.contains(where: { $0.key == key }) else { return }
        var owners: [String: NotchDropOwner] = [:]
        for display in Set(peers.values.flatMap(\.displays)) {
            let candidates = peers.values.filter { $0.displays.contains(display) }
            let chosen: NotchDropPeer?
            switch preference {
            case .automatic: chosen = candidates.first { $0.app == .mfinder } ?? candidates.first { $0.app == .mnotch }
            case .mfinder: chosen = candidates.first { $0.app == .mfinder }
            case .mnotch: chosen = candidates.first { $0.app == .mnotch }
            case .off: chosen = nil
            }
            if let chosen { owners[String(display)] = .init(app: chosen.app, instance: chosen.instance) }
        }
        leases.append(.init(key: key, owners: owners))
        if leases.count > 16 { leases.removeFirst(leases.count - 16) }
    }
}

/// Serialized, bounded, same-user metadata transactions. Never called on the
/// main thread or from an AppKit dragging callback. Notifications only wake
/// readers; the locked, atomically replaced file is the source of truth.
final class NotchDropDiskStore: @unchecked Sendable {
    enum StoreError: Error { case busy, unsafePath, invalidState, invalidPeer }
    let directory: URL
    let epoch: String
    private let isAlive: @Sendable (NotchDropPeer) -> Bool

    init(directory: URL, epoch: String,
         isAlive: @escaping @Sendable (NotchDropPeer) -> Bool) {
        self.directory = directory
        self.epoch = epoch
        self.isAlive = isAlive
    }

    private static func createDirectory(_ url: URL) throws {
        // Permissions are applied by mkdir itself, including a previously
        // absent MacLife parent during simultaneous first launches.
        if mkdir(url.path, 0o700) == 0 || errno == EEXIST { return }
        guard errno == ENOENT else { throw StoreError.unsafePath }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw StoreError.unsafePath }
        try createDirectory(parent)
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw StoreError.unsafePath }
    }

    func transaction(peer: NotchDropPeer, remove: Bool = false,
                     preference: NotchDropPreference? = nil, generation: Int? = nil) throws -> (NotchDropState, Bool) {
        // Do not publish an endpoint that the other app cannot authenticate.
        // Otherwise two invalid endpoints could endlessly prune/re-add each
        // other in response to their own notifications.
        guard remove || isAlive(peer) else { throw StoreError.invalidPeer }
        try Self.createDirectory(directory)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o077 == 0 else { throw StoreError.unsafePath }
        let lock = open(directory.appendingPathComponent("routing.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StoreError.unsafePath }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(),
              lockInfo.st_mode & S_IFMT == S_IFREG else { throw StoreError.unsafePath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
        defer { flock(lock, LOCK_UN) }
        let path = directory.appendingPathComponent("routing.json")
        var state = NotchDropState()
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= 65536 else { throw StoreError.invalidState }
            var data = Data(count: Int(info.st_size))
            let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count == data.count, let decoded = try? JSONDecoder().decode(NotchDropState.self, from: data),
                  decoded.schema == 1, decoded.peers.count <= 2, decoded.leases.count <= 16,
                  decoded.peers.allSatisfy({ $0.key == $0.value.app.rawValue && $0.value.displays.count <= 64 && $0.value.launched.isFinite }),
                  decoded.leases.allSatisfy({ $0.key.count <= 128 && $0.owners.count <= 64 }) else { throw StoreError.invalidState }
            state = decoded
        } else if errno != ENOENT { throw StoreError.unsafePath }
        let previous = state
        state.peers = state.peers.filter { isAlive($0.value) }
        if remove {
            if state.peers[peer.app.rawValue]?.instance == peer.instance { state.peers[peer.app.rawValue] = nil }
        } else { state.peers[peer.app.rawValue] = peer }
        if let preference { state.preference = preference }
        if let generation { state.reserve(key: "\(epoch):\(generation)") }
        let changed = state != previous
        if changed {
            let data = try JSONEncoder().encode(state)
            guard data.count <= 65536 else { throw StoreError.invalidState }
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        return (state, changed)
    }
}

/// A signature is immutable for one PID/launch identity. Liveness is checked
/// on every transaction; expensive validation is needed only once per process.
private final class NotchDropSignatureCache: @unchecked Sendable {
    static let shared = NotchDropSignatureCache()
    private let lock = NSLock()
    private var entries: Set<String> = []
    func contains(_ key: String) -> Bool { lock.withLock { entries.contains(key) } }
    func insert(_ key: String) {
        lock.withLock {
            if entries.count >= 64 { entries.removeAll() }
            entries.insert(key)
        }
    }
}

@MainActor @Observable
final class NotchDropBridge {
    static let shared = NotchDropBridge(app: Bundle.main.bundleIdentifier == NotchDropApp.mfinder.bundleID ? .mfinder : .mnotch)
    nonisolated static let notification = Notification.Name("com.maclife.notch-drop.routing.v1")
    let app: NotchDropApp
    private(set) var preference: NotchDropPreference = .automatic
    private(set) var isDragging = false
    private(set) var isAvailable = false
    private(set) var readyApps: Set<NotchDropApp> = []
    private(set) var lastError: String?
    private(set) var legacyPeer: NotchDropApp?
    private(set) var activeGeneration: Int?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var peer: NotchDropPeer
    @ObservationIgnored private var state = NotchDropState()
    @ObservationIgnored private let store: NotchDropDiskStore
    @ObservationIgnored private let queue = DispatchQueue(label: "com.maclife.notch-drop.routing", qos: .userInitiated)
    @ObservationIgnored private let automaticEvents: Bool
    @ObservationIgnored private var desiredDisplays: [UInt32] = []
    @ObservationIgnored private var legacyDisplays: Set<UInt32> = []
    @ObservationIgnored private var legacyScan = UUID()
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var pressGeneration: Int?
    @ObservationIgnored private var consumed: Set<Int> = []
    @ObservationIgnored private var revoked: Set<Int> = []
    @ObservationIgnored private var endTask: Task<Void, Never>?

    init(app: NotchDropApp, store: NotchDropDiskStore? = nil, instance: UUID = UUID(), automaticEvents: Bool = true) {
        self.app = app
        self.automaticEvents = automaticEvents
        peer = .init(app: app, instance: instance, pid: getpid(),
                     launched: NSRunningApplication.current.launchDate?.timeIntervalSince1970 ?? 0, displays: [])
        if let store { self.store = store }
        else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacLife/NotchDropBridge", isDirectory: true)
            var size = 0
            sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
            var bytes = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0)
            let epoch = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            self.store = NotchDropDiskStore(directory: directory, epoch: epoch, isAlive: Self.authenticatedPeer)
        }
    }

    nonisolated private static func authenticatedPeer(_ peer: NotchDropPeer) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: peer.pid), !running.isTerminated,
              running.bundleIdentifier == peer.app.bundleID,
              let launched = running.launchDate?.timeIntervalSince1970,
              abs(launched - peer.launched) < 0.001 else { return false }
        let cacheKey = "\(peer.pid):\(peer.launched):\(peer.app.bundleID)"
        if NotchDropSignatureCache.shared.contains(cacheKey) { return true }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: peer.pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"CF5PGH3KGK\" and identifier \"\(peer.app.bundleID)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        NotchDropSignatureCache.shared.insert(cacheKey)
        return true
    }

    func start(displays: [UInt32]) {
        guard !started else { updateDisplays(displays); return }
        started = true
        desiredDisplays = displays.sorted()
        if automaticEvents {
            // Do not advertise a physical target before the initial peer
            // capability check. File I/O itself stays on the private queue.
            legacyDisplays = Self.physicalDisplays()
        }
        refreshLegacyPeer()
        peer.displays = desiredDisplays.filter { !legacyDisplays.contains($0) }
        if automaticEvents {
            let distributed = DistributedNotificationCenter.default()
            distributedObserver = distributed.addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didWakeNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let changedApp = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    let woke = notification.name == NSWorkspace.didWakeNotification
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let other: NotchDropApp = self.app == .mnotch ? .mfinder : .mnotch
                        if woke || changedApp == other.bundleID {
                            self.refreshLegacyPeer()
                            self.refresh()
                        }
                    }
                })
            }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
        }
        refresh()
    }

    func updateDisplays(_ displays: [UInt32]) {
        desiredDisplays = displays.sorted()
        let displays = desiredDisplays.filter { !legacyDisplays.contains($0) }
        guard displays != peer.displays else { return }
        if !Set(peer.displays).subtracting(displays).isEmpty, let activeGeneration { revoked.insert(activeGeneration) }
        peer.displays = displays
        refresh()
    }

    func setPreference(_ value: NotchDropPreference) {
        guard started else { return }
        submit(preference: value)
    }

    func observeDrag(generation: Int) {
        guard started else { return }
        endTask?.cancel(); endTask = nil
        let changed = activeGeneration != generation || !isDragging
        isDragging = true
        guard activeGeneration != generation else { if changed { onChange?() }; return }
        activeGeneration = generation
        if consumed.count > 32 { consumed.removeAll() }
        if revoked.count > 32 { revoked.removeAll() }
        submit(generation: generation)
        onChange?()
    }

    func endDrag() {
        pressGeneration = nil
        guard endTask == nil else { return }
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.endTask = nil
            self.isDragging = false
            self.pressGeneration = nil
            self.onChange?()
        }
    }

    func isLocallyReady(display: UInt32) -> Bool { peer.displays.contains(display) }

    private static func physicalDisplays() -> Set<UInt32> {
        Set(NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
    }

    nonisolated private static func isLegacyBundle(_ url: URL) -> Bool {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let fd = open(infoURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 262144 else { return true }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == data.count,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return true }
        return (plist["MacLifeNotchDropProtocol"] as? Int) != 1
    }

    private func refreshLegacyPeer() {
        guard automaticEvents, started else { return }
        let other: NotchDropApp = app == .mnotch ? .mfinder : .mnotch
        let urls = NSRunningApplication.runningApplications(withBundleIdentifier: other.bundleID)
            .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }.compactMap(\.bundleURL)
        let scan = UUID(), token = lifetime
        legacyScan = scan
        queue.async { [weak self] in
            // Avoid CFBundle's cached Info dictionary from the app version that
            // was replaced. Bound the read and reject FIFO/device/symlink input.
            let legacy = urls.contains { Self.isLegacyBundle($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.lifetime == token, self.legacyScan == scan else { return }
                let changed = self.legacyPeer != (legacy ? other : nil)
                self.legacyPeer = legacy ? other : nil
                self.legacyDisplays = legacy ? Self.physicalDisplays() : []
                self.updateDisplays(self.desiredDisplays)
                if changed { self.onChange?() }
            }
        }
    }

    func owns(display: UInt32, generation: Int) -> Bool {
        guard started, isAvailable, peer.displays.contains(display),
              !consumed.contains(generation), !revoked.contains(generation) else { return false }
        let key = "\(store.epoch):\(generation)"
        return state.leases.first { $0.key == key }?.owners[String(display)] == .init(app: app, instance: peer.instance)
    }

    func claim(display: UInt32, generation: Int) -> Bool {
        guard owns(display: display, generation: generation) else { return false }
        consumed.insert(generation) // Before invoking a source that can re-enter AppKit.
        return true
    }

    func owner(display: UInt32) -> NotchDropApp? {
        guard isAvailable, let activeGeneration else { return nil }
        return state.leases.first { $0.key == "\(store.epoch):\(activeGeneration)" }?.owners[String(display)]?.app
    }

    func waitForTransactions() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func stop() {
        guard started else { return }
        if let activeGeneration { revoked.insert(activeGeneration) }
        started = false
        refreshInFlight = false
        refreshAgain = false
        lifetime = UUID()
        isAvailable = false
        readyApps.removeAll()
        isDragging = false
        endTask?.cancel(); endTask = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        distributedObserver = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        let store = store, peer = peer, broadcast = automaticEvents
        queue.async {
            if let (_, changed) = try? store.transaction(peer: peer, remove: true), changed, broadcast {
                DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        onChange?()
    }

    /// Uses the existing pointer sample only while a button is held. Native
    /// dragging loops can bypass the NSEvent monitors; no disk work occurs here.
    func sampleDrag(mouseButtonPressed: Bool) {
        guard started else { return }
        if !mouseButtonPressed { if isDragging { endDrag() }; return }
        guard !isDragging, let pressGeneration else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != pressGeneration, activeGeneration != board.changeCount || !isDragging else { return }
        let types = Set(board.types ?? [])
        if types.contains(.fileURL) || NSFilePromiseReceiver.readableDraggedTypes.contains(where: { types.contains(.init($0)) }) {
            observeDrag(generation: board.changeCount)
        }
    }

    private func observe(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            endTask?.cancel(); endTask = nil
            isDragging = false
            pressGeneration = NSPasteboard(name: .drag).changeCount
            onChange?()
        case .leftMouseDragged:
            let board = NSPasteboard(name: .drag)
            guard let pressGeneration, board.changeCount != pressGeneration else { return }
            let types = Set(board.types ?? [])
            if types.contains(.fileURL) || NSFilePromiseReceiver.readableDraggedTypes.contains(where: { types.contains(.init($0)) }) {
                observeDrag(generation: board.changeCount)
            }
        case .leftMouseUp: endDrag()
        default: break
        }
    }

    func refresh() {
        guard started else { return }
        if refreshInFlight { refreshAgain = true; return }
        refreshInFlight = true
        submit(refreshOnly: true)
    }

    private func finishRefresh() {
        refreshInFlight = false
        if refreshAgain { refreshAgain = false; refresh() }
    }

    private func submit(preference: NotchDropPreference? = nil, generation: Int? = nil, refreshOnly: Bool = false) {
        let store = store, peer = peer, token = lifetime, broadcast = automaticEvents
        queue.async { [weak self] in
            do {
                var result: (NotchDropState, Bool)?
                // Preserve request ordering while another process commits. The
                // bounded backoff is on this private queue, never the main run loop.
                for attempt in 0..<8 {
                    do { result = try store.transaction(peer: peer, preference: preference, generation: generation); break }
                    catch NotchDropDiskStore.StoreError.busy {
                        if attempt == 7 { throw NotchDropDiskStore.StoreError.busy }
                        usleep(useconds_t(2_000 << attempt))
                    }
                }
                guard let (state, changed) = result else { return }
                if changed && broadcast { DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil, userInfo: nil, deliverImmediately: true) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.started, self.lifetime == token else { return }
                    if refreshOnly { self.finishRefresh() }
                    self.state = state
                    self.readyApps = Set(state.peers.values.filter { !$0.displays.isEmpty }.map(\.app))
                    self.preference = state.preference
                    self.isAvailable = true
                    self.lastError = nil
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.started, self.lifetime == token else { return }
                    if refreshOnly { self.finishRefresh() }
                    self.lastError = String(describing: error)
                    if case NotchDropDiskStore.StoreError.busy = error {
                        // A committed lease is immutable. Contention cannot
                        // revoke it or require guessing a different receiver.
                    } else { self.isAvailable = false }
                    self.onChange?()
                }
            }
        }
    }
}
