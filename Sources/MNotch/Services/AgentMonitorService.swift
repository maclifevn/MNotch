import AppKit
import Observation

enum AgentStatus: Equatable {
    case working
    case waiting      // needs attention (idle prompt) but no blocking request
    case done
}

/// A live agent session tracked from hook events.
struct AgentSession: Identifiable, Equatable {
    let id: String
    var kind: String           // claude / codex / gemini …
    var cwd: String
    var status: AgentStatus
    var lastMessage: String
    var terminal: TerminalLocator
    /// Set while a blocking permission request is awaiting a decision.
    var request: PendingRequest?

    var folderName: String {
        (cwd as NSString).lastPathComponent
    }
}

struct TerminalLocator: Equatable {
    var program: String?
    var termSession: String?
    var itermSession: String?
    var tmux: String?
    var tmuxPane: String?
}

/// A permission request awaiting the user's approve/reject on the notch.
struct PendingRequest: Equatable {
    let id: Int                // AgentServer request id
    let toolName: String
    /// Extracted plan / summary Markdown to preview (may be empty).
    let markdown: String
    let toolSummary: String
}

/// Owns agent session state fed by `AgentServer`, and drives the notch:
/// permission requests auto-expand into the Agent tab, other events fire
/// transient pops + sounds.
@MainActor
@Observable
final class AgentMonitorService {
    private(set) var sessions: [AgentSession] = []

    /// A permission request needs the notch (auto-expand + approve/reject).
    @ObservationIgnored var onRequest: ((AgentSession) -> Void)?
    /// A non-blocking attention event (idle prompt) → pop + sound.
    @ObservationIgnored var onAttention: ((AgentSession) -> Void)?
    /// Agent finished a turn.
    @ObservationIgnored var onDone: ((AgentSession) -> Void)?
    /// A pending request was answered or dropped — collapse if nothing else pends.
    @ObservationIgnored var onRequestResolved: (() -> Void)?

    private let server = AgentServer()

    var hasPendingRequest: Bool { sessions.contains { $0.request != nil } }
    var firstPending: AgentSession? { sessions.first { $0.request != nil } }
    var activeCount: Int { sessions.filter { $0.status != .done }.count }

    func start() {
        server.onEvent = { [weak self] event, requestID in
            self?.handle(event, requestID: requestID)
        }
        server.start()
    }

    // MARK: - Event handling

    private func handle(_ event: AgentEvent, requestID: Int?) {
        let sessionID = event.sessionId ?? "unknown"
        var session = sessions.first { $0.id == sessionID }
            ?? AgentSession(
                id: sessionID,
                kind: event.agentKind ?? "claude",
                cwd: event.cwd ?? "",
                status: .working,
                lastMessage: "",
                terminal: TerminalLocator()
            )

        if let cwd = event.cwd, !cwd.isEmpty { session.cwd = cwd }
        session.terminal = TerminalLocator(
            program: event.termProgram,
            termSession: event.termSession,
            itermSession: event.itermSession,
            tmux: event.tmux,
            tmuxPane: event.tmuxPane
        )

        switch event.event {
        case "PreToolUse", "PermissionRequest":
            guard let requestID else { break }
            let request = PendingRequest(
                id: requestID,
                toolName: event.toolName ?? "tool",
                markdown: Self.extractMarkdown(event),
                toolSummary: Self.summarize(event)
            )
            session.status = .waiting
            session.request = request
            upsert(session)
            onRequest?(session)

        case "Notification":
            // permission_prompt is covered by the blocking hook; only surface
            // idle_prompt (agent is waiting for the user) as an attention pop.
            if event.notification == "idle_prompt" {
                session.status = .waiting
                upsert(session)
                onAttention?(session)
            } else {
                upsert(session)
            }

        case "Stop", "SubagentStop":
            session.status = .done
            if let msg = event.lastMessage { session.lastMessage = msg }
            upsert(session)
            onDone?(session)

        case "SessionStart":
            session.status = .working
            upsert(session)

        case "SessionEnd":
            // Drop any dangling request so the relay isn't left hanging.
            if let id = session.request?.id { server.drop(id) }
            sessions.removeAll { $0.id == sessionID }
            onRequestResolved?()

        case "status":
            // Generic notify helper (Codex/Gemini): title carries the state.
            session.status = .waiting
            if let t = event.title { session.lastMessage = t }
            upsert(session)
            onAttention?(session)

        default:
            upsert(session)
        }
    }

    private func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    // MARK: - User actions

    func approve(_ session: AgentSession) {
        respond(session, decision: "allow")
    }

    func reject(_ session: AgentSession) {
        respond(session, decision: "deny", reason: "Rejected from MNotch")
    }

    private func respond(_ session: AgentSession, decision: String, reason: String = "") {
        guard let request = session.request else { return }
        server.respond(request.id, decision: decision, reason: reason)
        clearRequest(session.id, status: decision == "allow" ? .working : .done)
        onRequestResolved?()
    }

    private func clearRequest(_ sessionID: String, status: AgentStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].request = nil
        sessions[index].status = status
    }

    func dismissDone(_ sessionID: String) {
        sessions.removeAll { $0.id == sessionID && $0.status == .done }
    }

    /// Bring the agent's terminal to the front, targeting the exact tab/pane
    /// where possible (iTerm2 & Terminal by session id, tmux by pane), else
    /// just activating the app.
    func jump(_ session: AgentSession) {
        let term = session.terminal
        let bundleID: String? = switch term.program {
        case "iTerm.app": "com.googlecode.iterm2"
        case "Apple_Terminal": "com.apple.Terminal"
        case "vscode": "com.microsoft.VSCode"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "Hyper": "co.zeit.hyper"
        case "WezTerm": "com.github.wez.wezterm"
        default: nil
        }

        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }

        // Precise tmux pane switch (works regardless of the outer terminal).
        if let pane = term.tmuxPane, !pane.isEmpty {
            runShell("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
        }

        // Focus the exact iTerm2 session, if we captured its id.
        if term.program == "iTerm.app", let sid = term.itermSession, !sid.isEmpty {
            let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s) is "\(sid)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
            runAppleScript(script)
        }
    }

    private func runShell(_ launch: String, _ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private func runAppleScript(_ source: String) {
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    // MARK: - Content extraction

    private static func summarize(_ event: AgentEvent) -> String {
        let tool = event.toolName ?? "tool"
        guard let json = event.toolInputJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return tool }

        // Show the most useful field per common tool.
        if let command = obj["command"] as? String { return command }
        if let path = obj["file_path"] as? String {
            return "\(tool) \((path as NSString).lastPathComponent)"
        }
        if let url = obj["url"] as? String { return "\(tool) \(url)" }
        return tool
    }

    /// Plan preview: ExitPlanMode carries the plan in tool_input.plan;
    /// otherwise fall back to the last assistant message.
    private static func extractMarkdown(_ event: AgentEvent) -> String {
        if let json = event.toolInputJSON,
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let plan = obj["plan"] as? String, !plan.isEmpty { return plan }
        }
        return event.lastMessage ?? ""
    }
}
