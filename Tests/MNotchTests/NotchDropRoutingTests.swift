import AppKit
import Darwin
import Testing
@testable import MNotch

private func dropPeer(_ app: NotchDropApp, displays: [UInt32]) -> NotchDropPeer {
    .init(app: app, instance: UUID(), pid: getpid(), launched: 1, displays: displays)
}

struct NotchDropPolicyTests {
    @Test func automaticPrefersFinderOnlyOnSupportedDisplays() {
        let notch = dropPeer(.mnotch, displays: [1, 2]), finder = dropPeer(.mfinder, displays: [1])
        var state = NotchDropState(peers: ["mnotch": notch, "mfinder": finder])
        state.reserve(key: "one")
        #expect(state.leases[0].owners["1"]?.instance == finder.instance)
        #expect(state.leases[0].owners["2"]?.instance == notch.instance)
    }

    @Test(arguments: NotchDropPreference.allCases)
    func explicitChoiceDoesNotLaunchOrFallback(_ preference: NotchDropPreference) {
        let notch = dropPeer(.mnotch, displays: [1])
        var state = NotchDropState(preference: preference, peers: ["mnotch": notch])
        state.reserve(key: "one")
        #expect(state.leases[0].owners["1"]?.app == ([.automatic, .mnotch].contains(preference) ? .mnotch : nil))
    }

    @Test func joiningQuittingDisablingOrChangingPreferenceCannotStealCurrentGesture() {
        let notch = dropPeer(.mnotch, displays: [1]), finder = dropPeer(.mfinder, displays: [1])
        var state = NotchDropState(peers: ["mnotch": notch])
        state.reserve(key: "one")
        let lease = state.leases[0]
        state.peers["mfinder"] = finder
        state.preference = .mfinder
        state.reserve(key: "one")
        #expect(state.leases[0] == lease)
        state.reserve(key: "two")
        #expect(state.leases[1].owners["1"]?.instance == finder.instance)
        state.peers["mfinder"] = nil
        state.preference = .automatic
        state.reserve(key: "two")
        #expect(state.leases[1].owners["1"]?.instance == finder.instance)
        state.reserve(key: "three")
        #expect(state.leases[2].owners["1"]?.instance == notch.instance)
    }

    @Test func emptyDecisionStaysEmptyAndHistoryIsBounded() {
        var state = NotchDropState()
        state.reserve(key: "one")
        state.peers["mnotch"] = dropPeer(.mnotch, displays: [1])
        state.reserve(key: "one")
        #expect(state.leases[0].owners.isEmpty)
        for i in 0..<1000 { state.reserve(key: String(i)) }
        #expect(state.leases.count == 16)
        #expect(state.leases.last?.key == "999")
    }
}

struct NotchDropDiskTests {
    private func makeStore() -> NotchDropDiskStore {
        .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent("NotchDropTests-\(UUID())"),
              epoch: "isolated-boot", isAlive: { _ in true })
    }

    @Test func independentStoresAgreeAndRestartCannotInheritAnOldClaim() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let other = NotchDropDiskStore(directory: store.directory, epoch: store.epoch, isAlive: { _ in true })
        let notch = dropPeer(.mnotch, displays: [1, 2]), finder = dropPeer(.mfinder, displays: [1])
        _ = try store.transaction(peer: notch)
        _ = try other.transaction(peer: finder)
        let (a, _) = try store.transaction(peer: notch, generation: 10)
        let (b, _) = try other.transaction(peer: finder, generation: 10)
        #expect(a.leases == b.leases)
        _ = try other.transaction(peer: finder, remove: true)
        let restarted = dropPeer(.mfinder, displays: [1])
        let (c, _) = try other.transaction(peer: restarted, generation: 10)
        #expect(c.leases == a.leases)
        #expect(c.leases[0].owners["1"]?.instance != restarted.instance)
        let (d, _) = try other.transaction(peer: restarted, generation: 11)
        #expect(d.leases.last?.owners["1"]?.instance == restarted.instance)
    }

    @Test func staleProcessIsPrunedWithoutReassigningItsGesture() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let notch = dropPeer(.mnotch, displays: [1]), finder = dropPeer(.mfinder, displays: [1])
        _ = try store.transaction(peer: notch)
        _ = try store.transaction(peer: finder, generation: 1)
        let reader = NotchDropDiskStore(directory: store.directory, epoch: store.epoch, isAlive: { $0.app != .mfinder })
        let (state, _) = try reader.transaction(peer: notch, generation: 1)
        #expect(state.peers["mfinder"] == nil)
        #expect(state.leases[0].owners["1"]?.app == .mfinder)
        let (next, _) = try reader.transaction(peer: notch, generation: 2)
        #expect(next.leases.last?.owners["1"]?.app == .mnotch)
    }

    @Test func invalidOrOversizedMetadataFailsClosedWithoutOverwriting() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let peer = dropPeer(.mnotch, displays: [1])
        _ = try store.transaction(peer: peer)
        let path = store.directory.appendingPathComponent("routing.json")
        for bytes in [Data("invalid".utf8), Data(repeating: 0, count: 65537)] {
            try bytes.write(to: path)
            #expect(throws: (any Error).self) { try store.transaction(peer: peer) }
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func unauthenticatedEndpointCannotPublishOrStartNotificationFeedback() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let peer = dropPeer(.mnotch, displays: [1])
        let blocked = NotchDropDiskStore(directory: store.directory, epoch: store.epoch, isAlive: { _ in false })
        #expect(throws: (any Error).self) { try blocked.transaction(peer: peer, generation: 1) }
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("routing.json").path))
    }

    @Test func fifoMetadataAndLockAreRejectedWithoutBlocking() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let peer = dropPeer(.mnotch, displays: [1])
        _ = try store.transaction(peer: peer)
        for name in ["routing.json", "routing.lock"] {
            let path = store.directory.appendingPathComponent(name)
            try FileManager.default.removeItem(at: path)
            #expect(mkfifo(path.path, 0o600) == 0)
            #expect(throws: (any Error).self) { try store.transaction(peer: peer) }
            try FileManager.default.removeItem(at: path)
            if name == "routing.json" { _ = try store.transaction(peer: peer) }
        }
    }

    @Test func redirectedMetadataAndBusyLockCannotBeUsed() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let peer = dropPeer(.mnotch, displays: [1])
        _ = try store.transaction(peer: peer)
        let lock = open(store.directory.appendingPathComponent("routing.lock").path, O_RDWR)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try store.transaction(peer: peer) }
        flock(lock, LOCK_UN)
        let path = store.directory.appendingPathComponent("routing.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: (any Error).self) { try store.transaction(peer: peer) }
    }
}

@MainActor @Suite(.serialized)
struct NotchDropBridgeTests {
    private func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The isolated routing transaction did not complete: \(label)")
    }

    @Test func bothReceiversAgreeSingleClaimAndNoMidDragFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDropPair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotchDropDiskStore(directory: directory, epoch: "test", isAlive: { _ in true })
        let notch = NotchDropBridge(app: .mnotch, store: store, automaticEvents: false)
        let finder = NotchDropBridge(app: .mfinder, store: store, automaticEvents: false)
        notch.start(displays: [1, 2]); finder.start(displays: [1])
        defer { notch.stop(); finder.stop() }
        try await wait("startup") { notch.isAvailable && finder.isAvailable }
        #expect(notch.isAvailable, "Notch startup error: \(notch.lastError ?? "none")")
        #expect(finder.isAvailable, "Finder startup error: \(finder.lastError ?? "none")")
        finder.observeDrag(generation: 1)
        try await wait("finder owns first gesture") { finder.owns(display: 1, generation: 1) }
        notch.observeDrag(generation: 1)
        try await wait("notch sees finder owner") { notch.owner(display: 1) == .mfinder }
        #expect(!notch.claim(display: 1, generation: 1))
        #expect(finder.claim(display: 1, generation: 1))
        #expect(!finder.claim(display: 1, generation: 1))
        finder.stop()
        await finder.waitForTransactions()
        notch.refresh()
        try await wait("notch refresh after stop") { notch.isAvailable }
        #expect(!notch.claim(display: 1, generation: 1))
        notch.observeDrag(generation: 2)
        try await wait("notch owns second gesture") { notch.owns(display: 1, generation: 2) }
        #expect(notch.claim(display: 1, generation: 2))
    }

    @Test func notificationBurstCannotQueueUnboundedDiskWorkOrStarveARealDrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDropBurst-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotchDropDiskStore(directory: directory, epoch: "test", isAlive: { _ in true })
        let bridge = NotchDropBridge(app: .mnotch, store: store, automaticEvents: false)
        bridge.start(displays: [1]); defer { bridge.stop() }
        for _ in 0..<10000 { bridge.refresh() }
        bridge.observeDrag(generation: 999)
        try await wait("real drop after notification burst") { bridge.owns(display: 1, generation: 999) }
        #expect(bridge.claim(display: 1, generation: 999))
    }

    @Test func disablingReceiverCancelsAdmissionAndReenablingWaitsForNextGesture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDropDisable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotchDropDiskStore(directory: directory, epoch: "test", isAlive: { _ in true })
        let bridge = NotchDropBridge(app: .mnotch, store: store, automaticEvents: false)
        bridge.start(displays: [1]); defer { bridge.stop() }
        bridge.observeDrag(generation: 100)
        try await wait("before disable") { bridge.owns(display: 1, generation: 100) }
        bridge.updateDisplays([])
        #expect(!bridge.claim(display: 1, generation: 100))
        bridge.updateDisplays([1])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!bridge.claim(display: 1, generation: 100))
        bridge.observeDrag(generation: 101)
        try await wait("next gesture after disable") { bridge.owns(display: 1, generation: 101) }
        #expect(bridge.claim(display: 1, generation: 101))
        bridge.observeDrag(generation: 102)
        try await wait("before stopping receiver") { bridge.owns(display: 1, generation: 102) }
        bridge.stop()
        await bridge.waitForTransactions()
        bridge.start(displays: [1])
        try await wait("receiver restarted") { bridge.isAvailable }
        #expect(!bridge.claim(display: 1, generation: 102))
        bridge.observeDrag(generation: 103)
        try await wait("new gesture after receiver restarted") { bridge.owns(display: 1, generation: 103) }
        #expect(bridge.claim(display: 1, generation: 103))
    }
}
