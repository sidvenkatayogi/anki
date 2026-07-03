// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// SettingsModel — per-device settings for automatic (voice + AI) grading.
// The enable flag is a plain preference (UserDefaults); the OpenAI API key is a
// secret, so it lives in the Keychain (mirroring SyncStore). Nothing here syncs
// with the collection — it is local to this device.

import Foundation

/// Persistence for the automatic-grading settings.
enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let autoGradeDefaultsKey = "autoGradeEnabled"

    static var autoGradeEnabled: Bool {
        get { defaults.bool(forKey: autoGradeDefaultsKey) }
        set { defaults.set(newValue, forKey: autoGradeDefaultsKey) }
    }

    // Keychain-backed OpenAI key (a single generic-password item).
    private static let service = "net.ankiweb.mcat.openai"
    private static let account = "apiKey"

    static var openAIKey: String {
        get {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8)
            else { return "" }
            return key
        }
        set {
            SecItemDelete(baseQuery() as CFDictionary)
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            var attrs = baseQuery()
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Observable wrapper the Settings screen binds to; writes straight through to
/// `SettingsStore` so changes take effect immediately for the review loop.
@MainActor
@Observable
final class SettingsModel {
    var autoGradeEnabled: Bool {
        didSet { SettingsStore.autoGradeEnabled = autoGradeEnabled }
    }

    var openAIKey: String {
        didSet { SettingsStore.openAIKey = openAIKey }
    }

    init() {
        autoGradeEnabled = SettingsStore.autoGradeEnabled
        openAIKey = SettingsStore.openAIKey
    }

    /// Automatic grading only runs when it's enabled *and* a key is present;
    /// otherwise the review loop falls back to manual grading.
    var autoGradeActive: Bool {
        autoGradeEnabled
            && !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
