import Foundation

enum BoundedFileReader {
    enum ReadError: Error { case notRegular, tooLarge }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard limit > 0, limit < Int.max,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw ReadError.notRegular }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ReadError.tooLarge }
        return data
    }
}
