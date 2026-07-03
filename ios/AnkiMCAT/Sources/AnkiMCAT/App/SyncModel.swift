// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// SyncModel — drives account login + collection/media sync on the shared
// AnkiEngine actor and publishes progress for SwiftUI. Reuses Anki's native
// sync (BackendSyncService), so the whole collection round-trips: cards + FSRS
// memory state, review log, notes, decks, and FSRS params. Media rides along.
//
// Flow: syncCollection() runs a normal (incremental) sync in one call and
// reports whether a one-way full transfer is needed instead. On first login the
// local (demo) collection is replaced by the server's via a full download; once
// both sides hold real data, a schema-level divergence asks the user which side
// wins rather than silently clobbering progress.

import Foundation
import SwiftUI

@MainActor
@Observable
final class SyncModel {
    @ObservationIgnored let engine: AnkiEngine

    /// Called after a sync changes the on-disk collection, so the reviewer /
    /// palace can rebuild their queues. Wired up by the app to ReviewModel.
    @ObservationIgnored var onCollectionChanged: (() async -> Void)?

    init(engine: AnkiEngine) {
        self.engine = engine
        self.creds = SyncStore.load()
    }

    // MARK: - Published state

    enum Phase: Equatable {
        case idle
        case working(String)          // spinner + message
        case success(String)
        case failure(String)
        case chooseDirection(String)  // ambiguous full sync — user must pick
    }

    private(set) var creds: SyncCredentials?
    private(set) var phase: Phase = .idle
    private(set) var mediaProgress: String?

    var isLoggedIn: Bool { (creds?.hkey.isEmpty == false) }
    var username: String { creds?.username ?? "" }
    var endpoint: String { creds?.endpoint ?? "" }
    var isBusy: Bool { if case .working = phase { return true }; return false }

    // Server media USN carried from the collection sync into the pending
    // full-transfer decision, so media follows a user-chosen full sync.
    private var pendingServerUsn: Int32 = 0
    private var inFlight = false

    /// The default AnkiWeb sync server, used when the user leaves the server
    /// field blank. We send this explicit URL rather than an empty endpoint:
    /// the Rust core only substitutes the AnkiWeb default for a *truly absent*
    /// endpoint, and relying on that has proven fragile on device (it surfaced
    /// as "error sending request for url ()"). An explicit, valid URL is
    /// accepted by both login and the collection sync.
    static let ankiWebEndpoint = "https://sync.ankiweb.net/"

    // MARK: - Login / logout

    /// Authenticate, persist the host key, then run the first sync (which
    /// adopts the server's collection on this device).
    func login(username: String, password: String, endpoint: String) async {
        var endpoint = normalize(endpoint)
        if endpoint.isEmpty { endpoint = Self.ankiWebEndpoint }
        // Trim surrounding whitespace/newlines the iOS keyboard or AutoFill can
        // slip in; auth is sha1(user:pass), so a stray space fails a correct login.
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .working("Signing in…")
        do {
            let auth = try await engine.syncLogin(
                username: username, password: password, endpoint: endpoint)
            let creds = SyncCredentials(hkey: auth.hkey, username: username, endpoint: endpoint)
            SyncStore.save(creds)
            self.creds = creds
            await sync(firstLogin: true)
        } catch {
            phase = .failure(describe(error))
        }
    }

    /// Forget credentials. The downloaded collection stays on device for
    /// offline study; the demo deck is not restored.
    func logout() {
        SyncStore.clear()
        creds = nil
        mediaProgress = nil
        phase = .idle
    }

    // MARK: - Sync

    /// Run a sync. On `firstLogin` a schema-level divergence resolves to a
    /// download (the device adopts the server's collection); otherwise the user
    /// is asked which side wins.
    func sync(firstLogin: Bool = false) async {
        guard !inFlight else { return }
        guard let creds, !creds.hkey.isEmpty else {
            phase = .failure("Not signed in."); return
        }
        inFlight = true
        defer { inFlight = false }

        phase = .working("Syncing…")
        mediaProgress = nil
        do {
            let resp = try await engine.syncCollection(auth: makeAuth(creds), syncMedia: true)
            // AnkiWeb load-balances accounts across sync hosts and returns the
            // shard to use for the (separate) full transfer + future syncs.
            // Adopt + persist it, or the full download/upload hits the base host
            // and fails (HTTP 303 -> "missing original size"). This mirrors what
            // desktop does with set_current_sync_url(out.new_endpoint).
            adoptNewEndpoint(resp)
            let auth = makeAuth(self.creds ?? creds)
            switch resp.required {
            case .noChanges, .normalSync:
                break  // the (incremental) sync already applied in the call above
            case .fullDownload:
                try await runFullSync(auth: auth, upload: false, serverUsn: resp.serverMediaUsn)
            case .fullUpload:
                if firstLogin {
                    // Nothing on the server yet — don't silently upload the demo.
                    pendingServerUsn = resp.serverMediaUsn
                    phase = .chooseDirection(
                        "This server has no collection yet. Upload this device's cards to it?")
                    return
                }
                try await runFullSync(auth: auth, upload: true, serverUsn: resp.serverMediaUsn)
            case .fullSync:
                if firstLogin {
                    // Adopt the server's collection on this device.
                    try await runFullSync(auth: auth, upload: false, serverUsn: resp.serverMediaUsn)
                } else {
                    pendingServerUsn = resp.serverMediaUsn
                    phase = .chooseDirection(
                        "This device and the server have diverged. Choose which one to keep.")
                    return
                }
            case .UNRECOGNIZED:
                phase = .failure("Unexpected sync response."); return
            }

            await refreshCollection()
            await pollMedia()
            phase = .success(successMessage())
        } catch {
            phase = .failure(describe(error))
        }
    }

    /// Resolve the ambiguous full-sync prompt.
    func resolveFullSync(upload: Bool) async {
        guard !inFlight, let creds else { return }
        inFlight = true
        defer { inFlight = false }
        let auth = makeAuth(creds)
        phase = .working(upload ? "Uploading…" : "Downloading…")
        do {
            try await runFullSync(auth: auth, upload: upload, serverUsn: pendingServerUsn)
            await refreshCollection()
            await pollMedia()
            phase = .success(successMessage())
        } catch {
            phase = .failure(describe(error))
        }
    }

    // MARK: - Internals

    private func runFullSync(auth: Anki_Sync_SyncAuth, upload: Bool, serverUsn: Int32) async throws {
        phase = .working(upload ? "Uploading collection…" : "Downloading collection…")
        // Passing serverUsn lets the core run a media sync after the transfer.
        try await engine.fullUploadOrDownload(auth: auth, upload: upload, serverUsn: serverUsn)
    }

    /// Poll the background media sync to completion, surfacing progress. A media
    /// error is reported but does not fail the collection sync (already done).
    private func pollMedia() async {
        for _ in 0..<600 {  // ~2 min ceiling at 200ms
            do {
                let status = try await engine.mediaSyncStatus()
                if status.hasProgress {
                    let p = status.progress
                    mediaProgress = "media · \(p.checked) checked, \(p.added) added"
                }
                if !status.active { mediaProgress = nil; return }
            } catch {
                mediaProgress = "media sync issue: \(describe(error))"
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        mediaProgress = nil
    }

    private func refreshCollection() async {
        await onCollectionChanged?()
    }

    private func makeAuth(_ c: SyncCredentials) -> Anki_Sync_SyncAuth {
        var a = Anki_Sync_SyncAuth()
        a.hkey = c.hkey
        // Always send a concrete endpoint; fall back to AnkiWeb for empty
        // (e.g. credentials stored before we defaulted blank -> AnkiWeb).
        a.endpoint = c.endpoint.isEmpty ? Self.ankiWebEndpoint : c.endpoint
        return a
    }

    /// Persist the shard endpoint the collection sync handed back (AnkiWeb
    /// spreads accounts across sync hosts), so the full transfer and later
    /// syncs target it directly instead of the base host.
    private func adoptNewEndpoint(_ resp: Anki_Sync_SyncCollectionResponse) {
        guard resp.hasNewEndpoint, !resp.newEndpoint.isEmpty,
              var updated = creds, updated.endpoint != resp.newEndpoint
        else { return }
        updated.endpoint = resp.newEndpoint
        creds = updated
        SyncStore.save(updated)
    }

    /// Accept "host:port" or a bare host and coerce to a URL the core accepts.
    private func normalize(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return e }
        if !e.contains("://") { e = "http://" + e }
        if !e.hasSuffix("/") { e += "/" }
        return e
    }

    private func successMessage() -> String {
        let now = Date().formatted(date: .omitted, time: .shortened)
        return "Last synced at \(now)"
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? AnkiEngineError { return e.description }
        return String(describing: error)
    }
}
