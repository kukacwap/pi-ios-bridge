import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject var model: ChatModel
    @StateObject private var dictation = SpeechDictation()
    @State private var input = ""
    @State private var dictationBase = ""      // text present when dictation started
    @FocusState private var inputFocused: Bool

    // Sheets / panels (phases 1–3)
    @State private var showSessions = false
    @State private var showArtifacts = false
    @State private var activeArtifact: Artifact?
    @State private var showControls = false
    @State private var showFork = false       // step 4
    @State private var showCommands = false   // step 5
    @State private var showBash = false       // step 6
    @State private var showLastResponse = false // improvement #14

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSessions) {
            SessionListView(model: model)
        }
        .sheet(isPresented: $showArtifacts) {
            ArtifactsListView(model: model, onOpen: { activeArtifact = $0; showArtifacts = false })
        }
        .sheet(item: $activeArtifact) { a in
            ArtifactView(artifact: a)
        }
        .sheet(item: Binding(
            get: { model.dialog },
            set: { if $0 == nil { model.answerDialog(cancelled: true) } }
        )) { d in
            ExtensionUISheet(dialog: d) { value, confirmed, cancelled in
                model.answerDialog(value: value, confirmed: confirmed, cancelled: cancelled)
            }
        }
        .sheet(isPresented: $showControls) {
            ControlPanel(model: model)
        }
        .sheet(isPresented: $showFork) { ForkSheet(model: model) }      // step 4
        .sheet(isPresented: $showCommands) { CommandsSheet(model: model) } // step 5
        .sheet(isPresented: $showBash) { BashPanel(model: model) }        // step 6
        .sheet(isPresented: $showLastResponse) {
            LastResponseView(text: model.lastAssistantText ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Context gauge (step 3) — shows when we have a reading.
        if let pct = model.contextPercent {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.50percent")
                    Text("\(pct)%").font(.caption.monospaced())
                }
                .foregroundStyle(pct >= 80 ? .red : pct >= 60 ? .orange : .secondary)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Steps 1–3: controls (name, thinking level, compact)
            Button { showControls = true } label: { Image(systemName: "slider.horizontal.3") }

            // Regenerate last response (improvement #1)
            if !model.turns.isEmpty {
                Button { model.regenerate() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .disabled(model.running)
            }

            // Clear conversation / restart session (improvement #5)
            if !model.turns.isEmpty {
                Button { model.clearConversation() } label: { Image(systemName: "trash") }
                    .disabled(model.running)
            }

            // improvement #18: copy full conversation to clipboard
            if !model.turns.isEmpty {
                Button {
                    var all = ""
                    for t in model.turns {
                        let txt = t.text
                        if !txt.isEmpty { all += (all.isEmpty ? "" : "\n\n") + txt }
                    }
                    UIPasteboard.general.string = all
                } label: { Image(systemName: "doc.on.doc") }
            }

            // improvement #14: show last assistant response
            if model.lastAssistantText != nil {
                Button { showLastResponse = true } label: { Image(systemName: "doc.text") }
            }

            // Phase 1 + step 4: sessions & fork
            Menu {
                Button("Browse sessions", systemImage: "folder") { showSessions = true }
                Button("New session", systemImage: "plus.bubble") { model.newSession() }
                Button("Fork from…", systemImage: "arrow.branch") { showFork = true }        // step 4
                Button("Branch (clone)", systemImage: "arrow.triangle.branch") { model.forkLastUser() }
            } label: { Image(systemName: "folder") }

            // Phase 2 + steps 5–6: diff, artifacts, export, skills, bash
            Menu {
                Button("Git diff", systemImage: "doc.text.magnifyingglass") { model.refreshDiff() }
                Button("Artifacts (\(model.artifacts.count))", systemImage: "square.stack") { showArtifacts = true }
                Button("Export HTML", systemImage: "square.and.arrow.up") { model.exportHTML() }
                Divider()
                Button("Skills & commands", systemImage: "wand.and.stars") { showCommands = true }  // step 5
                Button("Live bash", systemImage: "terminal") { showBash = true }                     // step 6
            } label: { Image(systemName: "square.stack") }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, showThinking: model.showThinking)
                            .id(turn.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.turns.last?.text) { _, _ in
                if let last = model.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            // improvement #8: scroll to bottom whenever the transcript changes
            // (e.g. after loading a session history) so the latest turn is visible.
            .onChange(of: model.turns.count) { _, _ in
                if let last = model.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(model.running ? "Steer the run…" : "Message the agent…",
                      text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(sendTapped)

            // Dictation (works on iOS, iPadOS, Mac Catalyst).
            if dictation.isAvailable {
                Button(action: toggleDictation) {
                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(dictation.isRecording ? .red : .accentColor)
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                }
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Start dictation")
            }

            if model.running {
                Button(role: .destructive) { model.abort() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
            }
            Button(action: sendTapped) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !model.connected)
        }
        .padding(8)
    }

    private func sendTapped() {
        if dictation.isRecording { dictation.stop() }
        let text = input
        input = ""
        if model.running { model.steer(text) } else { model.send(text) }
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        dictationBase = input.isEmpty ? "" : input + " "
        dictation.onText = { transcript in
            input = dictationBase + transcript
        }
        inputFocused = true
        dictation.start()
    }
}

struct TurnView: View {
    let turn: ChatModel.Turn
    let showThinking: Bool

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.text)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(turn.timestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                // Reasoning is ALWAYS available as a collapsible block so a
                // thinking-only turn (no final text) is never rendered blank.
                // Auto-expand when there's no other visible content for the turn.
                if !turn.thinking.isEmpty {
                    ReasoningBlock(text: turn.thinking,
                                   defaultExpanded: showThinking || turn.text.isEmpty)
                }
                if !turn.tools.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(turn.tools, id: \.self) { ToolBadge(name: $0) }
                        }
                    }
                }
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .textSelection(.enabled)
                    // improvement #2: copy response (via UIPasteboard — reliable across OS versions)
                    // improvement #6: copy full block (thinking + text combined)
                    Button {
                        var full = turn.text
                        if !turn.thinking.isEmpty { full = turn.thinking + "\n\n" + turn.text }
                        UIPasteboard.general.string = full
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
                // improvement #3: timestamp
                Text(turn.timestampLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // Issue #2: inline error note instead of an artifact panel entry.
                if let err = turn.toolError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err).font(.caption)
                    }
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                // Inline images from the assistant message (phase 2).
                ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                    if case .image(let data, _) = block, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFit()
                            .frame(maxWidth: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                // While streaming and nothing visible yet: spinner.
                if turn.text.isEmpty && turn.thinking.isEmpty && turn.tools.isEmpty && turn.streaming {
                    ProgressView().controlSize(.small)
                }
                // A finished turn that produced nothing visible: show a marker
                // so the conversation flow is never broken by a blank bubble.
                if !turn.streaming && turn.text.isEmpty && turn.thinking.isEmpty && turn.tools.isEmpty {
                    Text("(no output)").font(.caption).italic().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolBadge: View {
    let name: String
    var body: some View {
        Label(name, systemImage: icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.orange.opacity(0.18))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
    }
    private var icon: String {
        switch name {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write", "edit": return "pencil"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Collapsible reasoning (thinking) block

/// Always-available collapsible reasoning. Ensures a thinking-only assistant turn
/// (no final text) is never rendered as a blank bubble.
struct ReasoningBlock: View {
    let text: String
    @State private var expanded: Bool

    init(text: String, defaultExpanded: Bool) {
        self.text = text
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "brain")
                        .font(.caption2)
                    Text(expanded ? "Reasoning" : "reasoning (tap to expand)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Artifacts list (phase 2)

struct ArtifactsListView: View {
    @ObservedObject var model: ChatModel
    var onOpen: (Artifact) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.artifacts.isEmpty {
                    ContentUnavailableView("No artifacts", systemImage: "square.stack",
                                           description: Text("Diffs, files, and images appear here as the agent works."))
                } else {
                    List(model.artifacts) { a in
                        Button {
                            onOpen(a)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: a.kind)).foregroundStyle(accent(for: a.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(a.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(a.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func icon(for k: ArtifactKind) -> String {
        switch k {
        case .diff: return "doc.text.magnifyingglass"
        case .file: return "doc"
        case .image: return "photo"
        case .html: return "doc.richtext"
        case .text: return "text.alignleft"
        }
    }
    private func accent(for k: ArtifactKind) -> Color {
        switch k {
        case .diff, .file: return .orange
        case .image: return .blue
        case .html: return .purple
        case .text: return .secondary
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge (Mac)") {
                    LabeledContent("Host") {
                        TextField("100.x.y.z", text: $settings.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("8787", value: $settings.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    Toggle("Use TLS (wss://)", isOn: $settings.useTLS)
                }
                Section("Auth") {
                    SecureField("BRIDGE_TOKEN", text: $settings.token)
                }
                Section {
                    Text("Host should be your Mac's Tailscale IP (run `tailscale ip -4` on the Mac). Token must match BRIDGE_TOKEN in the bridge .env.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Connect") { settings.save(); onSave(); dismiss() }
                        .disabled(!settings.isConfigured)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
