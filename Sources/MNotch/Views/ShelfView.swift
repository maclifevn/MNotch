// QuickLookThumbnailing lacks Sendable annotations on SDKs before macOS 26,
// where returning a thumbnail across the actor boundary is a hard error.
@preconcurrency import QuickLookThumbnailing
@preconcurrency import QuickLookUI
import SwiftUI

@MainActor
private final class ShelfThumbnailCache {
    static let shared = ShelfThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var requests: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 80 * 104 * 104 * 4
    }

    /// Drop a cached thumbnail when its file leaves the shelf. The shelf reuses
    /// a freed filename for the next same-named drop, so without this a re-added
    /// file would render the trashed file's stale preview.
    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        requests[url]?.cancel()
        requests[url] = nil
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let request = requests[url] { return await request.value }

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
        requests[url] = request
        let image = await request.value
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
    @State private var selection: Set<URL> = []

    private var actionItems: [URL] {
        selection.isEmpty ? shelf.items : shelf.items.filter(selection.contains)
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
                                selected: selection.contains(url),
                                onSelect: { toggleSelection(url) },
                                onPreview: { preview(url) },
                                onOpen: { NSWorkspace.shared.open(url) },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                },
                                onAirDrop: { shelf.airDrop([url]) },
                                onRemove: {
                                    selection.remove(url)
                                    shelf.remove(url)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
                HStack {
                    if !selection.isEmpty {
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
                            selection.isEmpty ? "AirDrop" : "AirDrop \(selection.count)",
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
            selection.formIntersection(items)
            for removed in Set(old).subtracting(items) {
                ShelfThumbnailCache.shared.invalidate(removed)
            }
            ShelfQuickLookController.shared.itemsChanged(items)
        }
    }

    private func toggleSelection(_ url: URL) {
        if selection.contains(url) {
            selection.remove(url)
        } else {
            selection.insert(url)
        }
    }

    private func preview(_ initial: URL) {
        let urls = selection.contains(initial) ? actionItems : shelf.items
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
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 4, y: -4)
                } else if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }

            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 56)
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(count: 1, perform: onSelect)
        .onDrag {
            NSItemProvider(object: url as NSURL)
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
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAction(named: "Quick Look", onPreview)
        .task(id: url) {
            thumbnail = await ShelfThumbnailCache.shared.image(for: url)
        }
    }
}
