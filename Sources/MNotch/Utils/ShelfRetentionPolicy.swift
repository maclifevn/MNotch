import Foundation

enum ShelfRetentionPolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    static func belongsToShelf(_ url: URL, directory: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path
    }

    static func deadline(_ raw: Any?, path: String, directory: URL, now: Date = .now) -> Double? {
        guard belongsToShelf(URL(fileURLWithPath: path), directory: directory),
              let value = SafeNumeric.number(raw), value >= 0,
              value <= now.timeIntervalSince1970 + interval else { return nil }
        return value
    }
}
