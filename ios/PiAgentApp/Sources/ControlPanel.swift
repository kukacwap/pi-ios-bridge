import SwiftUI

/// Steps 1–3 controls: session naming, thinking level, context gauge + compact.
struct ControlPanel: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var nameText = ""

    var body: some View {
        NavigationStack {
            Form {
                // Step 1 — session naming
                Section("Session") {
                    TextField("Name this session", text: $nameText,
                              onCommit: { if !nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.nameSession(nameText) } })
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !model.sessionName.isEmpty {
                        LabeledContent("Current name", value: model.sessionName)
                    }
                    Button("Browse sessions…") { dismiss(); model.browseSessions() }
                }

                // Step 2 — thinking level
                Section("Thinking level") {
                    Picker("Level", selection: Binding(
                        get: { model.currentThinkingLevel },
                        set: { model.setThinking($0) }
                    )) {
                        ForEach(model.thinkingLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if model.thinkingLevels.isEmpty {
                        Text("Not available for this model").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Step 3 — context gauge + compact
                Section("Context") {
                    HStack {
                        ProgressView(value: Double(model.contextPercent ?? 0), total: 100)
                        Text(model.contextPercent.map { "\($0)%" } ?? "—")
                            .font(.caption.monospaced()).frame(width: 48, alignment: .trailing)
                    }
                    Button("Compact now") { model.doCompact() }
                        .disabled((model.contextPercent ?? 0) == 0)
                }
            }
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { nameText = model.sessionName }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
