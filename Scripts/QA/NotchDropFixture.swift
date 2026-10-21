import AppKit
import CryptoKit

private let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : Bundle.main.object(forInfoDictionaryKey: "NotchDropQARoot") as! String, isDirectory: true)
private let basePayload = Data((String(repeating: "Notch coexistence QA — preserve original bytes.\n", count: 64)).utf8)

private func payload(_ name: String) -> Data { Data((name + "\n").utf8) + basePayload }
private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

private let recordLock = NSLock()

private func record(_ value: [String: Any]) {
    recordLock.lock(); defer { recordLock.unlock() }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    let path = fixtureRoot.appendingPathComponent("native-events.jsonl")
    if !FileManager.default.fileExists(atPath: path.path) { _ = FileManager.default.createFile(atPath: path.path, contents: nil) }
    if let file = try? FileHandle(forWritingTo: path) {
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data + Data([10])); try? file.close()
    }
}

@MainActor
private func peerWindows() -> [[String: Any]] {
    var peers: [Int: String] = [:]
    for (id, name) in [("com.mnotch.app", "mnotch"), ("com.maclife.mfinder", "mfinder")] {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.activationPolicy != .prohibited {
            peers[Int(app.processIdentifier)] = name
        }
    }
    return ((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { info in
        guard let pid = info[kCGWindowOwnerPID as String] as? Int, let app = peers[pid],
              let layer = info[kCGWindowLayer as String] as? Int, layer >= 25,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              (bounds["Width"] as? Double ?? 0) > 100 else { return nil }
        return ["app": app, "pid": pid, "layer": layer, "alpha": info[kCGWindowAlpha as String] ?? -1, "bounds": bounds]
    }
}

@MainActor
private final class DragSource: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    let promises: Bool
    let names: [String]
    init(frame: NSRect, promises: Bool) {
        self.promises = promises
        names = promises ? ["NotchCoexist-Promise-A.txt", "NotchCoexist-Promise-B.txt"] : ["NotchCoexist-URL-A.txt", "NotchCoexist-URL-B.txt"]
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = (promises ? NSColor.systemPurple : NSColor.systemBlue).cgColor
        layer?.cornerRadius = 14
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(promises ? "notchQA.promiseSource" : "notchQA.urlSource")
        setAccessibilityLabel(promises ? "Drag two FILE PROMISES to the notch" : "Drag two FILE URLs to the notch")
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ((promises ? "Drag two FILE PROMISES to the notch" : "Drag two FILE URLs to the notch") as NSString)
            .draw(at: NSPoint(x: 18, y: 44), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) {
        // App-scoped UI tools can synthesize clicks without a global button
        // press. Those must not leave an AppKit drag tracking loop behind.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        record(["event": "drag-start", "promises": promises, "screenX": screenPoint.x, "screenY": screenPoint.y,
                "fullscreen": window?.styleMask.contains(.fullScreen) == true,
                "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "onActiveSpace": window?.isOnActiveSpace == true, "peerWindows": peerWindows(),
                "actualPointerX": NSEvent.mouseLocation.x, "actualPointerY": NSEvent.mouseLocation.y,
                "pressedButtons": NSEvent.pressedMouseButtons])
        let location = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = names.map { name in
            let writer: any NSPasteboardWriting
            if promises {
                let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: self)
                provider.userInfo = name; writer = provider
            } else { writer = fixtureRoot.appendingPathComponent(name) as NSURL }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = NSImage(size: NSSize(width: 100, height: 48), flipped: false) { bounds in
                NSColor.black.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
                ("QA FILE" as NSString).draw(at: NSPoint(x: 18, y: 16), withAttributes: [.foregroundColor: NSColor.white])
                return true
            }
            item.setDraggingFrame(NSRect(x: location.x, y: location.y, width: 100, height: 48), contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            record(["event": "settled", "fullscreen": self.window?.styleMask.contains(.fullScreen) == true,
                    "onActiveSpace": self.window?.isOnActiveSpace == true,
                    "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none", "peerWindows": peerWindows()])
        }
        record(["event": "drag-ended", "promises": promises, "operation": operation.rawValue,
                "pasteboardGeneration": session.draggingPasteboard.changeCount, "screenX": screenPoint.x, "screenY": screenPoint.y, "names": names,
                "fullscreen": window?.styleMask.contains(.fullScreen) == true,
                "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "onActiveSpace": window?.isOnActiveSpace == true, "peerWindows": peerWindows(),
                "actualPointerX": NSEvent.mouseLocation.x, "actualPointerY": NSEvent.mouseLocation.y,
                "pressedButtons": NSEvent.pressedMouseButtons])
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filePromiseProvider.userInfo as! String
    }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping (Error?) -> Void) {
        do {
            let name = filePromiseProvider.userInfo as? String ?? url.lastPathComponent
            let bytes = payload(name)
            try bytes.write(to: url)
            record(["event": "promise-written", "path": url.path, "bytes": bytes.count, "sourceName": name, "sha256": sha(bytes)])
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let names = ["NotchCoexist-URL-A.txt", "NotchCoexist-URL-B.txt", "NotchCoexist-Promise-A.txt", "NotchCoexist-Promise-B.txt"]
        var hashes: [String: String] = [:]
        for name in names {
            let bytes = payload(name)
            try! bytes.write(to: fixtureRoot.appendingPathComponent(name))
            hashes[name] = sha(bytes)
        }
        try! JSONEncoder().encode(hashes).write(to: fixtureRoot.appendingPathComponent("expected-hashes.json"))
        window = NSWindow(contentRect: NSRect(x: 400, y: 260, width: 600, height: 380),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notch Drop Coexistence QA"
        window.collectionBehavior = [.fullScreenPrimary]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
        let text = NSTextField(labelWithString: "Disposable QA files — originals must stay intact")
        text.frame = NSRect(x: 24, y: 325, width: 385, height: 25); root.addSubview(text)
        let activate = NSButton(title: "Activate fixture", target: self, action: #selector(activateFixture))
        activate.frame = NSRect(x: 422, y: 322, width: 155, height: 30)
        root.addSubview(activate)
        root.addSubview(DragSource(frame: NSRect(x: 24, y: 182, width: 552, height: 110), promises: false))
        root.addSubview(DragSource(frame: NSRect(x: 24, y: 40, width: 552, height: 110), promises: true))
        window.contentView = root
        let main = NSMenu()
        let item = NSMenuItem(); main.addItem(item)
        item.submenu = NSMenu()
        item.submenu?.addItem(withTitle: "Quit Notch QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func activateFixture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let window = self?.window {
                record(["event": "activated", "windowFrame": NSStringFromRect(window.frame),
                        "screenFrame": NSStringFromRect(window.screen?.frame ?? .zero),
                        "fullscreen": window.styleMask.contains(.fullScreen), "onActiveSpace": window.isOnActiveSpace,
                        "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"])
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
private let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
