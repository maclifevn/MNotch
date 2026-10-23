import AppKit
import XCTest
@testable import MNotch

@MainActor
final class ThumbnailLifecycleTests: XCTestCase {
    // Task results must be Sendable on older SDKs. The image stays isolated
    // to the main actor, as it does in the production cache.
    @MainActor
    private final class ImageResult {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    @MainActor
    private final class Provider {
        var completions: [ShelfThumbnailCache.Completion] = []
        var cancellations = 0
        func start(_ url: URL, completion: @escaping ShelfThumbnailCache.Completion) -> (() -> Void) {
            completions.append(completion)
            return { [weak self] in self?.cancellations += 1 }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Thumbnail lifecycle did not settle")
    }

    func testCancellingOnePanelKeepsTheOtherPanelsSharedRequestAlive() async throws {
        let source = Provider()
        let cache = ShelfThumbnailCache(provider: { url, complete in source.start(url, completion: complete) })
        let url = URL(fileURLWithPath: "/fixture/shared.png")
        let first = Task { ImageResult(await cache.image(for: url)) }
        let second = Task { ImageResult(await cache.image(for: url)) }
        try await waitUntil { cache.pendingWaiterCount == 2 }
        XCTAssertEqual(source.completions.count, 1)
        first.cancel()
        let cancelledImage = (await first.value).image
        XCTAssertNil(cancelledImage)
        XCTAssertEqual(source.cancellations, 0)
        let image = NSImage(size: NSSize(width: 20, height: 20))
        source.completions[0](image)
        let result = (await second.value).image
        XCTAssertTrue(result === image)
        let cached = await cache.image(for: url)
        XCTAssertTrue(cached === image)
        XCTAssertEqual(source.completions.count, 1)
        XCTAssertEqual(cache.pendingRequestCount, 0)
    }

    func testLastWaiterCancellationReleasesNativeWorkAndIgnoresLateResult() async throws {
        let source = Provider()
        let cache = ShelfThumbnailCache(provider: { url, complete in source.start(url, completion: complete) })
        let url = URL(fileURLWithPath: "/fixture/recycled.png")
        let first = Task { ImageResult(await cache.image(for: url)) }
        try await waitUntil { source.completions.count == 1 }
        first.cancel()
        let cancelled = (await first.value).image
        XCTAssertNil(cancelled)
        try await waitUntil { cache.pendingRequestCount == 0 }
        XCTAssertEqual(source.cancellations, 1)
        let second = Task { ImageResult(await cache.image(for: url)) }
        try await waitUntil { source.completions.count == 2 }
        let old = NSImage(size: NSSize(width: 1, height: 1))
        source.completions[0](old)
        XCTAssertEqual(cache.pendingRequestCount, 1)
        let fresh = NSImage(size: NSSize(width: 2, height: 2))
        source.completions[1](fresh)
        let result = (await second.value).image
        XCTAssertTrue(result === fresh)
    }

    func testInvalidateDoesNotLetARecycledFilenameReuseOldArtwork() async throws {
        let source = Provider()
        let cache = ShelfThumbnailCache(provider: { url, complete in source.start(url, completion: complete) })
        let url = URL(fileURLWithPath: "/fixture/file.png")
        let first = Task { ImageResult(await cache.image(for: url)) }
        try await waitUntil { source.completions.count == 1 }
        cache.invalidate(url)
        let cancelled = (await first.value).image
        XCTAssertNil(cancelled)
        let next = Task { ImageResult(await cache.image(for: url)) }
        try await waitUntil { source.completions.count == 2 }
        source.completions[0](NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertEqual(cache.pendingRequestCount, 1)
        source.completions[1](nil)
        let result = (await next.value).image
        XCTAssertNil(result)
    }

    func testStalledProviderTimesOutAndResumesItsCaller() async {
        let source = Provider()
        let cache = ShelfThumbnailCache(timeout: .milliseconds(30), provider: { url, complete in source.start(url, completion: complete) })
        let result = await cache.image(for: URL(fileURLWithPath: "/fixture/stalled.png"))
        XCTAssertNil(result)
        XCTAssertEqual(source.cancellations, 1)
        XCTAssertEqual(cache.pendingRequestCount, 0)
        source.completions[0](NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertEqual(cache.pendingRequestCount, 0)
    }

    func testConcurrencyAndQueueStayBoundedAcross100CancelledViews() async throws {
        let source = Provider()
        let cache = ShelfThumbnailCache(concurrencyLimit: 3, requestLimit: 100,
                                        provider: { url, complete in source.start(url, completion: complete) })
        let tasks = (0..<100).map { index in
            Task { ImageResult(await cache.image(for: URL(fileURLWithPath: "/fixture/\(index).png"))) }
        }
        try await waitUntil { cache.pendingRequestCount == 100 }
        XCTAssertEqual(cache.activeRequestCount, 3)
        XCTAssertEqual(source.completions.count, 3)
        let overflow = await cache.image(for: URL(fileURLWithPath: "/fixture/overflow.png"))
        XCTAssertNil(overflow)
        XCTAssertEqual(cache.pendingRequestCount, 100)
        for task in tasks { task.cancel() }
        for task in tasks {
            let result = (await task.value).image
            XCTAssertNil(result)
        }
        try await waitUntil { cache.pendingRequestCount == 0 }
        XCTAssertEqual(cache.activeRequestCount, 0)
        for completion in source.completions { completion(nil) }
        XCTAssertEqual(cache.pendingRequestCount, 0)
    }

    func testSynchronousProviderCompletionDoesNotReenterTheQueue() async {
        let cache = ShelfThumbnailCache(provider: { _, complete in
            complete(NSImage(size: NSSize(width: 1, height: 1)))
            return {}
        })
        let result = await cache.image(for: URL(fileURLWithPath: "/fixture/immediate.png"))
        XCTAssertNotNil(result)
        XCTAssertEqual(cache.pendingRequestCount, 0)
        XCTAssertEqual(cache.activeRequestCount, 0)
    }

    func testNativeProviderProducesAThumbnailForALocalPNG() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appending(path: "local.png")
        try data.write(to: url)
        let cache = ShelfThumbnailCache()
        let image = await cache.image(for: url)
        XCTAssertNotNil(image)
        XCTAssertEqual(cache.pendingRequestCount, 0)
        cache.invalidate(url)
    }
}
