#if DEBUG
import AppKit
import SwiftUI

/// Explicitly enabled test hooks: `mnotch.debug.dump` logs metadata only,
/// `mnotch.debug.settings` opens the settings window. Driven from the CLI
/// via DistributedNotificationCenter for headless verification.
@MainActor
enum DebugProbe {
    static func install(controller: NotchWindowController) {
        guard ProcessInfo.processInfo.environment["MNOTCH_ENABLE_DEBUG_PROBES"] == "1" else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.dump"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in dump(controller: controller) }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.settings"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in SettingsWindowController.shared.show() }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.agent-approve"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let agents = AppServices.shared.agents
                guard let s = agents.firstPending else { return }
                // Mirror AgentRequestCard.resolve so the confirm pill fires.
                if agents.pendingCount <= 1,
                   let vm = controller.debugViewModels.first {
                    vm.confirmAgentDecision(approved: true)
                }
                agents.approve(s)
            }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.agent-reject"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if let s = AppServices.shared.agents.firstPending {
                    AppServices.shared.agents.reject(s)
                }
            }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.agent-tab"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                controller.debugViewModels.first?.selectTab(.agent)
            }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.welcome"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in WelcomeWindowController.shared.show() }
        }
    }

    private static func dump(controller: NotchWindowController) {
        guard let data = try? AppDiagnostics.encode(AppDiagnostics.report()),
              let json = String(data: data, encoding: .utf8) else { return }
        mnotchLog.notice("DUMP \(json, privacy: .public)")
    }
}
#endif
