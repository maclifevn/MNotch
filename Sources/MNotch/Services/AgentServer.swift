import Foundation
import Network

enum AgentDecision: String {
    case allow, deny, ask

    static func normalized(_ value: String) -> AgentDecision {
        AgentDecision(rawValue: value) ?? .ask
    }
}

enum AgentHookResponse {
    static func data(
        event: String,
        decision: AgentDecision,
        reason: String = ""
    ) -> Data? {
        let payload: [String: Any]
        if event == "PermissionRequest" {
            // PermissionRequest has no "ask" representation. No output lets
            // Claude/Codex keep their native approval prompt as the fallback.
            guard decision != .ask else { return nil }
            payload = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": decision == .deny ? "deny" : "allow"],
                ],
            ]
        } else {
            payload = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision.rawValue,
                    "permissionDecisionReason": reason,
                ],
            ]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}

/// One event received from an agent hook relay.
struct AgentEvent: Decodable {
    /// hook event name: PreToolUse, PermissionRequest, Notification, Stop,
    /// SessionStart, SessionEnd — or "status" from the generic notify helper.
    let event: String
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
    let toolName: String?
    /// Free-form; decoded lazily where needed (tool_input can be any shape).
    let toolInputJSON: String?
    let lastMessage: String?
    let notification: String?     // Notification matcher: permission_prompt / idle_prompt …
    let agentKind: String?        // "claude" | "codex" | "gemini" | …
    let title: String?
    // Terminal locator (for jump-to-terminal).
    let termProgram: String?
    let termSession: String?
    let itermSession: String?
    let tmux: String?
    let tmuxPane: String?
    let hostBundle: String?       // host app bundle id (GUI-embedded agents)

    enum CodingKeys: String, CodingKey {
        case event, cwd, title, notification
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInputJSON = "tool_input"
        case lastMessage = "last_message"
        case lastAssistantMessage = "last_assistant_message"
        case agentKind = "agent_kind"
        case termProgram = "term_program"
        case termSession = "term_session"
        case itermSession = "iterm_session"
        case tmux, tmuxPane = "tmux_pane"
        case hostBundle = "host_bundle"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = (try? c.decode(String.self, forKey: .event)) ?? "unknown"
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        cwd = try? c.decode(String.self, forKey: .cwd)
        transcriptPath = try? c.decode(String.self, forKey: .transcriptPath)
        toolName = try? c.decode(String.self, forKey: .toolName)
        lastMessage = (try? c.decode(String.self, forKey: .lastMessage))
            ?? (try? c.decode(String.self, forKey: .lastAssistantMessage))
        notification = try? c.decode(String.self, forKey: .notification)
        agentKind = try? c.decode(String.self, forKey: .agentKind)
        title = try? c.decode(String.self, forKey: .title)
        termProgram = try? c.decode(String.self, forKey: .termProgram)
        termSession = try? c.decode(String.self, forKey: .termSession)
        itermSession = try? c.decode(String.self, forKey: .itermSession)
        tmux = try? c.decode(String.self, forKey: .tmux)
        tmuxPane = try? c.decode(String.self, forKey: .tmuxPane)
        hostBundle = try? c.decode(String.self, forKey: .hostBundle)
        // tool_input is arbitrary JSON — re-encode it back to a string so the
        // UI can pull specific fields (e.g. an ExitPlanMode plan) on demand.
        if let raw = try? c.decode(AnyCodable.self, forKey: .toolInputJSON),
           let data = try? JSONEncoder().encode(raw) {
            toolInputJSON = String(data: data, encoding: .utf8)
        } else {
            toolInputJSON = nil
        }
    }

    /// A blocking permission event that expects an allow/deny/ask reply.
    var isPermissionRequest: Bool {
        event == "PreToolUse" || event == "PermissionRequest"
    }
}

/// Minimal any-JSON box so `tool_input` round-trips without a fixed schema.
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
    init(_ value: Any) { self.value = value }
}

/// Local TCP server that receives agent hook events. A connection carrying a
/// permission request stays open until `respond(_:decision:)` sends the
/// decision back, which is how "approve from the notch" works. Bound to
/// 127.0.0.1 and gated by a shared token file so only local processes that
/// can read the token (i.e. this user) may talk to it.
@MainActor
final class AgentServer {
    /// (event, requestID?) — requestID is non-nil for blocking permission
    /// events that must be answered via `respond`.
    var onEvent: ((AgentEvent, Int?) -> Void)?

    /// A pending permission request ended without the app answering it: the
    /// relay disconnected (it timed out to the terminal, or the agent session
    /// was killed) or the server-side wait expired. The consumer must clear the
    /// matching notch card so it doesn't hang open. Not called for requests the
    /// app itself resolves via `respond`/`drop`.
    var onRequestEnded: ((Int) -> Void)?

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var token = ""
    private struct PendingConnection {
        let connection: NWConnection
        let event: String
        let timeout: Task<Void, Never>
    }

    private var pending: [Int: PendingConnection] = [:]
    private var nextID = 1

    static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: "MNotch")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: base.path
        )
        return base
    }

    static var tokenFile: URL { supportDirectory.appending(path: "agent-token") }
    static var portFile: URL { supportDirectory.appending(path: "agent-port") }

    func start() {
        guard listener == nil else { return }
        try? FileManager.default.removeItem(at: Self.portFile)
        token = Self.loadOrCreateToken()

        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { @MainActor in self?.listenerBecameReady() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            mnotchLog.error("AgentServer failed to listen: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        try? FileManager.default.removeItem(at: Self.portFile)
        for entry in pending.values {
            entry.timeout.cancel()
            entry.connection.cancel()
        }
        pending.removeAll()
    }

    private func listenerBecameReady() {
        guard let p = listener?.port?.rawValue else { return }
        port = p
        try? String(p).write(to: Self.portFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.portFile.path
        )
        mnotchLog.notice("AgentServer ready on 127.0.0.1:\(p)")
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.removePending(for: connection)
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveLine(on: connection, buffer: Data())
    }

    /// Each connection sends exactly one JSON envelope. Rather than framing on
    /// a delimiter (a stray newline inside the hook JSON broke that), just
    /// accumulate bytes and process as soon as the buffer decodes as a full
    /// envelope. Caps the buffer to avoid unbounded growth on garbage input.
    private func receiveLine(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }

            if let envelope = try? JSONDecoder().decode(Envelope.self, from: buffer) {
                Task { @MainActor in self?.handle(envelope, on: connection) }
                return
            }
            if isComplete || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self?.receiveLine(on: connection, buffer: buffer)
            }
        }
    }

    private struct Envelope: Decodable {
        let token: String
        let event: AgentEvent
    }

    private func handle(_ envelope: Envelope, on connection: NWConnection) {
        guard envelope.token == token else {
            mnotchLog.error("AgentServer token mismatch")
            connection.cancel()
            return
        }
        mnotchLog.notice("AgentServer event=\(envelope.event.event, privacy: .public) perm=\(envelope.event.isPermissionRequest)")
        dispatch(envelope.event, on: connection)
    }

    private func dispatch(_ event: AgentEvent, on connection: NWConnection) {
        if event.isPermissionRequest {
            let id = nextID
            nextID += 1
            let timeout = Task { [weak self, weak connection] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let connection else { return }
                self?.expire(id, connection: connection)
            }
            pending[id] = PendingConnection(
                connection: connection,
                event: event.event,
                timeout: timeout
            )
            // While waiting for a decision we aren't otherwise reading, so a
            // clean peer close (relay timed out and exited, or the session
            // ended) would go unnoticed until the backstop timer. Keep one read
            // pending purely to detect EOF and release the card promptly.
            watchForClose(connection)
            onEvent?(event, id)
        } else {
            onEvent?(event, nil)
            connection.cancel()
        }
    }

    /// Answer a pending permission request; sends the hook JSON back and
    /// closes the connection. `decision` is "allow" | "deny" | "ask".
    /// PreToolUse and PermissionRequest expect different output shapes.
    func respond(_ id: Int, decision: String, reason: String = "") {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        let connection = entry.connection
        let safeDecision = AgentDecision.normalized(decision)

        guard let data = AgentHookResponse.data(
            event: entry.event,
            decision: safeDecision,
            reason: reason
        ) else {
            connection.cancel()
            return
        }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Drop a pending request without answering (relay will time out to the
    /// terminal). Used when a request is superseded or the session ends.
    func drop(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.connection.cancel()
    }

    /// Wait for the blocking connection's peer to close (EOF) or error while a
    /// decision is outstanding, then release the pending request. Re-arms on the
    /// stray byte the relay never actually sends, so it can't busy-loop.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
            [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                Task { @MainActor in self?.removePending(for: connection) }
            } else {
                Task { @MainActor in self?.watchForClose(connection) }
            }
        }
    }

    private func expire(_ id: Int, connection: NWConnection) {
        guard let entry = pending[id], entry.connection === connection else { return }
        pending.removeValue(forKey: id)
        connection.cancel()
        onRequestEnded?(id)
    }

    private func removePending(for connection: NWConnection) {
        let ids = pending.compactMap { id, entry in
            entry.connection === connection ? id : nil
        }
        for id in ids {
            pending.removeValue(forKey: id)?.timeout.cancel()
            onRequestEnded?(id)
        }
    }

    private static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: tokenFile.path
                )
                return trimmed
            }
        }
        let fresh = UUID().uuidString + UUID().uuidString
        try? fresh.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenFile.path
        )
        return fresh
    }
}
