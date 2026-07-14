import Foundation
import Network

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

    enum CodingKeys: String, CodingKey {
        case event, cwd, title, notification
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInputJSON = "tool_input"
        case lastMessage = "last_message"
        case agentKind = "agent_kind"
        case termProgram = "term_program"
        case termSession = "term_session"
        case itermSession = "iterm_session"
        case tmux, tmuxPane = "tmux_pane"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = (try? c.decode(String.self, forKey: .event)) ?? "unknown"
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        cwd = try? c.decode(String.self, forKey: .cwd)
        transcriptPath = try? c.decode(String.self, forKey: .transcriptPath)
        toolName = try? c.decode(String.self, forKey: .toolName)
        lastMessage = try? c.decode(String.self, forKey: .lastMessage)
        notification = try? c.decode(String.self, forKey: .notification)
        agentKind = try? c.decode(String.self, forKey: .agentKind)
        title = try? c.decode(String.self, forKey: .title)
        termProgram = try? c.decode(String.self, forKey: .termProgram)
        termSession = try? c.decode(String.self, forKey: .termSession)
        itermSession = try? c.decode(String.self, forKey: .itermSession)
        tmux = try? c.decode(String.self, forKey: .tmux)
        tmuxPane = try? c.decode(String.self, forKey: .tmuxPane)
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

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var token = ""
    private var pending: [Int: NWConnection] = [:]
    private var nextID = 1

    static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: "MNotch")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var tokenFile: URL { supportDirectory.appending(path: "agent-token") }
    static var portFile: URL { supportDirectory.appending(path: "agent-port") }

    func start() {
        guard listener == nil else { return }
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

    private func listenerBecameReady() {
        guard let p = listener?.port?.rawValue else { return }
        port = p
        try? String(p).write(to: Self.portFile, atomically: true, encoding: .utf8)
        mnotchLog.notice("AgentServer ready on 127.0.0.1:\(p)")
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveLine(on: connection, buffer: Data())
    }

    private func receiveLine(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                Task { @MainActor in self?.handleLine(lineData, on: connection) }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.receiveLine(on: connection, buffer: buffer)
        }
    }

    private struct Envelope: Decodable {
        let token: String
        let event: AgentEvent
    }

    private func handleLine(_ data: Data, on connection: NWConnection) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.token == token
        else {
            connection.cancel()
            return
        }

        let event = envelope.event
        if event.isPermissionRequest {
            let id = nextID
            nextID += 1
            pending[id] = connection
            onEvent?(event, id)
        } else {
            onEvent?(event, nil)
            connection.cancel()
        }
    }

    /// Answer a pending permission request; sends the hook JSON back and
    /// closes the connection. `decision` is "allow" | "deny" | "ask".
    func respond(_ id: Int, decision: String, reason: String = "") {
        guard let connection = pending.removeValue(forKey: id) else { return }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
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
        pending.removeValue(forKey: id)?.cancel()
    }

    private static func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8),
           !existing.isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fresh = UUID().uuidString + UUID().uuidString
        try? fresh.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenFile.path
        )
        return fresh
    }
}
