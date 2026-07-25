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
    @State private var claudeCLIInstalled: Bool?   // nil = still checking

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
                Text("Adds MNotch's permission and session relay to ~/.claude/settings.json. Claude usage is read separately from the local CLI.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Claude usage") {
                LabeledContent("Claude CLI") {
                    switch claudeCLIInstalled {
                    case .some(true): Text("Installed").foregroundStyle(.green)
                    case .some(false): Text("Not found").foregroundStyle(.orange)
                    case .none: Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                if claudeCLIInstalled == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude usage % is read from the local `claude` CLI. Install it, then sign in — no Keychain, no separate login for MNotch.")
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
                    Text("Usage % comes straight from the `claude` CLI (`claude -p /usage`) — no Keychain access and no extra login.")
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
                    Text(quotaSummary(quota.codexQuota))
                        .foregroundStyle(
                            quota.codexQuota.windows.isEmpty
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.green
                        )
                }
                LabeledContent("Claude") {
                    Text(quotaSummary(quota.claudeQuota))
                        .foregroundStyle(
                            quota.claudeQuota.windows.isEmpty
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.green
                        )
                }
                Button("Refresh Now") { quota.refresh(force: true) }
                Text("Codex uses the official App Server. Claude's session + weekly percentages come from the `claude` CLI (see Claude usage above).")
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
        // Locating the CLI can spawn a login shell — keep it off the main actor.
        let path = await Task.detached { ClaudeUsageClient.cliPath() }.value
        claudeCLIInstalled = (path != nil)
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
