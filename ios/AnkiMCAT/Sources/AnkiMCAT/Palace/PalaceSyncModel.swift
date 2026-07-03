// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceSyncModel — pushes memory palaces to the self-hosted mcat_tools sync
// server (contracts/api.md `PUT /palaces/{id}` + `PUT /palaces/{id}/photo`),
// mirroring ReadModel's HTTP-client style (URLSession, X-Mcat-Token header,
// `{"error":{"code","message"}}` envelope, endpoint normalization). Simpler
// than ReadModel: there's no view-facing phase machine, just a silent,
// fire-and-forget push per AC3 — a failed push must never surface an error or
// block the UI; the next local save (or the next launch's `pushAll`)
// naturally retries with the latest state.
//
// Namespacing (see contracts/api.md's "AMENDMENT (validation round, C1 fix)"
// under Auth & namespacing): the server supports an optional `X-Mcat-User`
// header to namespace storage, reserved for a future multi-user phase. Phase
// 1 is single-user, and iOS/desktop have no reliably-equal shared per-account
// string (a stored sync username on one side isn't guaranteed to match the
// other, and a random per-install id is unknowable across devices), so this
// client deliberately omits the header on every request. The server defaults
// an absent header to the fixed namespace `"default"`
// (`sanitize_user_key(None) == "default"` in mcat_tools/palace_store.py),
// which is exactly what desktop resolves to as well (it also always omits
// the header) — so both clients land in the same namespace. Do not
// reintroduce a per-account or per-install `X-Mcat-User` value here without
// also updating desktop to send the identical string; sending mismatched
// values silently breaks sync (this file previously did exactly that — see
// C1 in this run's `04-validation.md`).
//
// The on-disk `PalaceStore` format is untouched: it uses a bare
// `JSONEncoder()`/`JSONDecoder()` (`.deferredToDate`, so `Date` fields are raw
// `Double` timestamps on disk). The wire format mcat_tools expects is
// ISO-8601 strings (contracts/data-model.md), so this file defines its own
// `Codable` DTO + its own `.iso8601`-configured encoder/decoder, entirely
// separate from `PalaceStore`'s on-disk pair.

import Foundation

@MainActor
@Observable
final class PalaceSyncModel {
    // MARK: - Wire types (contracts/data-model.md)

    private struct WirePoint: Codable {
        var x: Float
        var y: Float
    }

    private struct WireLocus: Codable {
        var id: UUID
        var cardID: Int64
        var label: String
        var mnemonic: String
        var transform: [Float]?
        var anchorID: String?
        var point: WirePoint
        var learned: Bool
    }

    private struct WirePalace: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var capacity: Int
        var loci: [WireLocus]
        var hasPhoto: Bool
        var hasWorldMap: Bool
        var photoVersion: Int?
    }

    // MARK: - State

    /// Last photoVersion successfully pushed per palace, so an unchanged
    /// photo isn't re-uploaded on every metadata save. Intentionally
    /// in-memory only (not persisted) — `pushAll()` at the next launch
    /// reconciles from scratch, which is sufficient (AC2).
    @ObservationIgnored private var lastPushedPhotoVersion: [UUID: Int] = [:]

    // `nonisolated` so `PalaceSyncModel()` can be used as a default parameter
    // value in `PalaceModel`'s initializer (default-argument expressions are
    // evaluated outside the caller's actor context regardless of the
    // enclosing type's `@MainActor` annotation); the initializer only sets up
    // empty in-memory state, so isolation doesn't matter here.
    nonisolated init() {}

    // MARK: - Wire encoding

    private static let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func wirePalace(from palace: Palace) -> WirePalace {
        WirePalace(
            id: palace.id,
            name: palace.name,
            createdAt: palace.createdAt,
            updatedAt: palace.updatedAt,
            capacity: palace.capacity,
            loci: palace.loci.map {
                WireLocus(
                    id: $0.id,
                    cardID: $0.cardID,
                    label: $0.label,
                    mnemonic: $0.mnemonic,
                    transform: $0.transform,
                    anchorID: $0.anchorID,
                    point: WirePoint(x: $0.point.x, y: $0.point.y),
                    learned: $0.learned
                )
            },
            hasPhoto: palace.hasPhoto,
            hasWorldMap: palace.hasWorldMap,
            photoVersion: palace.photoVersion
        )
    }

    // MARK: - Push

    /// Pushes one palace's metadata, then (if the photo changed since the
    /// last successful push and one is provided) its reference photo.
    /// Silent-fail throughout: network errors, non-2xx responses, and decode
    /// failures are swallowed — this must never surface in `lastError` or
    /// block the caller (AC3). Missing server config is a silent no-op.
    func push(_ palace: Palace, photoData: Data? = nil) async {
        guard let creds = SyncStore.load(), !creds.endpoint.isEmpty, !creds.mcatToolsToken.isEmpty
        else { return }

        let base = normalize(creds.endpoint)

        guard let url = URL(string: base + "palaces/" + palace.id.uuidString) else { return }
        guard let body = try? Self.wireEncoder.encode(wirePalace(from: palace)) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(creds.mcatToolsToken, forHTTPHeaderField: "X-Mcat-Token")
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }
        } catch {
            return
        }

        guard let photoData, palace.hasPhoto else { return }
        let version = palace.photoVersion ?? 0
        guard lastPushedPhotoVersion[palace.id] != version else { return }

        guard let photoURL = URL(string: base + "palaces/" + palace.id.uuidString + "/photo")
        else { return }
        var photoRequest = URLRequest(url: photoURL)
        photoRequest.httpMethod = "PUT"
        photoRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        photoRequest.setValue(creds.mcatToolsToken, forHTTPHeaderField: "X-Mcat-Token")
        photoRequest.httpBody = photoData

        do {
            let (_, response) = try await URLSession.shared.data(for: photoRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }
            lastPushedPhotoVersion[palace.id] = version
        } catch {
            return
        }
    }

    /// Launch-time reconciliation pass (AC2): push every local palace,
    /// sequentially (palace counts are small, and this avoids hammering the
    /// server with a concurrent burst on every launch).
    func pushAll(_ palaces: [Palace], photoDataProvider: (UUID) -> Data?) async {
        for palace in palaces {
            await push(palace, photoData: photoDataProvider(palace.id))
        }
    }

    // MARK: - Internals

    /// Accept "host:port" or a bare host and ensure a trailing slash (mirrors
    /// ReadModel's `normalize`).
    private func normalize(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return e }
        if !e.contains("://") { e = "http://" + e }
        if !e.hasSuffix("/") { e += "/" }
        return e
    }
}
