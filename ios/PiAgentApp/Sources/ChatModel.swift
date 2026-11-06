import Foundation
import SwiftUI
import UIKit

/// Observable chat state driven by PiAgentClient events.
@MainActor
final class ChatModel: ObservableObject {

    struct Turn: Identifiable {
        let id = UUID()
        enum Role { case user, assistant }
        var role: Role
        var blocks: [MessageBlock] = []
        var streaming: Bool = false
        var tools: [String] = []          // tool names used in this turn
        var toolError: String? = nil      // issue #2: inline error note (not an artifact)
        var timestamp: Date = Date()      // when this turn was created/answered

        var text: String {
            blocks.compactMap { block in
                if case .text(let t) = block { return t }
                return nil
            }.joined()
        }
        var thinking: String {
            blocks.compactMap { block in
                if case .thinking(let t) = block { return t }
                return nil
            }.joined()
        }
        var timestampLabel: String {
            timestamp.formatted(.dateTime.hour().minute())
        }
    }

    struct ModelOption: Identifiable, Hashable {
        var id: String { "\(provider)/\(model)" }
        let provider: String
        let model: String
        let name: String
    }

    @Published var turns: [Turn] = []
    @Published var connected = false
    @Published var running = false
    @Published var statusLine = "disconnected"
    @Published var currentModel = ""
    @Published var availableModels: [ModelOption] = []
    @Published var showThinking = false

    // Phase 1
    @Published var sessions: [SessionInfo] = []
    @Published var sessionName = ""

    // Phase 2
    @Published var artifacts: [Artifact] = []
    @Published var activeArtifact: Artifact?

    // Phase 3
    @Published var dialog: ExtensionUIDialog?
    @Published var commands: [CommandInfo] = []

    // Steps 1–3
    @Published var thinkingLevels: [String] = []
    @Published var currentThinkingLevel = ""
    @Published var contextPercent: Int? = nil

    // Steps 4–6
    @Published var forkMessages: [ForkMessage] = []     // step 4
    @Published var bashOutput = ""                        // step 6
    @Published var bashRunning = false                    // step 6

    private var client: PiAgentClient?
    private var settings: AppSettings
    /// Only apply a get_messages batch to the transcript when we explicitly
    /// requested it (connect / switch / new). Stray or broadcast .history events
    /// must NOT clobber a live conversation.
    private var pendingHistoryLoad = false

    init(settings: AppSettings) { self.settings = settings }

    func reconfigure(_ settings: AppSettings) { self.settings = settings }

    // MARK: - Connection

    func connect() {
        let cfg = PiAgentClient.Config(
            host: settings.host, port: settings.port,
            token: settings.token, useTLS: settings.useTLS
        )
        let c = PiAgentClient(config: cfg)
        c.onEvent = { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
        self.client = c
        statusLine = "connecting…"
        c.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        connected = false
        running = false
        statusLine = "disconnected"
    }

    // MARK: - User actions

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, connected else { return }
        // improvement #9: haptic feedback on send
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        turns.append(Turn(role: .user, blocks: [.text(t)]))
        turns.append(Turn(role: .assistant, streaming: true))
        running = true
        client?.prompt(t)
    }

    // Regenerate: re-send the last user message (replaces the assistant response).
    func regenerate() {
        guard let lastUserIdx = (0..<turns.count).last(where: { turns[$0].role == .user }) else { return }
        let text = turns[lastUserIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Drop the user turn + assistant response, then re-run the same prompt.
        turns.removeSubrange(lastUserIdx...turns.count - 1)
        send(text)
    }

    // Clear conversation / restart session (improvement #5).
    func clearConversation() {
        client?.newSession()
        turns.removeAll()
        artifacts.removeAll()
    }

    func steer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, running else { return }
        client?.steer(t)
    }

    func abort() { client?.abort(); running = false }

    // Phase 1
    func newSession() { client?.newSession(); turns.removeAll(); artifacts.removeAll() }
    func browseSessions() { client?.listSessions() }
    func openSession(_ s: SessionInfo) {
        turns.removeAll()
        client?.switchSession(s.path)
        statusLine = "loading \(s.name)…"
    }
    func forkLastUser() {
        // Fork from the most recent user turn's entry — we don't track entry ids
        // here, so use clone as a safe fallback for "branch from now".
        client?.clone()
    }

    // Step 4: per-message fork
    func loadForkMessages() { client?.getForkMessages() }
    func fork(from msg: ForkMessage) {
        client?.fork(entryId: msg.entryId)
        statusLine = "forked from: \(msg.text.prefix(40))…"
    }

    // Phase 2
    func refreshDiff(staged: Bool = false) { client?.diff(staged: staged) }
    func exportHTML() { client?.exportHTML() }

    // Phase 3
    func refreshCommands() { client?.getCommands() }
    func runCommand(_ c: CommandInfo) {
        // Skills / prompt templates are invoked by prefixing the name with "/".
        send("/\(c.name)")
    }
    // Step 6: live bash
    func runBash(_ command: String, excludeFromContext: Bool = false) {
        guard connected else { return }
        bashOutput = ""
        bashRunning = true
        client?.runBash(command, excludeFromContext: excludeFromContext)
    }
    func stopBash() { client?.abortBash(); bashRunning = false }
    func answerDialog(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
        guard let d = dialog else { return }
        client?.answerDialog(d, value: value, confirmed: confirmed, cancelled: cancelled)
        self.dialog = nil
    }

    func selectModel(_ opt: ModelOption) {
        client?.setModel(provider: opt.provider, model: opt.model)
        currentModel = opt.name
    }

    // Steps 1–3
    func nameSession(_ name: String) {
        sessionName = name
        client?.setSessionName(name)
    }
    func setThinking(_ level: String) {
        currentThinkingLevel = level
        client?.setThinkingLevel(level)
    }
    func refreshStats() { client?.getStats() }
    func doCompact() { client?.compact(); statusLine = "compacting…" }

    // MARK: - Event handling

    private var assistantIndex: Int? {
        for i in stride(from: turns.count - 1, through: 0, by: -1) where turns[i].role == .assistant { return i }
        return nil
    }

    private func handle(_ ev: PiAgentClient.Event) {
        switch ev {
        case .ready(let model, let provider, _, _):
            connected = true
            currentModel = model
            statusLine = "connected · \(provider)/\(model)"
            pendingHistoryLoad = true          // we explicitly want history now
            client?.getMessages()      // load history (phase 1)
            client?.listSessions()     // populate session browser
            client?.getAvailableModels()
            client?.getAvailableThinkingLevels()   // step 2
            client?.getStats()                    // step 3
            client?.getCommands()                 // step 5: skills/templates

        case .textDelta(let d):
            appendToAssistant { $0.blocks.append(.text(d)) }

        case .thinkingDelta(let d):
            appendToAssistant { $0.blocks.append(.thinking(d)) }

        case .toolStart(let name, let args):
            if let i = assistantIndex {
                if !turns[i].tools.contains(name) { turns[i].tools.append(name) }
                // Build an artifact from write/edit tool calls (phase 2).
                if name == "write" || name == "edit" {
                    let path = (args["path"] as? String) ?? "file"
                    var content = ""
                    if name == "write", let c = args["content"] as? String { content = c }
                    else if let old = args["oldText"] as? String, let new = args["newText"] as? String {
                        content = "− \(old)\n+ \(new)"
                    }
                    artifacts.append(Artifact(kind: .file, title: path, content: content))
                }
            }

        case .toolEnd(let name, let isError, let resultText):
            // Issue #2: don't clutter the Artifacts panel with tool errors.
            // Surface them inline on the turn instead (small red note).
            if isError, let i = assistantIndex, !resultText.isEmpty {
                turns[i].toolError = "\(name): \(resultText.prefix(300))"
            }

        case .image(let data, let mimeType):
            artifacts.append(Artifact(kind: .image, title: "image", content: "", imageData: data, mimeType: mimeType))

        case .messageEnd(let role, let blocks):
            // Replace the streaming assistant turn with the authoritative one.
            if role == "assistant" {
                if let i = assistantIndex {
                    turns[i].blocks = blocks
                    turns[i].streaming = false
                } else {
                    turns.append(Turn(role: .assistant, blocks: blocks))
                }
                // Surface any images in the completed message as artifacts.
                for b in blocks {
                    if case .image(let data, let mime) = b {
                        artifacts.append(Artifact(kind: .image, title: "image", content: "", imageData: data, mimeType: mime))
                    }
                }
            } else if role == "user" {
                // History load: append past user turns.
                if !blocks.isEmpty {
                    var t = Turn(role: .user, blocks: blocks)
                    t.streaming = false
                    turns.append(t)
                }
            }

        case .history(let messages):
            // Issue #1: only replace the transcript when we explicitly asked for
            // history AND nothing is actively streaming. Otherwise a stray or
            // broadcast get_messages would wipe a live conversation.
            guard pendingHistoryLoad, !running else { return }
            pendingHistoryLoad = false
            var newTurns: [Turn] = []
            for m in messages {
                guard !m.blocks.isEmpty else { continue }
                if m.role == "system" { continue }   // skip system preamble
                let role: Turn.Role = (m.role == "user") ? .user : .assistant
                var t = Turn(role: role, blocks: m.blocks)
                t.streaming = false
                t.timestamp = Date(timeIntervalSince1970: m.timestamp / 1000.0)
                // Collect tool names for the badge row.
                for b in m.blocks {
                    if case .toolCall(_, let name, _) = b, !t.tools.contains(name) { t.tools.append(name) }
                }
                newTurns.append(t)
            }
            turns = newTurns

        case .settled:
            running = false
            if let i = assistantIndex { turns[i].streaming = false }
            client?.getStats()   // refresh context gauge after each run

        case .agentEnd:
            break

        case .bashUpdate(let id, let delta):   // step 6: live bash output
            _ = id
            bashOutput += delta

        case .extensionUI(let d):
            dialog = d          // present as a sheet (phase 3)

        case .response(let command, let success, let data):
            switch command {
            case "get_available_models":
                parseModels(data)
            case "list_sessions":
                parseSessions(data)
            case "switch_session":
                // After switching, reload the new session's history.
                pendingHistoryLoad = true
                client?.getMessages()
            case "new_session":
                turns.removeAll(); artifacts.removeAll()
                pendingHistoryLoad = true
                client?.getMessages()
            case "diff":
                if let out = data["output"] as? String, !out.isEmpty {
                    artifacts.append(Artifact(kind: .diff, title: "git diff", content: out))
                } else {
                    statusLine = "no changes (clean working tree)"
                }
            case "export_html":
                if let path = data["path"] as? String {
                    statusLine = "exported: \(path)"
                    artifacts.append(Artifact(kind: .html, title: "session.html", content: path))
                }
            case "get_commands":
                if let cmds = data["commands"] as? [[String: Any]] {
                    commands = cmds.compactMap { d in
                        guard let name = d["name"] as? String else { return nil }
                        return CommandInfo(name: name,
                                          description: d["description"] as? String,
                                          source: (d["source"] as? String) ?? "")
                    }
                }
            case "get_fork_messages":   // step 4
                if let msgs = data["messages"] as? [[String: Any]] {
                    forkMessages = msgs.compactMap { d in
                        guard let id = d["entryId"] as? String else { return nil }
                        return ForkMessage(entryId: id, text: (d["text"] as? String) ?? "")
                    }.reversed()   // most recent first
                }
            case "bash":   // step 6: final result
                bashRunning = false
                if let out = data["output"] as? String, !out.isEmpty {
                    bashOutput = out
                }
            case "get_available_thinking_levels":
                if let levels = data["levels"] as? [String] { thinkingLevels = levels }
            case "get_session_stats":
                if let cu = data["contextUsage"] as? [String: Any], let pct = cu["percent"] as? Int {
                    contextPercent = pct
                }
            default:
                break
            }

        case .bridgeError(let msg):
            statusLine = "error: \(msg)"

        case .raw(let obj):
            // session_info_changed arrives as a raw event.
            if obj["type"] as? String == "session_info_changed", let name = obj["name"] as? String {
                sessionName = name
            }
        }
    }

    private func appendToAssistant(_ mutate: (inout Turn) -> Void) {
        guard let i = assistantIndex else { return }
        mutate(&turns[i])
    }

    private func parseModels(_ data: [String: Any]) {
        let local = Set(["ollama", "llama-cpp", "lmstudio", "vllm"])
        guard let arr = data["models"] as? [[String: Any]] else { return }
        var opts: [ModelOption] = []
        for m in arr {
            let provider = m["provider"] as? String ?? ""
            let model = (m["id"] as? String) ?? (m["model"] as? String) ?? ""
            let name = (m["name"] as? String) ?? model
            guard local.contains(provider), !model.isEmpty else { continue }
            opts.append(ModelOption(provider: provider, model: model, name: name))
        }
        if !opts.isEmpty { availableModels = opts }
    }

    private func parseSessions(_ data: [String: Any]) {
        guard let arr = data["sessions"] as? [[String: Any]] else { return }
        sessions = arr.compactMap { d in
            guard let path = d["path"] as? String else { return nil }
            return SessionInfo(
                path: path,
                name: (d["name"] as? String) ?? path,
                mtime: (d["mtime"] as? Double) ?? 0,
                preview: (d["preview"] as? String) ?? ""
            )
        }
    }
}
