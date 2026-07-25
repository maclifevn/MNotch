import AppKit

// Bundle localization is chosen during application bootstrap. Apply MNotch's
// per-app override before AppKit creates NSApplication or any window/menu.
AppLanguage.applySavedOverride()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
