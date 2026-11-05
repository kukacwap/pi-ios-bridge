import Foundation
import SwiftUI

/// One connection config, Codable so it can live as a single Keychain blob.
struct BridgeConfig: Codable {
    var host: String
    var port: Int
    var useTLS: Bool
    var token: String
}

/// Connection settings synced across the user's devices via iCloud Keychain
/// (synchronizable items — no iCloud entitlement or App ID capability required).
///
/// Safety rules so an empty/partial sync record can't clobber a good config:
///  - WRITE the synced record only when the config is complete (host + token).
///  - READ only non-empty fields from a synced record, merged over local values.
///  - A device-local (non-synced) copy is the fallback so it works offline.
@MainActor
final class AppSettings: ObservableObject {
    @Published var host: String = defaultHost
    @Published var port: Int = 8787
    @Published var useTLS: Bool = false
    @Published var token: String = ""

    static let defaultHost = "100.126.26.86"   // Mac Tailscale IP
    private static let account = "bridge.config"
    private var loading = false

    init() { load() }

    var isConfigured: Bool { !host.isEmpty && port > 0 && !token.isEmpty }

    /// Merge valid, non-empty values from local + iCloud into the live fields.
    func load() {
        loading = true
        defer { loading = false }
        if let local = Keychain.loadConfig(account: Self.account, synchronizable: false) {
            apply(local)
        }
        if let cloud = Keychain.loadConfig(account: Self.account, synchronizable: true) {
            applyNonEmpty(cloud)   // never clears good values with empty cloud fields
        }
    }

    /// Call after the user edits settings (Save & Connect).
    func save() {
        guard !loading else { return }
        let cfg = BridgeConfig(host: host, port: port, useTLS: useTLS, token: token)

        // Device-local copy always (so it remembers without iCloud).
        Keychain.saveConfig(cfg, account: Self.account, synchronizable: false)

        // Publish to iCloud ONLY when complete — prevents an empty/partial record
        // from overwriting a configured device.
        if isConfigured {
            Keychain.saveConfig(cfg, account: Self.account, synchronizable: true)
        }
    }

    /// Re-read iCloud (e.g. on foreground), applying only non-empty fields.
    func refreshFromCloud() {
        if let cloud = Keychain.loadConfig(account: Self.account, synchronizable: true) {
            applyNonEmpty(cloud)
        }
    }

    private func apply(_ c: BridgeConfig) {
        host = c.host
        port = c.port > 0 ? c.port : port
        useTLS = c.useTLS
        token = c.token
    }

    private func applyNonEmpty(_ c: BridgeConfig) {
        if !c.host.trimmingCharacters(in: .whitespaces).isEmpty { host = c.host }
        if c.port > 0 { port = c.port }
        useTLS = c.useTLS
        if !c.token.trimmingCharacters(in: .whitespaces).isEmpty { token = c.token }
    }
}

/// Keychain wrapper supporting device-local and iCloud-synced (synchronizable) items.
enum Keychain {
    private static let service = "pi-ios-bridge"

    static func saveConfig(_ config: BridgeConfig, account: String, synchronizable: Bool) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadConfig(account: String, synchronizable: Bool) -> BridgeConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let cfg = try? JSONDecoder().decode(BridgeConfig.self, from: data) else { return nil }
        return cfg
    }
}
