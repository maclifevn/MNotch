import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Shelf tab: horizontal strip of dropped files, drag-out enabled, AirDrop.
struct ShelfView: View {
    let viewModel: NotchViewModel
    let shelf = ShelfStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfItemView(url: url) {
                                shelf.remove(url)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                HStack {
                    Button {
                        shelf.airDrop(shelf.items)
                    } label: {
                        Label("AirDrop", systemImage: "airplane.circle.fill")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ShelfItemView: View {
    let url: URL
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
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if hovering {
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
        .onDrag {
            NSItemProvider(object: url as NSURL)
        }
        .task(id: url) {
            thumbnail = await Self.thumbnail(for: url)
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 104, height: 104),
            scale: 2,
            representationTypes: .thumbnail
        )
        let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return generated?.nsImage
    }
}
