import AppKit

/// NSWorkspace resolves application icons through LaunchServices and disk.
/// SwiftUI bodies can run often (especially the media timeline), so cache the
/// immutable result by bundle identifier instead of repeating that lookup.
@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let icons = NSCache<NSString, NSImage>()
    private let names = NSCache<NSString, NSString>()

    private init() {
        icons.countLimit = 48
        names.countLimit = 48
    }

    func icon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = icons.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: key)
        return icon
    }

    func displayName(for bundleID: String) -> String {
        let key = bundleID as NSString
        if let cached = names.object(forKey: key) { return cached as String }
        let name = NSWorkspace.shared.appDisplayName(forBundleID: bundleID)
        names.setObject(name as NSString, forKey: key)
        return name
    }
}
