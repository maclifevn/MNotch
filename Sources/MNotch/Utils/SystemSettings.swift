import AppKit

/// Deep links into the System Settings privacy panes MNotch guides users to.
enum SystemSettings {
    enum Pane: String {
        case fullDiskAccess = "Privacy_AllFiles"
        case calendars = "Privacy_Calendars"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension NSWorkspace {
    /// Human-readable name of the app owning `bundleID` (the bundle id itself
    /// when it isn't installed).
    func appDisplayName(forBundleID bundleID: String) -> String {
        guard let url = urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
