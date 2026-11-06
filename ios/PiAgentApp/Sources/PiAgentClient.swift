import Foundation

/// Transport client for the pi-ios-bridge WebSocket protocol.
/// No third-party deps (URLSessionWebSocketTask). One JSON object per message.
final class PiAgentClient: NSObject {

    struct Config {
        public var host: String
        public var port: Int
        public var token: String
        public var useTLS: Bool
        /// Open an existing session file on connect (optional).
        public var sessionPath: String?
        public init(host: String, port: Int = 8787, token: String, useTLS: Bool = false, sessionPath: String? = nil) {
            self.host = host; self.port = port; self.token = token; self.useTLS = useTLS; self.sessionPath = sessionPath
        }
    }

    // Emitted to the app.
    enum Event {
        case ready(model: String, provider: String, cwd: String, sessionDir: String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStart(name: String, args: [String: Any])
        case toolEnd(name: String, isError: Bool, resultText: String)
        case image(data: Data, mimeType: String)
        case messageStart(role: String)
        case messageEnd(role: String, blocks: [MessageBlock])   // authoritative completed message
        case settled(aborted: Bool)
        case agentEnd
        case bashUpdate(id: String, delta: String)   // step 6: live bash output
        case history(id: String, messages: [HistoryMessage])   // get_messages batch -> turns
        case response(command: String, id: String, success: Bool, error: String?, data: [String: Any])
        case extensionUI(ExtensionUIDialog)                      // ask-style clarification
        case bridgeError(String)
        case raw([String: Any])
    }

    private let config: Config
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)
    var onEvent: ((Event) -> Void)?

    init(config: Config) { self.config = config }

    func connect() {
        let scheme = config.useTLS ? "wss" : "ws"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = config.host
        comps.port = config.port
        comps.path = "/"
        var items = [URLQueryItem(name: "token", value: config.token)]
        if let sp = config.sessionPath { items.append(URLQueryItem(name: "session", value: sp)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        self.task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Commands

    /// Sends one command and returns its request id, so callers can match the
    /// response (the bridge is shared, so not every response is ours).
    @discardableResult
    private func send(_ obj: [String: Any]) -> String {
        var obj = obj
        let id = (obj["id"] as? String) ?? UUID().uuidString
        obj["id"] = id
        guard let task = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return id }
        task.send(.string(str)) { err in
            if let err = err { self.onEvent?(.bridgeError("send failed: \(err.localizedDescription)")) }
        }
        return id
    }

    @discardableResult
    func prompt(_ message: String, behavior: String? = nil) -> String {
        var obj: [String: Any] = ["type": "prompt", "message": message, "id": UUID().uuidString]
        if let b = behavior { obj["streamingBehavior"] = b }
        return send(obj)
    }
    func steer(_ message: String) { send(["type": "steer", "message": message, "id": UUID().uuidString]) }
    func followUp(_ message: String) { send(["type": "follow_up", "message": message, "id": UUID().uuidString]) }
    func abort() { send(["type": "abort", "id": UUID().uuidString]) }

    // Phase 1: history + session management
    @discardableResult func getMessages() -> String { send(["type": "get_messages", "id": "gm-\(UUID().uuidString)"]) }
    @discardableResult func getState() -> String { send(["type": "get_state", "id": "st-\(UUID().uuidString)"]) }
    func listSessions() { send(["type": "list_sessions", "id": "ls-\(UUID().uuidString)"]) }
    @discardableResult func newSession() -> String { send(["type": "new_session", "id": UUID().uuidString]) }
    @discardableResult func switchSession(_ path: String) -> String { send(["type": "switch_session", "sessionPath": path, "id": UUID().uuidString]) }
    @discardableResult func fork(entryId: String) -> String { send(["type": "fork", "entryId": entryId, "id": UUID().uuidString]) }
    @discardableResult func clone() -> String { send(["type": "clone", "id": UUID().uuidString]) }
    func getForkMessages() { send(["type": "get_fork_messages", "id": UUID().uuidString]) }
    func setSessionName(_ name: String) { send(["type": "set_session_name", "name": name, "id": UUID().uuidString]) }

    // Model switching (local providers only — enforced by the bridge)
    func setModel(provider: String, model: String) {
        send(["type": "set_model", "provider": provider, "modelId": model, "id": UUID().uuidString])
    }
    func getAvailableModels() { send(["type": "get_available_models", "id": UUID().uuidString]) }

    // Thinking level (step 2)
    func setThinkingLevel(_ level: String) { send(["type": "set_thinking_level", "level": level, "id": UUID().uuidString]) }
    func getAvailableThinkingLevels() { send(["type": "get_available_thinking_levels", "id": UUID().uuidString]) }

    // Context / compaction (step 3)
    @discardableResult func getStats() -> String { send(["type": "get_session_stats", "id": "stats-\(UUID().uuidString)"]) }
    func compact(customInstructions: String? = nil) {
        var obj: [String: Any] = ["type": "compact", "id": UUID().uuidString]
        if let ci = customInstructions { obj["customInstructions"] = ci }
        send(obj)
    }

    // Phase 2: diffs / export / images
    func diff(staged: Bool = false) { send(["type": "diff", "staged": staged, "id": "df-\(UUID().uuidString)"]) }
    func exportHTML() { send(["type": "export_html", "id": UUID().uuidString]) }
    func bash(_ command: String) { send(["type": "bash", "command": command, "id": "sh-\(UUID().uuidString)"]) }

    // Phase 3: commands / clarifications
    func getCommands() { send(["type": "get_commands", "id": UUID().uuidString]) }
    func runBash(_ command: String, excludeFromContext: Bool = false) {
        var obj: [String: Any] = ["type": "bash", "command": command, "id": "sh-\(UUID().uuidString)"]
        if excludeFromContext { obj["excludeFromContext"] = true }
        send(obj)
    }
    func abortBash() { send(["type": "abort_bash", "id": UUID().uuidString]) }
    /// Answer an extension UI dialog.
    func answerDialog(_ dialog: ExtensionUIDialog, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
        var obj: [String: Any] = ["type": "extension_ui_response", "id": dialog.id]
        if cancelled { obj["cancelled"] = true }
        else if let c = confirmed { obj["confirmed"] = c }
        else if let v = value { obj["value"] = v }
        send(obj)
    }

    // MARK: - Receive

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.onEvent?(.bridgeError("receive failed: \(err.localizedDescription)"))
                return
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "bridge_ready":
            onEvent?(.ready(model: obj["model"] as? String ?? "",
                            provider: obj["provider"] as? String ?? "",
                            cwd: obj["cwd"] as? String ?? "",
                            sessionDir: obj["sessionDir"] as? String ?? ""))

        case "message_update":
            if let ev = obj["assistantMessageEvent"] as? [String: Any],
               let evType = ev["type"] as? String {
                switch evType {
                case "text_delta":
                    if let d = ev["delta"] as? String { onEvent?(.textDelta(d)) }
                case "thinking_delta":
                    if let d = ev["delta"] as? String { onEvent?(.thinkingDelta(d)) }
                case "toolcall_start":
                    let name = ev["toolName"] as? String ?? ""
                    onEvent?(.toolStart(name: name, args: [:]))
                default: break
                }
            }

        case "tool_execution_start":
            let name = obj["toolName"] as? String ?? ""
            let args = obj["args"] as? [String: Any] ?? [:]
            onEvent?(.toolStart(name: name, args: args))

        case "tool_execution_end":
            let name = obj["toolName"] as? String ?? ""
            let isError = obj["isError"] as? Bool ?? false
            let resultText = extractText(obj["result"])
            onEvent?(.toolEnd(name: name, isError: isError, resultText: resultText))

        case "message_start":
            if let msg = obj["message"] as? [String: Any] {
                onEvent?(.messageStart(role: msg["role"] as? String ?? "assistant"))
            }

        case "message_end":
            if let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? "assistant"
                let blocks = parseBlocks(msg["content"])
                onEvent?(.messageEnd(role: role, blocks: blocks))
            }

        case "agent_settled": onEvent?(.settled(aborted: obj["aborted"] as? Bool ?? false))
        case "agent_end": onEvent?(.agentEnd)

        case "bash_execution_update":
            let id = obj["id"] as? String ?? ""
            if let d = obj["delta"] as? String { onEvent?(.bashUpdate(id: id, delta: d)) }

        case "extension_ui_request":
            if let dialog = parseDialog(obj) { onEvent?(.extensionUI(dialog)) }

        case "response":
            let command = obj["command"] as? String ?? ""
            let id = obj["id"] as? String ?? ""
            let success = obj["success"] as? Bool ?? false
            let data = obj["data"] as? [String: Any] ?? [:]
            // get_messages returns a batch of historical messages; parse into turns.
            if command == "get_messages", success, let msgs = data["messages"] as? [[String: Any]] {
                let parsed = msgs.compactMap { m -> HistoryMessage? in
                    guard let role = m["role"] as? String else { return nil }
                    let ts = (m["timestamp"] as? Double) ?? (m["timestamp"] as? Int).map { Double($0) } ?? 0
                    var blocks = parseBlocks(m["content"])
                    // bashExecution (user-run `!cmd`) has no content array.
                    if role == "bashExecution" {
                        let cmd = m["command"] as? String ?? ""
                        let out = m["output"] as? String ?? ""
                        blocks = [.text("$ \(cmd)\n\(out)")]
                    }
                    return HistoryMessage(role: role, blocks: blocks, timestamp: ts,
                                          toolName: m["toolName"] as? String,
                                          isError: m["isError"] as? Bool ?? false)
                }
                onEvent?(.history(id: id, messages: parsed))
            } else {
                onEvent?(.response(command: command, id: id, success: success,
                                   error: obj["error"] as? String, data: data))
            }

        case "bridge_error":
            onEvent?(.bridgeError(obj["error"] as? String ?? "unknown"))

        default:
            onEvent?(.raw(obj))
        }
    }

    // MARK: - Decoding helpers

    private func extractText(_ any: Any?) -> String {
        guard let result = any as? [String: Any] else { return "" }
        if let content = result["content"] as? [[String: Any]] {
            var out = ""
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String { out += t }
            }
            return out
        }
        if let s = result["output"] as? String { return s }
        return ""
    }

    private func parseBlocks(_ content: Any?) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        // String content (user messages).
        if let s = content as? String {
            if !s.isEmpty { blocks.append(.text(s)) }
            return blocks
        }
        guard let arr = content as? [[String: Any]] else { return blocks }
        for c in arr {
            switch c["type"] as? String {
            case "text":
                if let t = c["text"] as? String, !t.isEmpty { blocks.append(.text(t)) }
            case "thinking":
                if let t = c["thinking"] as? String, !t.isEmpty { blocks.append(.thinking(t)) }
            case "toolCall":
                let id = c["id"] as? String ?? ""
                let name = c["name"] as? String ?? ""
                let args = c["arguments"] as? [String: Any] ?? [:]
                blocks.append(.toolCall(id: id, name: name, args: args))
            case "image":
                if let b64 = c["data"] as? String, let data = Data(base64Encoded: b64) {
                    blocks.append(.image(data: data, mimeType: c["mimeType"] as? String ?? "image/png"))
                }
            default: break
            }
        }
        return blocks
    }

    private func parseDialog(_ obj: [String: Any]) -> ExtensionUIDialog? {
        guard let id = obj["id"] as? String, let method = obj["method"] as? String else { return nil }
        return ExtensionUIDialog(
            id: id,
            method: method,
            title: obj["title"] as? String ?? "",
            message: obj["message"] as? String,
            options: obj["options"] as? [String],
            placeholder: obj["placeholder"] as? String,
            prefill: obj["prefill"] as? String,
            timeoutMs: obj["timeout"] as? Int
        )
    }
}
