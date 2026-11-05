import SwiftUI

/// Issue #3: native iPad sidebar — sessions + settings always visible.
struct SidebarView: View {
    @ObservedObject var model: ChatModel
    @EnvironmentObject var settings: AppSettings
    var onOpenSettings: () -> Void
    var onNewSession: () -> Void

    var body: some View {
        List {
            // Connection status
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text(model.connected ? "Connected" : "Disconnected")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !model.currentModel.isEmpty {
                        Text(model.currentModel)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Actions
            Section("Actions") {
                Button {
                    onNewSession()
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                }
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings…", systemImage: "gear")
                }
                if model.connected {
                    Button(role: .destructive) {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                } else {
                    Button {
                        // trigger reconnect via settings save path
                        onOpenSettings()
                    } label: {
                        Label("Connect…", systemImage: "bolt")
                    }
                }
            }

            // Sessions
            Section("Sessions (\(model.sessions.count))") {
                if model.sessions.isEmpty {
                    Text("No sessions yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.sessions) { s in
                        Button {
                            model.openSession(s)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(s.dateLabel).font(.caption2).foregroundStyle(.secondary)
                                }
                                if !s.preview.isEmpty {
                                    Text(s.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pi (local)")
        .onAppear { model.browseSessions() }
        .onChange(of: model.sessions.count) { _, _ in /* refresh on new sessions */ }
    }
}
