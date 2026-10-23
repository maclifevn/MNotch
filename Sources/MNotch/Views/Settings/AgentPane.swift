import AppKit
import Combine
import SwiftUI

/// Settings → Agents: monitor AI coding agents from the notch. Installing the
/// hooks writes MNotch's relay into each agent's user config (reversible).
struct AgentPane: View {
    @Bindable var settings = SettingsStore.shared
    @State private var claudeHooksInstalled = ClaudeHookInstaller.isInstalled
    @State private var codexHooksInstalled = CodexHookInstaller.isInstalled
    @State private var errorMessage: String?
    @State private var checkingClaudeCLI = false
    @State private var claudeCLIInstalled: Bool?   // nil = still checking
    @State private var claudeDesktopAvailable = false
    @State private var connectingClaude = false
    @State private var claudeConnectionMessage: String?

    private let claudeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.agentEnabled) {
                    Label("Agent Monitor", systemImage: "terminal.fill")
                }
                Text("Monitor AI coding agents, approve permission requests, and jump to their terminal — right from the notch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Claude Code") {
                LabeledContent("Hooks") {
                    Text(
                        claudeHooksInstalled
                            ? L10n.string("Installed") : L10n.string("Not installed")
                    )
                        .foregroundStyle(claudeHooksInstalled ? .green : .secondary)
                }
                if claudeHooksInstalled {
                    Button("Uninstall Hooks", role: .destructive) {
                        run { try ClaudeHookInstaller.uninstall() }
                    }
                } else {
                    Button("Install Hooks") {
                        run { try ClaudeHookInstaller.install() }
                    }
                }
                Text("Adds MNotch's permission and session relay to ~/.claude/settings.json. Subscription usage uses your existing Claude sign-in separately.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Claude usage") {
                Text("Uses your saved Claude sign-in to show session and weekly usage, even when Claude Code is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if claudeDesktopAvailable {
                    Button {
                        Task { await connectClaude() }
                    } label: {
                        HStack {
                            Text("Connect Claude")
                            if connectingClaude { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(connectingClaude)
                    Text("Connect once to let MNotch read Claude's saved sign-in. macOS may ask for Keychain access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Choose Always Allow in the macOS prompt to keep this connection after restarting MNotch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let claudeConnectionMessage {
                        Text(L10n.string(claudeConnectionMessage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Claude CLI (optional)") {
                    switch claudeCLIInstalled {
                    case .some(true): Text("Installed").foregroundStyle(.green)
                    case .some(false): Text("Not found").foregroundStyle(.orange)
                    case .none: Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                if claudeCLIInstalled == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You can also install and sign in to the Claude CLI to provide subscription usage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("1. Run this in Terminal to install:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(claudeInstallCommand)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(claudeInstallCommand, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy install command")
                        }
                        Text("2. Then run `claude` in Terminal and sign in. Usage appears within a few minutes (or reopen MNotch).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("MNotch reads subscription usage without refreshing tokens or changing your Claude sign-in.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Codex") {
                LabeledContent("Approval hooks") {
                    Text(
                        codexHooksInstalled
                            ? L10n.string("Installed") : L10n.string("Not installed")
                    )
                        .foregroundStyle(codexHooksInstalled ? .green : .secondary)
                }
                if codexHooksInstalled {
                    Button("Uninstall Codex Hooks", role: .destructive) {
                        run { try CodexHookInstaller.uninstall() }
                    }
                } else {
                    Button("Install Codex Hooks") {
                        run { try CodexHookInstaller.install() }
                    }
                }
                Text("Adds PermissionRequest hooks to ~/.codex/hooks.json. After installing or changing them, open /hooks in Codex once and trust the MNotch command. Codex keeps its built-in approval prompt if MNotch is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Behaviour") {
                Toggle("Auto-open notch on permission request", isOn: $settings.agentAutoExpand)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Defer to terminal when it's active", isOn: $settings.agentDeferToTerminal)
                    Text("When on, a request whose terminal is frontmost is answered by the terminal's own prompt; the notch only pops when you've switched away. Turn off to always pop the notch.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                SoundToggleRow(
                    title: "Sound on agent events",
                    isOn: $settings.agentSound,
                    effect: .agentAttention
                )
                SliderRow(
                    title: "Status pop duration",
                    value: $settings.agentDuration,
                    range: 2...10,
                    step: 1
                ) { "\(Int($0)) s" }
            }

            Section("Live quota") {
                let quota = AppServices.shared.quota
                LabeledContent("Codex") {
                    Text(settings.agentEnabled ? quotaSummary(quota.codexQuota) : L10n.string("Agent Monitor is off"))
                        .foregroundStyle(
                            quota.codexQuota.windows.isEmpty
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.green
                        )
                }
                LabeledContent("Claude") {
                    Text(settings.agentEnabled ? quotaSummary(quota.claudeQuota) : L10n.string("Agent Monitor is off"))
                        .foregroundStyle(
                            quota.claudeQuota.windows.isEmpty
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.green
                        )
                }
                Button("Refresh Now") { quota.refresh(force: true) }
                    .disabled(!settings.agentEnabled)
                Text("Usage refreshes automatically. The last values stay visible if a provider is temporarily unavailable.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Other agents (Gemini, …)") {
                Text("Agents without a blocking permission hook can still send status notifications. Point their notify command at:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("/usr/bin/perl \(notifyPath)")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshInstallState()
            ClaudeHookInstaller.ensureNotifyHelper()
        }
        .task { await recheckClaudeCLI() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Re-check after the user tabs out to install the CLI and comes back,
            // so the status stops saying "Not found" without reopening the pane.
            Task { await recheckClaudeCLI() }
        }
        .onChange(of: settings.agentEnabled) { _, enabled in
            AppServices.shared.setAgentMonitoringEnabled(enabled)
        }
    }

    @MainActor
    private func recheckClaudeCLI() async {
        guard !checkingClaudeCLI else { return }
        checkingClaudeCLI = true
        defer { checkingClaudeCLI = false }
        // Locating the CLI can spawn a login shell — keep it off the main actor.
        let (path, desktopAvailable) = await Task.detached {
            (ClaudeUsageClient.cliPath(), ClaudeDesktopCredentials.isAvailable)
        }.value
        guard !Task.isCancelled else { return }
        claudeCLIInstalled = (path != nil)
        claudeDesktopAvailable = desktopAvailable
    }

    @MainActor
    private func connectClaude() async {
        guard !connectingClaude else { return }
        connectingClaude = true
        defer { connectingClaude = false }
        let result = await ClaudeDesktopCredentials.connect()
        guard !Task.isCancelled else { return }
        switch result {
        case .connected:
            claudeConnectionMessage = "Claude connected. Usage works while Claude Code is closed."
            AppServices.shared.quota.refresh(force: true)
        case .permissionRequired:
            claudeConnectionMessage = "Keychain access was not granted. Connect again when you are ready."
        case .signInRequired:
            claudeConnectionMessage = "Sign in to the Claude app again, then reconnect MNotch."
        case .unavailable:
            claudeConnectionMessage = "Couldn't read Claude's saved sign-in. Try connecting again."
        }
    }

    private var notifyPath: String {
        AgentServer.supportDirectory.appending(path: "mnotch-notify.pl").path
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshInstallState()
    }

    private func refreshInstallState() {
        claudeHooksInstalled = ClaudeHookInstaller.isInstalled
        codexHooksInstalled = CodexHookInstaller.isInstalled
    }

    private func quotaSummary(_ provider: ProviderQuota) -> String {
        if let primary = provider.primaryWindow {
            return String(
                format: L10n.string("%d%% left"),
                Int(primary.remainingPercent.rounded())
            )
        }
        switch provider.state {
        case .loading: return L10n.string("Connecting…")
        case .waiting(let message), .unavailable(let message):
            return L10n.string(message)
        case .live, .cached: return L10n.string("Unavailable")
        }
    }
}
