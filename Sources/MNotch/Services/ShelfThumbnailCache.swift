@preconcurrency import QuickLookThumbnailing
import AppKit

/// Shared across panels. Every caller owns a cancellable waiter; closing the
/// last view cancels the native request too. Late callbacks never revive it.
@MainActor
final class ShelfThumbnailCache {
    typealias Completion = @MainActor (NSImage?) -> Void
    typealias Provider = @MainActor (URL, @escaping Completion) -> (() -> Void)

    static let shared = ShelfThumbnailCache()
    // Older SDKs explicitly mark NSImage non-Sendable. Keep the image behind
    // an actor-isolated reference when resuming an async continuation.
    @MainActor
    private final class ImageResult {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private final class Request {
        let id = UUID()
        var waiters: [UUID: CheckedContinuation<ImageResult, Never>] = [:]
        var cancel: (() -> Void)?
        var timeout: Task<Void, Never>?
        var started = false
    }

    private let cache = NSCache<NSURL, NSImage>()
    private var requests: [URL: Request] = [:]
    private var queue: [URL] = []
    private let provider: Provider
    private let timeout: Duration
    private let concurrencyLimit: Int
    private let requestLimit: Int
    private var draining = false

    init(concurrencyLimit: Int = 4, requestLimit: Int = 100,
         timeout: Duration = .seconds(15), provider: Provider? = nil) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.requestLimit = max(1, requestLimit)
        self.timeout = timeout
        self.provider = provider ?? Self.nativeThumbnail
        cache.countLimit = 80
        cache.totalCostLimit = 80 * 104 * 104 * 4
    }

    var pendingRequestCount: Int { requests.count }
    var activeRequestCount: Int { requests.values.filter(\.started).count }
    var pendingWaiterCount: Int { requests.values.reduce(0) { $0 + $1.waiters.count } }

    func image(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        let waiterID = UUID()
        let result: ImageResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: ImageResult(nil)); return }
                if let request = requests[url] {
                    request.waiters[waiterID] = continuation
                } else {
                    guard requests.count < requestLimit else {
                        continuation.resume(returning: ImageResult(nil))
                        return
                    }
                    let request = Request()
                    request.waiters[waiterID] = continuation
                    requests[url] = request
                    queue.append(url)
                }
                drain()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID, for: url) }
        }
        return result.image
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        guard let request = requests[url] else { return }
        finish(url, id: request.id, image: nil, cancel: true)
    }

    private func cancelWaiter(_ waiterID: UUID, for url: URL) {
        guard let request = requests[url],
              let waiter = request.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: ImageResult(nil))
        if request.waiters.isEmpty { finish(url, id: request.id, image: nil, cancel: true) }
    }

    private func drain() {
        // Providers may finish synchronously (including test fixtures). Do not
        // recursively drain a hundred queued entries on the same stack.
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while activeRequestCount < concurrencyLimit, !queue.isEmpty {
            let url = queue.removeFirst()
            guard let request = requests[url], !request.started else { continue }
            request.started = true
            let id = request.id
            request.timeout = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(url, id: id, image: nil, cancel: true)
            }
            let cancel = provider(url) { [weak self] image in
                self?.finish(url, id: id, image: image, cancel: false)
            }
            if requests[url]?.id == id { request.cancel = cancel }
            else { cancel() }
        }
    }

    private func finish(_ url: URL, id: UUID, image: NSImage?, cancel: Bool) {
        guard let request = requests[url], request.id == id else { return }
        requests[url] = nil
        queue.removeAll { $0 == url }
        request.timeout?.cancel()
        if cancel { request.cancel?() }
        if let image { cache.setObject(image, forKey: url as NSURL, cost: 208 * 208 * 4) }
        let result = ImageResult(image)
        for waiter in request.waiters.values { waiter.resume(returning: result) }
        request.waiters.removeAll()
        drain()
    }

    private static func nativeThumbnail(_ url: URL, completion: @escaping Completion) -> (() -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 104, height: 104),
            scale: 2, representationTypes: .thumbnail
        )
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let image = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).nsImage
            guard !Task.isCancelled else { return }
            completion(image)
        }
        return {
            task.cancel()
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}
