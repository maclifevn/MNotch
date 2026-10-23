import Foundation
import Darwin

/// One bounded async stream replaces one main-actor Task per readability
/// callback. Raw nonblocking reads cannot raise FileHandle's Objective-C
/// exceptions when a child/pipe disappears during teardown.
final class BoundedPipeStream: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var exceededCapacity = false

    init(capacity: Int = 32) {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    var overflowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceededCapacity
    }

    func read(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            enqueue(Data(bytes.prefix(count)))
            if closed { handle.readabilityHandler = nil }
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            closed = true
            handle.readabilityHandler = nil
            continuation.finish()
        }
    }

    /// Also used by tests without opening a live pipe.
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        guard data.count <= 16_384 else {
            exceededCapacity = true
            closed = true
            continuation.finish()
            return
        }
        enqueue(data)
    }

    private func enqueue(_ data: Data) {
        if case .dropped = continuation.yield(data) {
            exceededCapacity = true
            closed = true
            continuation.finish()
        }
    }

    func close(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        closed = true
        continuation.finish()
        try? handle.close()
    }
}
