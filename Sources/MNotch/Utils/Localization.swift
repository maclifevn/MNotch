import AppKit

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case vietnamese = "vi"

    static let preferenceKey = "general.language"

    var displayName: String {
        switch self {
        case .system: L10n.string("System Language")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    static func resolvedPreference(from storedRawValue: String?) -> AppLanguage {
        storedRawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// AppleLanguages in this app's defaults domain overrides localization for
    /// MNotch only. It does not modify the user's global macOS language order.
    static func applySavedOverride() {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        applyOverride(resolvedPreference(from: raw))
    }

    static func applyOverride(_ language: AppLanguage) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .vietnamese:
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        // The app terminates immediately after the restart request succeeds;
        // flush the language domain first so the replacement instance sees it.
        UserDefaults.standard.synchronize()
    }
}

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}

enum AppLanguageRestartPolicy {
    static func requiresRestart(selected: AppLanguage, launched: AppLanguage) -> Bool {
        selected != launched
    }
}

@MainActor
enum ApplicationRestart {
    private static var isRestarting = false

    static func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    isRestarting = false
                    mnotchLog.error("MNotch restart failed: \(error)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
