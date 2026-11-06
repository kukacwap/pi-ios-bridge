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
    @Published var lastAssistantText: String? = nil   // improvement #14: last assistant response

    // Phase 1
    @Published var sessions: [SessionInfo] = []
    @Published var cachedSessions: [SessionInfo] = []   // improvement #15: local cache
    @Published var sessionName = ""
    @Published var currentSessionPath: String? = nil     // from get_state.sessionFile
    @Published var switchingSession = false

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
    /// Only apply a get_messages batch whose request id is the one we are
    /// waiting for. A plain Bool flag was not enough: it stayed armed when a
    /// load was skipped and then let an unrelated batch clobber the transcript.
    private var historyRequestId: String?
    private var stateRequestId: String?
    private var statsRequestIds: Set<String> = []
    private var promptRequestIds: Set<String> = []
    /// Request id of our own pending session change (switch/new/fork/clone).
    /// While set, streaming events belong to the session we are leaving — pi
    /// aborts the old run and flushes a partial message_end before it answers.
    private var sessionChangeRequestId: String?
    /// Index in the current assistant turn's blocks where the in-flight
    /// assistant message begins. A run with tools emits several assistant
    /// messages; each message_end replaces only its own part.
    private var stepBase = 0
    /// Auto-compact at most once per session.
    private var autoCompactedPath: String?

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
        stepBase = 0
        running = true
        if let id = client?.prompt(t) { promptRequestIds.insert(id) }
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
    func clearConversation() { newSession() }

    func steer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, running else { return }
        client?.steer(t)
    }

    func abort() { client?.abort(); running = false }

    // Phase 1
    func newSession() {
        guard let c = client, connected else { return }
        beginSessionChange()
        sessionChangeRequestId = c.newSession()
        statusLine = "new session…"
    }
    func browseSessions() { client?.listSessions() }
    func openSession(_ s: SessionInfo) {
        guard let c = client, connected else { return }
        guard s.path != currentSessionPath || switchingSession else { return }
        beginSessionChange()
        sessionName = displayName(for: s)
        currentSessionPath = s.path
        sessionChangeRequestId = c.switchSession(s.path)
        statusLine = "loading \(sessionName.isEmpty ? "session" : sessionName)…"
    }
    func forkLastUser() {
        // Fork from the most recent user turn's entry — we don't track entry ids
        // here, so use clone as a safe fallback for "branch from now".
        guard let c = client, connected else { return }
        beginSessionChange()
        sessionChangeRequestId = c.clone()
    }

    /// Reset everything that belongs to the session we are leaving.
    private func beginSessionChange() {
        switchingSession = true
        turns.removeAll()
        artifacts.removeAll()
        activeArtifact = nil
        forkMessages.removeAll()
        lastAssistantText = nil
        contextPercent = nil
        sessionName = ""
        historyRequestId = nil
        stepBase = 0
        // pi aborts a running agent when the session changes.
        running = false
    }

    /// After any session change (ours or another attached client's), reload
    /// everything that is per-session.
    private func resyncSession() {
        guard let c = client else { return }
        historyRequestId = c.getMessages()
        stateRequestId = c.getState()
        statsRequestIds.insert(c.getStats())
        c.listSessions()
    }

    private func displayName(for s: SessionInfo) -> String {
        // The bridge falls back to the file name when a session has no name.
        let file = (s.path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        return s.name == file ? "" : s.name
    }

    // Step 4: per-message fork
    func loadForkMessages() { client?.getForkMessages() }
    func fork(from msg: ForkMessage) {
        guard let c = client, connected else { return }
        beginSessionChange()
        sessionChangeRequestId = c.fork(entryId: msg.entryId)
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
    func refreshStats() { if let id = client?.getStats() { statsRequestIds.insert(id) } }
    func doCompact() { client?.compact(); statusLine = "compacting…" }

    // MARK: - Event handling

    private var assistantIndex: Int? {
        for i in stride(from: turns.count - 1, through: 0, by: -1) where turns[i].role == .assistant { return i }
        return nil
    }

    private func handle(_ ev: PiAgentClient.Event) {
        // While our own session change is pending, streaming events still
        // belong to the session we are leaving: drop them.
        if sessionChangeRequestId != nil {
            switch ev {
            case .textDelta, .thinkingDelta, .toolStart, .toolEnd, .image, .messageStart, .messageEnd:
                return
            default: break
            }
        }
        switch ev {
        case .ready(let model, let provider, _, _):
            connected = true
            currentModel = model
            statusLine = "connected · \(provider)/\(model)"
            resyncSession()            // history, state, stats, session list
            client?.getAvailableModels()
            client?.getAvailableThinkingLevels()   // step 2
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

        case .messageStart(let role):
            guard role == "assistant" else { break }
            // A run we didn't start here (another attached device): give it its
            // own bubble instead of appending to the previous answer.
            if !(turns.last?.role == .assistant && turns.last?.streaming == true) {
                turns.append(Turn(role: .assistant, streaming: true))
                running = true
            }
            if let i = assistantIndex { stepBase = turns[i].blocks.count }

        case .messageEnd(let role, let blocks):
            // Replace the streaming assistant turn with the authoritative one.
            // NOTE: user turns are appended by `send` (live) or by the `.history`
            // handler (session load) — we must NOT append a user turn here again,
            // otherwise every prompt duplicates the user message.
            if role == "assistant" {
                if let i = assistantIndex {
                    // Replace only this step's streamed blocks; keep earlier
                    // steps of the same run (thinking/tool calls before a tool result).
                    let base = min(stepBase, turns[i].blocks.count)
                    turns[i].blocks = Array(turns[i].blocks[..<base]) + blocks
                    stepBase = turns[i].blocks.count
                    for b in blocks {
                        if case .toolCall(_, let name, _) = b, !turns[i].tools.contains(name) { turns[i].tools.append(name) }
                    }
                } else {
                    turns.append(Turn(role: .assistant, blocks: blocks))
                }
                // Surface any images in the completed message as artifacts.
                for b in blocks {
                    if case .image(let data, let mime) = b {
                        artifacts.append(Artifact(kind: .image, title: "image", content: "", imageData: data, mimeType: mime))
                    }
                }
            }
            // (user turns are handled by send() / .history — no append here)

        case .history(let id, let messages):
            // Only the batch we asked for most recently; ignore other clients'
            // and superseded requests (e.g. after a quick second switch).
            guard id == historyRequestId else { return }
            historyRequestId = nil
            var newTurns: [Turn] = []
            for m in messages {
                switch m.role {
                case "system":
                    continue                                   // preamble
                case "user":
                    guard !m.blocks.isEmpty else { continue }
                    var t = Turn(role: .user, blocks: m.blocks)
                    t.timestamp = Date(timeIntervalSince1970: m.timestamp / 1000.0)
                    newTurns.append(t)
                default:
                    // assistant / toolResult / bashExecution / custom: fold into one
                    // assistant turn per user prompt, exactly like the live view.
                    // Tool results are NOT assistant text — they only mark errors.
                    if newTurns.last?.role != .assistant {
                        newTurns.append(Turn(role: .assistant))
                    }
                    let i = newTurns.count - 1
                    newTurns[i].timestamp = Date(timeIntervalSince1970: m.timestamp / 1000.0)
                    if m.role == "toolResult" {
                        if m.isError {
                            let text = m.blocks.compactMap { b -> String? in
                                if case .text(let t) = b { return t }; return nil
                            }.joined()
                            newTurns[i].toolError = "\(m.toolName ?? "tool"): \(text.prefix(300))"
                        }
                        continue
                    }
                    if m.role == "bashExecution", !newTurns[i].tools.contains("bash") {
                        newTurns[i].tools.append("bash")
                    }
                    newTurns[i].blocks.append(contentsOf: m.blocks)
                    for b in m.blocks {
                        if case .toolCall(_, let name, _) = b, !newTurns[i].tools.contains(name) {
                            newTurns[i].tools.append(name)
                        }
                    }
                }
            }
            // A run is still streaming (started on another device): keep a live
            // bubble at the end so new deltas don't land in an old answer.
            if running {
                newTurns.append(Turn(role: .assistant, streaming: true))
                stepBase = 0
            }
            turns = newTurns
            switchingSession = false
            if statusLine.hasPrefix("loading") || statusLine.hasPrefix("new session") || statusLine.hasPrefix("forked") {
                statusLine = "connected"
            }

        case .settled:
            running = false
            if let i = assistantIndex { turns[i].streaming = false }
            refreshStats()          // refresh context gauge after each run
            client?.listSessions()  // first prompt creates the session file; mtime changes

        case .agentEnd:
            break

        case .bashUpdate(let id, let delta):   // step 6: live bash output
            _ = id
            bashOutput += delta

        case .extensionUI(let d):
            dialog = d          // present as a sheet (phase 3)

        case .response(let command, let id, let success, let error, let data):
            if ["switch_session", "new_session", "fork", "clone"].contains(command) {
                let ours = (id == sessionChangeRequestId)
                if ours { sessionChangeRequestId = nil }
                if !success {
                    statusLine = "error: \(command) failed\(error.map { ": \($0)" } ?? "")"
                } else if data["cancelled"] as? Bool == true {
                    statusLine = "\(command) cancelled"
                } else if !ours {
                    // Another device changed the shared session: follow it.
                    beginSessionChange()
                }
                // Always reload — on failure this restores the old session's view.
                resyncSession()
                return
            }
            if command == "prompt", promptRequestIds.remove(id) != nil, !success {
                running = false
                if let i = assistantIndex, turns[i].streaming {
                    turns[i].streaming = false
                    turns[i].toolError = "prompt failed: \(error ?? "unknown error")"
                }
                return
            }
            switch command {
            case "get_available_models":
                parseModels(data)
            case "list_sessions":
                parseSessions(data)
                // improvement #15: cache the session list locally
                cachedSessions = sessions
            case "get_state":
                guard id == stateRequestId else { break }
                stateRequestId = nil
                applyState(data)
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
            case "get_last_assistant_text":   // improvement #14
                if let t = data["text"] as? String { lastAssistantText = t }
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
                // Stats responses can belong to another client; only act on ours.
                guard statsRequestIds.remove(id) != nil else { break }
                if let cu = data["contextUsage"] as? [String: Any], let rawPct = cu["percent"] {
                    var pct: Int? = nil
                    if let i = rawPct as? Int { pct = i }
                    else if let d = rawPct as? Double { pct = Int(d) }
                    if let pct = pct {
                        contextPercent = pct
                        // improvement #11: auto-compact when context usage exceeds 70%
                        // Once per session, and never mid-run / mid-switch.
                        if pct > 70, !running, sessionChangeRequestId == nil,
                           let path = currentSessionPath, autoCompactedPath != path {
                            autoCompactedPath = path
                            doCompact()
                        }
                    }
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
            // thinking_level_changed arrives as a raw event.
            if obj["type"] as? String == "thinking_level_changed", let level = obj["level"] as? String {
                currentThinkingLevel = level
            }
        }
    }

    private func applyState(_ data: [String: Any]) {
        if let file = data["sessionFile"] as? String { currentSessionPath = file }
        if let name = data["sessionName"] as? String, !name.isEmpty {
            sessionName = name
        } else if let path = currentSessionPath,
                  let s = sessions.first(where: { $0.path == path }) {
            sessionName = displayName(for: s)
        }
        if let level = data["thinkingLevel"] as? String { currentThinkingLevel = level }
        if let m = data["model"] as? [String: Any] {
            currentModel = (m["name"] as? String) ?? (m["id"] as? String) ?? currentModel
        }
        // Only pick up a run that is already going (e.g. started on another
        // device). Never clear `running` here: a prompt we sent after this
        // get_state may not have started yet — agent_settled ends runs.
        if data["isStreaming"] as? Bool == true, !running {
            running = true
            if !(turns.last?.role == .assistant && turns.last?.streaming == true) {
                turns.append(Turn(role: .assistant, streaming: true))
                stepBase = 0
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
        // The list may arrive after get_state: fill in the current name now.
        if sessionName.isEmpty, let path = currentSessionPath,
           let s = sessions.first(where: { $0.path == path }) {
            sessionName = displayName(for: s)
        }
    }
}
