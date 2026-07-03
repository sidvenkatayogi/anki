// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// SyncStore — persists the sync credentials (host key + username + server URL)
// in the iOS Keychain. The host key (`hkey`) is a bearer token returned by
// SyncLogin and is what authenticates every subsequent sync, so it lives in the
// Keychain rather than UserDefaults. Stored as a single JSON item so a login is
// one atomic write and a logout is one delete.

import Foundation

/// The credentials needed to run a sync: the bearer `hkey`, plus the `username`
/// and server `endpoint` we show in the UI and re-send on login refresh. An
/// empty `endpoint` means the default AnkiWeb server. (Older builds also stored
/// a since-removed `mcatToolsToken`; extra keys in previously-persisted JSON
/// are simply ignored on decode.)
struct SyncCredentials: Codable, Equatable {
    var hkey: String
    var username: String
    var endpoint: String

    init(hkey: String, username: String, endpoint: String) {
        self.hkey = hkey
        self.username = username
        self.endpoint = endpoint
    }
}

/// Thin Keychain wrapper for a single generic-password item.
enum SyncStore {
    private static let service = "net.ankiweb.mcat.sync"
    private static let account = "primary"

    /// The currently stored credentials, or nil if logged out.
    static func load() -> SyncCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncCredentials.self, from: data)
    }

    /// True when a host key is present (used to gate sync-aware startup).
    static var isLoggedIn: Bool { load()?.hkey.isEmpty == false }

    /// Persist credentials, replacing any existing item.
    @discardableResult
    static func save(_ creds: SyncCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        // Delete-then-add keeps this idempotent across logins.
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Remove stored credentials (logout).
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
