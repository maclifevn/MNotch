import AppKit

/// Nonmodal: File Tray continuations must keep running while the user waits.
@MainActor
final class UpdateWaitWindowController: NSWindowController, NSWindowDelegate {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 150),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.string("Preparing Update")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let message = NSTextField(wrappingLabelWithString: L10n.string(
            "Waiting for File Tray to finish copying or dragging files. New file operations are paused until the update starts."
        ))
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.startAnimation(nil)
        let cancel = NSButton(title: L10n.string("Cancel Update"), target: self, action: #selector(cancelUpdate))
        let stack = NSStackView(views: [message, progress, cancel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        }
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    @objc private func cancelUpdate() { onCancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel(); return true }
}
