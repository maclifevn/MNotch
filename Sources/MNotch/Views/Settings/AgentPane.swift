import AppKit
import SwiftUI

/// Settings → Agents: monitor AI coding agents from the notch. Installing the
/// hooks writes MNotch's relay into ~/.claude/settings.json (reversible).
struct AgentPane: View {
    @Bindable var settings = SettingsStore.shared
    @State private var hooksInstalled = ClaudeHookInstaller.isInstalled
    @State private var errorMessage: String?

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
                    Text(hooksInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                }
                if hooksInstalled {
                    Button("Uninstall Hooks", role: .destructive) {
                        run { try ClaudeHookInstaller.uninstall() }
                    }
                } else {
                    Button("Install Hooks") {
                        run { try ClaudeHookInstaller.install() }
                    }
                }
                Text("Adds MNotch's relay to ~/.claude/settings.json. Approve/reject permission requests from the notch; if MNotch isn't running, Claude Code falls back to the terminal prompt.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Behaviour") {
                Toggle("Auto-open notch on permission request", isOn: $settings.agentAutoExpand)
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

            Section("Other agents (Codex, Gemini, …)") {
                Text("These tools don't expose a blocking permission hook, so they can only send status notifications (not remote approval). Point their notify command at:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("/usr/bin/perl \(notifyPath)")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { hooksInstalled = ClaudeHookInstaller.isInstalled }
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
        hooksInstalled = ClaudeHookInstaller.isInstalled
    }
}
