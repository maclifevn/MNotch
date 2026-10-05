import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MNOTCH_SUPPORT_DIRECTORY"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MNotch", directoryHint: .isDirectory)
    }
}
