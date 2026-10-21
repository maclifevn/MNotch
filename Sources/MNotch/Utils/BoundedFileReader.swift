import Foundation
import Darwin

enum BoundedFileReader {
    enum ReadError: Error { case notRegular, tooLarge }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit > 0, limit < Int.max else { throw ReadError.notRegular }
        // Inspect the opened descriptor, rather than checking a path and then
        // reopening it. O_NONBLOCK also makes an unexpected FIFO fail safely.
        // Follow ordinary symlinks: dotfile managers commonly use them.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? reader.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ReadError.notRegular }
        guard metadata.st_size <= limit else { throw ReadError.tooLarge }
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ReadError.tooLarge }
        return data
    }
}
