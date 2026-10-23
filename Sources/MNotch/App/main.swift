import AppKit

// Bundle localization is chosen during application bootstrap. Apply MNotch's
// per-app override before AppKit creates NSApplication or any window/menu.
AppLanguage.applySavedOverride()

// Soak tests use a copied bundle with a unique ID and isolated support path.
// Avoid onboarding, updater/network side effects, and hook migration there.
if ProcessInfo.processInfo.environment["MNOTCH_DIAGNOSTIC_RUN"] == "1" {
    UserDefaults.standard.register(defaults: ["general.seenWelcome": true, "agent.enabled": false])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
