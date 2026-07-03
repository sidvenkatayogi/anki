// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// AnkiEngine — a thin, thread-safe Swift wrapper over the `anki-ios` C ABI
// (anki_open / anki_command / anki_free / anki_free_backend).
//
// The underlying Rust Collection is NOT thread-safe (see contracts/api.md §3
// and anki_ios.h "Threading"): all anki_command calls for a handle MUST be
// serialized. Modeling this as a Swift `actor` gives us that guarantee for
// free — every method hop is a serialized await, so no two anki_command calls
// can ever overlap on the handle. All request/response bodies are typed
// SwiftProtobuf messages (generated from proto/anki/*.proto), so we never
// hand-build wire bytes past the trivial BackendInit case.

import Foundation
import SwiftProtobuf
import AnkiIOS

/// Backend service ids, as dispatched by `Backend::run_service_method` on the
/// Rust side. These are the exact (service, method) pairs the Python bridge
/// (`out/pylib/anki/_backend_generated.py`) passes to the same entry point —
/// verified against that generated code during the C3/C4 build.
enum AnkiService {
    // service 3 = BackendCollectionService
    static let collection: UInt32 = 3
    static let openCollection: UInt32 = 0
    static let checkDatabase: UInt32 = 6

    // service 39 = BackendImportExportService
    static let importExport: UInt32 = 39
    static let importAnkiPackage: UInt32 = 2

    // service 13 = BackendSchedulerService
    static let scheduler: UInt32 = 13
    static let getQueuedCards: UInt32 = 3
    static let answerCard: UInt32 = 4
    static let getSchedulingStates: UInt32 = 23

    // service 29 = BackendSearchService
    static let search: UInt32 = 29
    static let searchCards: UInt32 = 1

    // service 27 = BackendCardRenderingService
    static let cardRendering: UInt32 = 27
    static let renderExistingCard: UInt32 = 6

    // service 7 = BackendDecksService
    static let decks: UInt32 = 7
    static let getDeckNames: UInt32 = 13
    static let setCurrentDeck: UInt32 = 22

    // service 11 = BackendDeckConfigService
    static let deckConfig: UInt32 = 11
    static let getDeckConfigsForUpdate: UInt32 = 6
    static let updateDeckConfigs: UInt32 = 7

    // service 1 = BackendSyncService. Method ids verified against
    // out/pylib/anki/_backend_generated.py (_run_command(1, N, …)).
    static let sync: UInt32 = 1
    static let syncMedia: UInt32 = 0
    static let mediaSyncStatus: UInt32 = 2
    static let syncLogin: UInt32 = 3
    static let syncStatus: UInt32 = 4
    static let syncCollection: UInt32 = 5
    static let fullUploadOrDownload: UInt32 = 6
    static let abortSync: UInt32 = 7

    // service 43 = BackendStatsService. Method id verified against
    // out/pylib/anki/_backend_generated.py's tag_mastery_raw
    // (self._run_command(43, 5, ...)).
    static let stats: UInt32 = 43
    static let tagMastery: UInt32 = 5
    static let getReviewLogs: UInt32 = 1

    // service 9 = BackendConfigService. Indices verified against
    // out/pylib/anki/_backend_generated.py (_run_command(9, N, …)).
    static let config: UInt32 = 9
    static let getConfigJson: UInt32 = 0
    static let setConfigJson: UInt32 = 1

    // service 23 = BackendNotetypesService.
    static let notetypes: UInt32 = 23
    static let addNotetype: UInt32 = 0
    static let getNotetypeIdByName: UInt32 = 10

    // service 25 = BackendNotesService.
    static let notes: UInt32 = 25
    static let newNote: UInt32 = 0
    static let addNote: UInt32 = 1
    static let updateNotes: UInt32 = 5
    static let getNote: UInt32 = 6

    // service 29 = BackendSearchService (searchNotes; searchCards is above).
    static let searchNotes: UInt32 = 2

    // service 41 = BackendMediaService.
    static let media: UInt32 = 41
    static let addMediaFile: UInt32 = 1

    // service 7 = BackendDecksService (add + lookup; the study-deck helpers
    // getDeckNames/setCurrentDeck are above).
    static let newDeck: UInt32 = 0
    static let addDeck: UInt32 = 1
    static let getDeckIdByName: UInt32 = 7
}

/// Error surfaced across the C ABI seam.
enum AnkiEngineError: Error, CustomStringConvertible {
    /// anki_open returned NULL (BackendInit decode / backend init failed).
    case openFailed
    /// Called before the backend was opened.
    case notOpen
    /// anki_command returned 1: a serialized BackendError from the Rust core.
    case backend(kind: String, message: String)
    /// anki_command returned -1: bad handle/args (should not happen in normal use).
    case argument
    /// A response protobuf failed to decode.
    case decode(String)

    var description: String {
        switch self {
        case .openFailed: return "Failed to open the Anki backend"
        case .notOpen: return "Backend is not open"
        case let .backend(kind, message): return "\(message) [\(kind)]"
        case .argument: return "Invalid argument passed to anki_command"
        case let .decode(what): return "Failed to decode \(what)"
        }
    }
}

/// Serializes every call into the Rust backend on a single actor executor,
/// satisfying the "one queue/actor per handle" threading contract.
actor AnkiEngine {
    private var handle: OpaquePointer?

    // MARK: - Lifecycle

    /// Open a backend from a BackendInit message (same bytes Python decodes).
    func open(preferredLangs: [String] = ["en"]) throws {
        if handle != nil { return }
        var initMsg = Anki_Backend_BackendInit()
        initMsg.preferredLangs = preferredLangs
        initMsg.server = false
        let bytes = try initMsg.serializedData()
        let h: OpaquePointer? = bytes.withUnsafeBytes { raw in
            anki_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard let opened = h else { throw AnkiEngineError.openFailed }
        handle = opened
    }

    /// Release the backend handle. Safe to call more than once.
    func close() {
        if let h = handle {
            anki_free_backend(h)
            handle = nil
        }
    }

    deinit {
        if let h = handle { anki_free_backend(h) }
    }

    // MARK: - Raw command dispatch (serialized by the actor)

    /// Invoke one (service, method) RPC. Copies the Rust-owned response buffer
    /// into a Swift `Data`, then releases it via `anki_free` (never Swift's
    /// native free — the buffer is from the Rust allocator).
    private func command(service: UInt32, method: UInt32, input: Data) throws -> Data {
        guard let backend = handle else { throw AnkiEngineError.notOpen }

        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: Int = 0

        let rc: Int32 = input.withUnsafeBytes { raw in
            anki_command(backend, service, method,
                         raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                         &outPtr, &outLen)
        }

        // Copy out the Rust-owned buffer (if any) then free it exactly once.
        var out = Data()
        if rc == 0 || rc == 1 {
            if let p = outPtr, outLen > 0 {
                out = Data(bytes: p, count: outLen)
            }
            anki_free(outPtr, outLen)
        }

        switch rc {
        case 0:
            return out
        case 1:
            // Serialized anki_proto::backend::BackendError.
            if let err = try? Anki_Backend_BackendError(serializedBytes: out) {
                throw AnkiEngineError.backend(kind: "\(err.kind)", message: err.message)
            }
            throw AnkiEngineError.backend(kind: "UNKNOWN", message: "backend error")
        default:
            throw AnkiEngineError.argument
        }
    }

    /// Typed helper: encode `request`, dispatch, decode into `Response`.
    private func call<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        service: UInt32, method: UInt32, _ request: Request, returning: Response.Type
    ) throws -> Response {
        let input = try request.serializedData()
        let output = try command(service: service, method: method, input: input)
        do {
            return try Response(serializedBytes: output)
        } catch {
            throw AnkiEngineError.decode(String(describing: Response.self))
        }
    }

    // MARK: - Collection

    /// Open (or create) a collection at the given sandbox paths.
    func openCollection(collectionPath: String, mediaFolderPath: String, mediaDbPath: String) throws {
        var req = Anki_Collection_OpenCollectionRequest()
        req.collectionPath = collectionPath
        req.mediaFolderPath = mediaFolderPath
        req.mediaDbPath = mediaDbPath
        _ = try call(service: AnkiService.collection, method: AnkiService.openCollection,
                     req, returning: Anki_Generic_Empty.self)
    }

    // MARK: - Import

    /// Import an .apkg from the sandbox. Returns the number of notes found in
    /// the package (ImportResponse.log.foundNotes).
    @discardableResult
    func importAnkiPackage(packagePath: String) throws -> UInt32 {
        var req = Anki_ImportExport_ImportAnkiPackageRequest()
        req.packagePath = packagePath
        // Defaults are fine for a fresh import: keep scheduling + deck configs.
        var opts = Anki_ImportExport_ImportAnkiPackageOptions()
        opts.withScheduling = true
        opts.withDeckConfigs = true
        req.options = opts
        let resp = try call(service: AnkiService.importExport, method: AnkiService.importAnkiPackage,
                            req, returning: Anki_ImportExport_ImportResponse.self)
        return resp.log.foundNotes
    }

    // MARK: - Decks

    /// All deck (id, name) pairs, excluding the empty Default deck.
    func deckNames() throws -> [Anki_Decks_DeckNameId] {
        var req = Anki_Decks_GetDeckNamesRequest()
        req.skipEmptyDefault = true
        req.includeFiltered = false
        let resp = try call(service: AnkiService.decks, method: AnkiService.getDeckNames,
                            req, returning: Anki_Decks_DeckNames.self)
        return resp.entries
    }

    /// Select the deck to study. The scheduler builds its queue from the
    /// current deck's subtree, so this must be set to a deck that has cards.
    func setCurrentDeck(_ deckID: Int64) throws {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        _ = try call(service: AnkiService.decks, method: AnkiService.setCurrentDeck,
                     req, returning: Anki_Collection_OpChanges.self)
    }

    /// Make new cards gather across every category (RANDOM_CARDS) rather than
    /// draining one subdeck at a time (the default DECK order). This mirrors the
    /// desktop "Start Flashcards" behaviour so the iOS daily new cards are spread
    /// across topics. Idempotent, and respects the daily new-card limit — it only
    /// changes the *order* cards are introduced, not how many. The apkg config
    /// round-trip does not reliably carry this field, so we set it at runtime.
    func ensureRandomCardGather(deckID: Int64) throws {
        var getReq = Anki_Decks_DeckId()
        getReq.did = deckID
        let data = try call(service: AnkiService.deckConfig,
                            method: AnkiService.getDeckConfigsForUpdate,
                            getReq, returning: Anki_DeckConfig_DeckConfigsForUpdate.self)

        var configs: [Anki_DeckConfig_DeckConfig] = []
        var changed = false
        for entry in data.allConfig {
            var cfg = entry.config
            if cfg.config.newCardGatherPriority != .randomCards {
                cfg.config.newCardGatherPriority = .randomCards
                changed = true
            }
            configs.append(cfg)
        }
        guard changed else { return }

        var upd = Anki_DeckConfig_UpdateDeckConfigsRequest()
        upd.targetDeckID = deckID
        upd.configs = configs
        upd.removedConfigIds = []
        upd.mode = .normal
        upd.cardStateCustomizer = data.cardStateCustomizer
        upd.limits = data.currentDeck.limits
        upd.newCardsIgnoreReviewLimit = data.newCardsIgnoreReviewLimit
        upd.fsrs = data.fsrs
        upd.applyAllParentLimits = data.applyAllParentLimits
        upd.fsrsReschedule = false
        upd.fsrsHealthCheck = false
        _ = try call(service: AnkiService.deckConfig,
                     method: AnkiService.updateDeckConfigs,
                     upd, returning: Anki_Collection_OpChanges.self)
    }

    // MARK: - Scheduler / review loop

    /// Fetch the current queue head. `cards` is empty when the queue is done.
    func queuedCards(fetchLimit: UInt32 = 1) throws -> Anki_Scheduler_QueuedCards {
        var req = Anki_Scheduler_GetQueuedCardsRequest()
        req.fetchLimit = fetchLimit
        req.intradayLearningOnly = false
        return try call(service: AnkiService.scheduler, method: AnkiService.getQueuedCards,
                        req, returning: Anki_Scheduler_QueuedCards.self)
    }

    /// Grade a card. Builds a CardAnswer from the queued card's scheduling
    /// states + the chosen rating (exactly as the desktop/web reviewer does),
    /// then advances the scheduler. Returns the resulting OpChanges.
    @discardableResult
    func answer(card: Anki_Scheduler_QueuedCards.QueuedCard,
                rating: Anki_Scheduler_CardAnswer.Rating,
                millisecondsTaken: UInt32 = 1000) throws -> Anki_Collection_OpChanges {
        var ans = Anki_Scheduler_CardAnswer()
        ans.cardID = card.card.id
        ans.currentState = card.states.current
        ans.newState = newState(for: rating, from: card.states)
        ans.rating = rating
        ans.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        ans.millisecondsTaken = millisecondsTaken
        return try call(service: AnkiService.scheduler, method: AnkiService.answerCard,
                        ans, returning: Anki_Collection_OpChanges.self)
    }

    private func newState(for rating: Anki_Scheduler_CardAnswer.Rating,
                          from states: Anki_Scheduler_SchedulingStates) -> Anki_Scheduler_SchedulingState {
        switch rating {
        case .again: return states.again
        case .hard: return states.hard
        case .good: return states.good
        case .easy: return states.easy
        default: return states.good
        }
    }

    // MARK: - Search / card lookup (memory palace)

    /// Return the card ids matching an Anki search string (same query syntax as
    /// the desktop browser, e.g. "deck:current", "tag:biochem", or free text).
    /// An empty query returns every card in the collection. Used by the memory
    /// palace card picker to let the user choose which card to place at a locus.
    func searchCards(_ query: String) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        // Default SortOrder is fine — the picker renders its own labels.
        let resp = try call(service: AnkiService.search, method: AnkiService.searchCards,
                            req, returning: Anki_Search_SearchResponse.self)
        return resp.ids
    }

    // MARK: - Grading an arbitrary card (memory palace → FSRS)

    /// The four candidate next states for a card in its *current* position,
    /// exactly as the reviewer previews them. Works for any card (new, learning
    /// or review), not just the ones currently queued — which is what lets the
    /// memory palace grade a pinned card on demand.
    func schedulingStates(cardID: Int64) throws -> Anki_Scheduler_SchedulingStates {
        var req = Anki_Cards_CardId()
        req.cid = cardID
        return try call(service: AnkiService.scheduler, method: AnkiService.getSchedulingStates,
                        req, returning: Anki_Scheduler_SchedulingStates.self)
    }

    /// Grade any card by id and advance the real scheduler, so memory-palace
    /// recall counts toward FSRS. Fetches the card's current scheduling states,
    /// applies the chosen rating, and round-trips answer_card — the same path
    /// the reviewer takes, generalized to a card that need not be queued.
    @discardableResult
    func gradeCard(cardID: Int64,
                   rating: Anki_Scheduler_CardAnswer.Rating) throws -> Anki_Collection_OpChanges {
        let states = try schedulingStates(cardID: cardID)
        var ans = Anki_Scheduler_CardAnswer()
        ans.cardID = cardID
        ans.currentState = states.current
        ans.newState = newState(for: rating, from: states)
        ans.rating = rating
        ans.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        ans.millisecondsTaken = 1000
        // A pinned card usually isn't the reviewer's current queue head, so
        // skip the queue pop — the scheduler would otherwise reject it with
        // "not at top of queue". The FSRS/revlog update still happens.
        ans.skipQueue = true
        return try call(service: AnkiService.scheduler, method: AnkiService.answerCard,
                        ans, returning: Anki_Collection_OpChanges.self)
    }

    // MARK: - Rendering

    /// Render a card's question + answer HTML by concatenating the rendered
    /// template nodes (literal text + resolved field replacements).
    func render(cardID: Int64) throws -> (question: String, answer: String, css: String) {
        var req = Anki_CardRendering_RenderExistingCardRequest()
        req.cardID = cardID
        req.browser = false
        req.partialRender = false
        let resp = try call(service: AnkiService.cardRendering, method: AnkiService.renderExistingCard,
                            req, returning: Anki_CardRendering_RenderCardResponse.self)
        return (assemble(resp.questionNodes), assemble(resp.answerNodes), resp.css)
    }

    private func assemble(_ nodes: [Anki_CardRendering_RenderedTemplateNode]) -> String {
        var html = ""
        for node in nodes {
            switch node.value {
            case let .text(t): html += t
            case let .replacement(r): html += r.currentText
            case .none: break
            }
        }
        return html
    }

    // MARK: - Sync (BackendSyncService, service 1)
    //
    // The sync HTTP is performed inside the Rust core (reqwest + its own TLS),
    // not by Swift URLSession — so these are ordinary anki_command round-trips
    // and iOS App Transport Security does not apply to the sync traffic. The
    // whole collection is synced (cards + FSRS memory state, revlog, notes,
    // decks, deck config/FSRS params); media rides along when `syncMedia` is set.

    /// Exchange username/password for a host key (`hkey`). The returned auth
    /// (hkey + endpoint) must be persisted and supplied to every later call.
    func syncLogin(username: String, password: String, endpoint: String?) throws -> Anki_Sync_SyncAuth {
        var req = Anki_Sync_SyncLoginRequest()
        req.username = username
        req.password = password
        if let endpoint, !endpoint.isEmpty { req.endpoint = endpoint }
        return try call(service: AnkiService.sync, method: AnkiService.syncLogin,
                        req, returning: Anki_Sync_SyncAuth.self)
    }

    /// Lightweight check of what a sync would do (no changes / normal / full),
    /// without transferring anything.
    func syncStatus(auth: Anki_Sync_SyncAuth) throws -> Anki_Sync_SyncStatusResponse {
        try call(service: AnkiService.sync, method: AnkiService.syncStatus,
                 auth, returning: Anki_Sync_SyncStatusResponse.self)
    }

    /// Run a normal (incremental) collection sync. When `syncMedia` is true the
    /// Rust core kicks off a background media sync afterwards (poll it with
    /// `mediaSyncStatus()`). The response's `required` tells the caller whether a
    /// full upload/download is needed instead.
    func syncCollection(auth: Anki_Sync_SyncAuth, syncMedia: Bool) throws -> Anki_Sync_SyncCollectionResponse {
        var req = Anki_Sync_SyncCollectionRequest()
        req.auth = auth
        req.syncMedia = syncMedia
        return try call(service: AnkiService.sync, method: AnkiService.syncCollection,
                        req, returning: Anki_Sync_SyncCollectionResponse.self)
    }

    /// One-way full transfer used when collections have diverged at the schema
    /// level (or one side is empty — e.g. first login). The Rust core closes and
    /// re-opens the collection internally, so callers only need to refresh their
    /// UI afterward. Pass `serverUsn` (from SyncCollectionResponse.serverMediaUsn)
    /// so a media sync follows the transfer; omit it to skip media.
    func fullUploadOrDownload(auth: Anki_Sync_SyncAuth, upload: Bool, serverUsn: Int32?) throws {
        var req = Anki_Sync_FullUploadOrDownloadRequest()
        req.auth = auth
        req.upload = upload
        if let serverUsn { req.serverUsn = serverUsn }
        _ = try call(service: AnkiService.sync, method: AnkiService.fullUploadOrDownload,
                     req, returning: Anki_Generic_Empty.self)
    }

    /// Poll the background media sync started by `syncCollection`/full transfer.
    /// `active` is false once it has finished; a prior media error is surfaced as
    /// a thrown backend error on the next call.
    func mediaSyncStatus() throws -> Anki_Sync_MediaSyncStatusResponse {
        try call(service: AnkiService.sync, method: AnkiService.mediaSyncStatus,
                 Anki_Generic_Empty(), returning: Anki_Sync_MediaSyncStatusResponse.self)
    }

    /// Abort an in-flight collection sync.
    func abortSync() throws {
        _ = try call(service: AnkiService.sync, method: AnkiService.abortSync,
                     Anki_Generic_Empty(), returning: Anki_Generic_Empty.self)
    }

    // MARK: - Stats (BackendStatsService, service 43)

    /// FSRS mastery/recall rolled up per tag group, used by the Practice tab's
    /// Readiness computation (see contracts/data-model.md "FsrsCategorySummary").
    /// `groupDepth` controls how many `::`-separated tag components form each
    /// returned `Group` (this fork groups at depth 2 — see plan-ios.md's tag
    /// mapping deviation note).
    func tagMastery(groupDepth: UInt32, masteredThreshold: Double = 0,
                    search: String = "") throws -> Anki_Stats_TagMasteryResponse {
        var req = Anki_Stats_TagMasteryRequest()
        req.groupDepth = groupDepth
        req.masteredThreshold = masteredThreshold
        req.search = search
        return try call(service: AnkiService.stats, method: AnkiService.tagMastery,
                        req, returning: Anki_Stats_TagMasteryResponse.self)
    }

    /// The revlog for one card. Used by the Practice tab to reconstruct answer
    /// history from the (synced) review log — `buttonChosen >= 3` (Good/Easy)
    /// counts as a correct answer, `1`/`2` (Again/Hard) as incorrect, and `0`
    /// (non-answer entries like manual reschedules) is ignored by the caller.
    func reviewLogs(cardID: Int64) throws -> [Anki_Stats_CardStatsResponse.StatsRevlogEntry] {
        var req = Anki_Cards_CardId()
        req.cid = cardID
        let resp = try call(service: AnkiService.stats, method: AnkiService.getReviewLogs,
                            req, returning: Anki_Stats_ReviewLogs.self)
        return resp.entries
    }

    // MARK: - Config (BackendConfigService, service 9)
    //
    // Small synced per-collection scalars (e.g. the practice-bank seed marker)
    // live in the collection config map, so they ride the same native sync as
    // cards/notes/media.

    /// Read a JSON config value by key, or nil if unset. A missing key surfaces
    /// as a backend NotFound error from the core, which we translate to nil.
    func getConfigJson(key: String) throws -> Data? {
        var req = Anki_Generic_String()
        req.val = key
        do {
            let resp = try call(service: AnkiService.config, method: AnkiService.getConfigJson,
                                req, returning: Anki_Generic_Json.self)
            return resp.json
        } catch AnkiEngineError.backend(_, _) {
            return nil
        }
    }

    /// Write a JSON config value by key. Not undoable — seeding/config writes
    /// aren't user actions worth an undo entry.
    func setConfigJson(key: String, valueJson: Data) throws {
        var req = Anki_Config_SetConfigJsonRequest()
        req.key = key
        req.valueJson = valueJson
        req.undoable = false
        _ = try call(service: AnkiService.config, method: AnkiService.setConfigJson,
                     req, returning: Anki_Collection_OpChanges.self)
    }

    // MARK: - Notetypes (BackendNotetypesService, service 23)

    /// The notetype id for a name, or nil if no such notetype exists.
    func notetypeIdByName(_ name: String) throws -> Int64? {
        var req = Anki_Generic_String()
        req.val = name
        do {
            let resp = try call(service: AnkiService.notetypes,
                                method: AnkiService.getNotetypeIdByName,
                                req, returning: Anki_Notetypes_NotetypeId.self)
            return resp.ntid == 0 ? nil : resp.ntid
        } catch AnkiEngineError.backend(_, _) {
            return nil
        }
    }

    /// Add a notetype from a fully-specified proto. The core normalizes field/
    /// template names and computes card requirements itself, so callers only
    /// need to supply the name, fields, and templates. Returns the new id.
    @discardableResult
    func addNotetype(_ notetype: Anki_Notetypes_Notetype) throws -> Int64 {
        let resp = try call(service: AnkiService.notetypes, method: AnkiService.addNotetype,
                            notetype, returning: Anki_Collection_OpChangesWithId.self)
        return resp.id
    }

    // MARK: - Notes (BackendNotesService, service 25)

    /// A blank note for the given notetype (correct number of empty fields).
    func newNote(notetypeID: Int64) throws -> Anki_Notes_Note {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = notetypeID
        return try call(service: AnkiService.notes, method: AnkiService.newNote,
                        req, returning: Anki_Notes_Note.self)
    }

    /// Add a note to a deck. Returns the new note id.
    @discardableResult
    func addNote(_ note: Anki_Notes_Note, deckID: Int64) throws -> Int64 {
        var req = Anki_Notes_AddNoteRequest()
        req.note = note
        req.deckID = deckID
        let resp = try call(service: AnkiService.notes, method: AnkiService.addNote,
                            req, returning: Anki_Notes_AddNoteResponse.self)
        return resp.noteID
    }

    /// Update existing notes in place (fields/tags). No undo entry.
    func updateNotes(_ notes: [Anki_Notes_Note]) throws {
        var req = Anki_Notes_UpdateNotesRequest()
        req.notes = notes
        req.skipUndoEntry = true
        _ = try call(service: AnkiService.notes, method: AnkiService.updateNotes,
                     req, returning: Anki_Collection_OpChanges.self)
    }

    /// Fetch a note by id (fields + tags + notetype id).
    func getNote(noteID: Int64) throws -> Anki_Notes_Note {
        var req = Anki_Notes_NoteId()
        req.nid = noteID
        return try call(service: AnkiService.notes, method: AnkiService.getNote,
                        req, returning: Anki_Notes_Note.self)
    }

    /// Note ids matching an Anki search string (same syntax as `searchCards`).
    func searchNotes(_ query: String) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        let resp = try call(service: AnkiService.search, method: AnkiService.searchNotes,
                            req, returning: Anki_Search_SearchResponse.self)
        return resp.ids
    }

    // MARK: - Media (BackendMediaService, service 41)

    /// Write a media file into the collection's media folder (synced). Returns
    /// the actual stored filename, which may differ from `desiredName` on a
    /// content collision.
    @discardableResult
    func addMediaFile(desiredName: String, data: Data) throws -> String {
        var req = Anki_Media_AddMediaFileRequest()
        req.desiredName = desiredName
        req.data = data
        let resp = try call(service: AnkiService.media, method: AnkiService.addMediaFile,
                            req, returning: Anki_Generic_String.self)
        return resp.val
    }

    // MARK: - Decks (BackendDecksService, service 7)

    /// Get a deck id by full name, creating the deck if it doesn't exist.
    /// Used to keep the MCAT practice/palace cards in their own decks, out of
    /// the normal study queue.
    @discardableResult
    func ensureDeck(name: String) throws -> Int64 {
        var lookup = Anki_Generic_String()
        lookup.val = name
        if let existing = try? call(service: AnkiService.decks,
                                    method: AnkiService.getDeckIdByName,
                                    lookup, returning: Anki_Decks_DeckId.self),
           existing.did != 0 {
            return existing.did
        }
        var deck = try call(service: AnkiService.decks, method: AnkiService.newDeck,
                            Anki_Generic_Empty(), returning: Anki_Decks_Deck.self)
        deck.name = name
        let resp = try call(service: AnkiService.decks, method: AnkiService.addDeck,
                            deck, returning: Anki_Collection_OpChangesWithId.self)
        return resp.id
    }
}
