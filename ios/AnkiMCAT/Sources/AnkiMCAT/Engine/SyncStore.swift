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
/// and server `endpoint` we show in the UI and re-send on login refresh.
///
/// `mcatToolsToken` is a later addition (the shared `X-Mcat-Token` secret for
/// the Read/Practice tabs' sync-server routes, see contracts/api.md). It has a
/// manual `init(from:)` below (rather than relying on Codable's synthesized
/// default-value support, which only applies when a key is *present but
/// null* — not when the key is missing entirely) so JSON persisted before
/// this field existed still decodes cleanly, with `mcatToolsToken` defaulting
/// to "".
struct SyncCredentials: Codable, Equatable {
    var hkey: String
    var username: String
    var endpoint: String
    var mcatToolsToken: String = ""

    init(hkey: String, username: String, endpoint: String, mcatToolsToken: String = "") {
        self.hkey = hkey
        self.username = username
        self.endpoint = endpoint
        self.mcatToolsToken = mcatToolsToken
    }

    private enum CodingKeys: String, CodingKey {
        case hkey, username, endpoint, mcatToolsToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hkey = try container.decode(String.self, forKey: .hkey)
        username = try container.decode(String.self, forKey: .username)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        mcatToolsToken = try container.decodeIfPresent(String.self, forKey: .mcatToolsToken) ?? ""
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

extension SyncStore {
    /// Update just the sync-server URL + `mcatToolsToken`, preserving any
    /// other stored fields (hkey/username survive if the user is also logged
    /// into sync). If nothing is stored yet, starts from a logged-out
    /// credential shell so the Read/Practice tabs' inline config form works
    /// even when the user has never signed into collection sync — mirrors the
    /// web round's "no separate settings dialog" precedent.
    static func saveToolsToken(_ token: String, endpoint: String? = nil) {
        var creds = load() ?? SyncCredentials(hkey: "", username: "", endpoint: endpoint ?? "")
        if let endpoint, !endpoint.isEmpty {
            creds.endpoint = endpoint
        }
        creds.mcatToolsToken = token
        save(creds)
    }
}
