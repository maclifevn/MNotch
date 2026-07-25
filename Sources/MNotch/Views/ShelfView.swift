// QuickLookThumbnailing lacks Sendable annotations on SDKs before macOS 26,
// where returning a thumbnail across the actor boundary is a hard error.
@preconcurrency import QuickLookThumbnailing
@preconcurrency import QuickLookUI
import AppKit
import SwiftUI

/// Resolves Finder-style drag semantics independently of the UI framework:
/// dragging a selected item carries the whole selection; dragging an item that
/// is not selected carries only that item. Preserve tray order for predictable
/// file ordering in Finder, browsers and upload targets.
enum ShelfDragSelection {
    static func urls(
        dragged: URL,
        selection: Set<URL>,
        available: [URL]
    ) -> [URL] {
        guard selection.contains(dragged) else { return [dragged] }
        let selected = available.filter(selection.contains)
        return selected.isEmpty ? [dragged] : selected
    }
}

/// Process-local guard distinguishing a drag emitted by File Tray from an
/// external file drag entering MNotch. AppKit's destination callbacks do not
/// otherwise tell the shelf that the URLs originated from itself.
@MainActor
enum ShelfOutgoingDragState {
    private(set) static var isActive = false

    static func begin() { isActive = true }
    static func end() { isActive = false }
}

enum ShelfDropPolicy {
    static func accepts(featureEnabled: Bool, outgoingShelfDrag: Bool) -> Bool {
        featureEnabled && !outgoingShelfDrag
    }
}

enum ShelfDragCompletionPolicy {
    static func shouldClear(settingEnabled: Bool, operationSucceeded: Bool) -> Bool {
        settingEnabled && operationSucceeded
    }
}

@MainActor
private final class ShelfThumbnailCache {
    static let shared = ShelfThumbnailCache()

    private struct PendingRequest {
        let id: UUID
        let task: Task<NSImage?, Never>
    }

    private let cache = NSCache<NSURL, NSImage>()
    private var requests: [URL: PendingRequest] = [:]

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 80 * 104 * 104 * 4
    }

    /// Drop a cached thumbnail when its file leaves the shelf. The shelf reuses
    /// a freed filename for the next same-named drop, so without this a re-added
    /// file would render the trashed file's stale preview.
    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        requests[url]?.task.cancel()
        requests[url] = nil
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let request = requests[url] { return await request.task.value }

        let id = UUID()
        let request = Task { @MainActor in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 104, height: 104),
                scale: 2,
                representationTypes: .thumbnail
            )
            return try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).nsImage
        }
        requests[url] = PendingRequest(id: id, task: request)
        let image = await request.value
        // invalidate() or a new request for the same recycled path won the
        // race. The old thumbnail must not clear/cache over that generation.
        guard requests[url]?.id == id, !request.isCancelled else { return nil }
        requests[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: 104 * 104 * 4)
        }
        return image
    }
}

@MainActor
private final class ShelfQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = ShelfQuickLookController()
    private var urls: [URL] = []

    func show(urls: [URL], initial: URL) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.currentPreviewItemIndex = urls.firstIndex(of: initial) ?? 0
        panel.reloadData()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keep an open preview panel in sync when items leave the shelf, so arrow
    /// keys never page onto a trashed file. Closes the panel if nothing is left.
    func itemsChanged(_ available: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self else { return }
        let currentURL = urls.indices.contains(panel.currentPreviewItemIndex)
            ? urls[panel.currentPreviewItemIndex] : nil
        let filtered = urls.filter(available.contains)
        guard !filtered.isEmpty else {
            urls = []
            panel.orderOut(nil)
            return
        }
        urls = filtered
        panel.reloadData()
        panel.currentPreviewItemIndex = currentURL.flatMap(filtered.firstIndex(of:)) ?? 0
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

/// Shelf tab: horizontal strip of dropped files, drag-out enabled, AirDrop.
struct ShelfView: View {
    let viewModel: NotchViewModel
    let shelf = ShelfStore.shared

    private var actionItems: [URL] {
        shelf.selection.isEmpty ? shelf.items : shelf.selectedItems
    }

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfItemView(
                                url: url,
                                selected: shelf.selection.contains(url),
                                onSelect: { shelf.toggleSelection(url) },
                                onPreview: { preview(url) },
                                onOpen: { NSWorkspace.shared.open(url) },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                },
                                onAirDrop: { shelf.airDrop([url]) },
                                dragURLs: ShelfDragSelection.urls(
                                    dragged: url,
                                    selection: shelf.selection,
                                    available: shelf.items
                                ),
                                onDragBegan: {
                                    shelf.selectForDrag(url)
                                },
                                onRemove: {
                                    shelf.remove(url)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
                HStack {
                    if !shelf.selection.isEmpty {
                        Button {
                            if let first = actionItems.first { preview(first) }
                        } label: {
                            Label("Preview", systemImage: "eye.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    Button {
                        shelf.airDrop(actionItems)
                    } label: {
                        Label(
                            shelf.selection.isEmpty
                                ? "AirDrop" : "AirDrop \(shelf.selection.count)",
                            systemImage: "airplane.circle.fill"
                        )
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        shelf.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.top, viewModel.geometry.notchHeight + 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if shelf.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 8)
            } else if let error = shelf.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
        }
        .onChange(of: shelf.items) { old, items in
            for removed in Set(old).subtracting(items) {
                ShelfThumbnailCache.shared.invalidate(removed)
            }
            ShelfQuickLookController.shared.itemsChanged(items)
        }
    }

    private func preview(_ initial: URL) {
        let urls = shelf.selection.contains(initial) ? actionItems : shelf.items
        ShelfQuickLookController.shared.show(urls: urls, initial: initial)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.35))
            Text("Drop files here")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
    }
}

struct ShelfItemView: View {
    let url: URL
    let selected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onAirDrop: () -> Void
    let dragURLs: [URL]
    let onDragBegan: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.1))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 52, height: 52)
            // Clip the fill-cropped thumbnail to the tile so a wide (landscape)
            // image can't overflow its 52pt slot and overlap its neighbours.
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selected ? Color.accentColor : .white.opacity(hovering ? 0.18 : 0),
                        lineWidth: selected ? 2 : 1
                    )
            }
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                        .allowsHitTesting(false)
                }
            }
            // SwiftUI's onDrag creates exactly one NSItemProvider for the tile,
            // even when several tray items are selected. Back this tile with a
            // native drag source so the session publishes one pasteboard item
            // per selected URL — required by Finder and browser upload targets.
            .overlay {
                ShelfFileDragSource(
                    urls: dragURLs,
                    previewURL: url,
                    onSingleClick: onSelect,
                    onDoubleClick: onOpen,
                    onDragBegan: onDragBegan,
                    onHoverChanged: { hovering = $0 }
                )
            }

            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 56)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onOpen)
                .onTapGesture(count: 1, perform: onSelect)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.82), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from File Tray")
                .accessibilityLabel(String(
                    format: L10n.string("Remove %@"),
                    url.lastPathComponent
                ))
                .padding(.top, 1)
                .padding(.trailing, 2)
            }
        }
        .contextMenu {
            Button("Quick Look", systemImage: "eye", action: onPreview)
            Button("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            Button("Show in Finder", systemImage: "folder", action: onReveal)
            Divider()
            Button("AirDrop", systemImage: "airplane.circle", action: onAirDrop)
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityValue(
            selected ? L10n.string("Selected") : L10n.string("Not selected")
        )
        .accessibilityAction(named: "Quick Look", onPreview)
        .task(id: url) {
            thumbnail = await ShelfThumbnailCache.shared.image(for: url)
        }
    }
}

/// NSViewRepresentable bridge for a real multi-item AppKit drag session.
/// NSURL is an NSPasteboardWriting file URL, so every selected file becomes a
/// distinct pasteboard item rather than one opaque aggregate provider.
private struct ShelfFileDragSource: NSViewRepresentable {
    let urls: [URL]
    let previewURL: URL
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onDragBegan: () -> Void
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfFileDragSourceView {
        ShelfFileDragSourceView()
    }

    func updateNSView(_ view: ShelfFileDragSourceView, context: Context) {
        view.urls = urls
        view.previewURL = previewURL
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onDragBegan = onDragBegan
        view.onHoverChanged = onHoverChanged
    }
}

@MainActor
private final class ShelfFileDragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var previewURL: URL?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var mouseDownPoint: CGPoint?
    private var dragging = false
    private var activeDragURLs: [URL] = []
    private var trackingAreaRef: NSTrackingArea?
    private weak var activePanel: NotchPanel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    /// Own only the primary-button gesture. Let SwiftUI underneath continue to
    /// receive right-click context menus and scroll-wheel events while the
    /// pointer happens to be over a thumbnail.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, nil:
            return self
        default:
            return nil
        }
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }

        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        dragging = true
        activeDragURLs = existing
        onDragBegan?()
        ShelfOutgoingDragState.begin()

        let draggingItems = existing.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            icon.size = CGSize(width: 48, height: 48)
            item.setDraggingFrame(
                CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                contents: icon
            )
            return item
        }
        let sourcePanel = window as? NotchPanel
        activePanel = sourcePanel
        let session = beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        // The fixed panel is 700×448 even though most of it is transparent. If
        // it remains an active destination, it sits above Finder/browser drop
        // targets and receives its own URLs back. Let the WindowServer route
        // the native drag through the panel until this session ends.
        sourcePanel?.setOutgoingDragActive(true)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = existing.count > 1 ? .pile : .none
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            dragging = false
        }
        guard !dragging else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let completedURLs = activeDragURLs
        let shouldClear = ShelfDragCompletionPolicy.shouldClear(
            settingEnabled: SettingsStore.shared.shelfClearAfterDrag,
            operationSucceeded: operation != []
        )
        ShelfOutgoingDragState.end()
        activePanel?.setOutgoingDragActive(false)
        activePanel = nil
        activeDragURLs = []
        mouseDownPoint = nil
        dragging = false
        if shouldClear {
            ShelfStore.shared.dismissAfterSuccessfulDrag(completedURLs)
        }
    }
}
