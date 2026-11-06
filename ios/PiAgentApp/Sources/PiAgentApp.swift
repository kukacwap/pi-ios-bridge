import SwiftUI

@main
struct PiAgentApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model: ChatModel
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize

    init() {
        // ChatModel needs settings; construct a throwaway here and rebind in onAppear.
        _model = StateObject(wrappedValue: ChatModel(settings: AppSettings()))
    }

    /// iPad / Mac window with regular width → split view (sidebar + detail).
    /// iPhone → always the single-column stack, in every orientation.
    ///
    /// Size classes alone are not enough: a Plus/Max iPhone in landscape reports
    /// a *regular* width (with compact height), so a size-class-only check put
    /// the wide split view on the phone and rebuilt the whole hierarchy on every
    /// rotation. The device idiom is fixed for the app's lifetime.
    private var usesSplitView: Bool {
        UIDevice.current.userInterfaceIdiom != .phone && hSize == .regular
    }

    var body: some View {
        Group {
            if usesSplitView {
                // iPad / large Mac window: native sidebar with sessions + settings.
                NavigationSplitView {
                    SidebarView(model: model,
                                onOpenSettings: { showSettings = true },
                                onNewSession: { model.newSession() })
                        .environmentObject(settings)
                } detail: {
                    chatDetail
                }
                // Side-by-side in both orientations: in iPad portrait the default
                // style overlays the sidebar, and it stayed over the chat after
                // picking a session (the switch looked like it did nothing).
                .navigationSplitViewStyle(.balanced)
            } else {
                // iPhone (compact): single-column stack with sheets.
                NavigationStack {
                    chatContent
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onSave: reconnect)
                .environmentObject(settings)
        }
        .onAppear {
            if settings.isConfigured { model.connect() } else { showSettings = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up a config that synced from another device via iCloud Keychain.
            if phase == .active {
                let wasConfigured = settings.isConfigured
                settings.refreshFromCloud()
                if !wasConfigured && settings.isConfigured && !model.connected {
                    model.reconfigure(settings)
                    model.connect()
                }
            }
        }
    }

    // The chat column, shared by both layouts.
    private var chatContent: some View {
        ChatView()
            .environmentObject(model)
            .navigationTitle("Pi (local)")
            .toolbar { toolbar }
    }

    // iPad detail: wrap the chat in its own navigation stack so it has a toolbar.
    private var chatDetail: some View {
        NavigationStack {
            chatContent
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Circle()
                .fill(model.connected ? .green : .red)
                .frame(width: 10, height: 10)
        }
        ToolbarItem(placement: .principal) {
            // C) Model switcher
            Menu {
                ForEach(model.availableModels) { opt in
                    Button {
                        model.selectModel(opt)
                    } label: {
                        Label(opt.name, systemImage: opt.name == model.currentModel ? "checkmark" : "cpu")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(model.currentModel.isEmpty ? "model" : model.currentModel)
                        .lineLimit(1).font(.subheadline)
                }
            }
            .disabled(model.availableModels.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New session", systemImage: "plus.bubble") { model.newSession() }
                Toggle("Show thinking", isOn: $model.showThinking)
                if AppIcons.supported {
                    Menu("App icon", systemImage: "app.badge") {
                        ForEach(AppIconOption.allCases) { opt in
                            Button {
                                AppIcons.set(opt)
                            } label: {
                                Label(opt.label,
                                      systemImage: AppIcons.current == opt ? "checkmark" : "app")
                            }
                        }
                    }
                }
                Divider()
                Button("Settings", systemImage: "gear") { showSettings = true }
                if model.connected {
                    Button("Disconnect", systemImage: "bolt.slash") { model.disconnect() }
                } else {
                    Button("Connect", systemImage: "bolt") { reconnect() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func reconnect() {
        model.disconnect()
        // Rebind model's settings to the live settings object before connecting.
        model.reconfigure(settings)
        if settings.isConfigured { model.connect() }
    }
}
