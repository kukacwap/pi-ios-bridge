import SwiftUI

// MARK: - Step 4: per-message fork

/// Lists user messages available for forking; tapping one forks the branch from it.
struct ForkSheet: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.forkMessages.isEmpty {
                    ContentUnavailableView("No fork points", systemImage: "arrow.branch",
                                           description: Text("Fork points appear after you send messages."))
                } else {
                    List(model.forkMessages) { m in
                        Button {
                            model.fork(from: m)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.text.isEmpty ? "(empty)" : m.text)
                                    .font(.subheadline).lineLimit(3)
                                Text("entry \(m.entryId.prefix(8))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fork from…")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.loadForkMessages() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Step 5: skills / prompt-template launcher

struct CommandsSheet: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.commands.isEmpty {
                    ContentUnavailableView("No commands", systemImage: "wand.and.stars",
                                           description: Text("Skills and prompt templates appear here when available."))
                } else {
                    List(model.commands) { c in
                        Button {
                            model.runCommand(c)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("/\(c.name)").font(.subheadline.weight(.medium)).monospaced()
                                    Spacer()
                                    Text(c.source).font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                if let d = c.description {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Skills & Commands")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.refreshCommands() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Step 6: live bash runner

struct BashPanel: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Live output
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.bashOutput.isEmpty ? "No output yet." : model.bashOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("end")
                    }
                    .onChange(of: model.bashOutput) { _, _ in
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                Divider()
                // Input row
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    TextField("Run a shell command…", text: $command, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(run)
                    if model.bashRunning {
                        Button(role: .destructive) { model.stopBash() } label: {
                            Image(systemName: "stop.circle.fill").font(.title2)
                        }
                    } else {
                        Button(action: run) {
                            Image(systemName: "play.fill").font(.title2)
                        }.disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(8)
            }
            .navigationTitle("Live Bash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func run() {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        model.runBash(c)
    }
}
