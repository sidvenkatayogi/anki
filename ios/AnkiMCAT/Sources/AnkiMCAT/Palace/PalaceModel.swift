// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceModel — the memory palace's UI-facing state, mirroring ReviewModel's
// shape: @MainActor @Observable, backed by the shared AnkiEngine actor (so
// card search/render/grade go through the same serialized backend as the
// reviewer) plus a PalaceStore for on-disk palaces.
//
// The engine is opened by ReviewModel.start(); the app calls onEngineReady()
// once startup finishes so the palace can talk to the collection. Palace
// capture itself never needs the engine (placing spots is geometry), only the
// card picker / study loop do — those are gated on `ready`.

import Foundation
import SwiftUI

/// A candidate card in the picker: its id and a lazily rendered label.
struct CardCandidate: Identifiable, Equatable {
    var id: Int64 { cardID }
    var cardID: Int64
    var label: String
}

/// A card rendered for the study loop.
struct RenderedCard: Equatable {
    var question: String
    var answer: String
    var css: String
}

@MainActor
@Observable
final class PalaceModel {
    @ObservationIgnored private let engine: AnkiEngine
    @ObservationIgnored private let store: PalaceStore

    /// All palaces, newest first.
    private(set) var palaces: [Palace] = []
    /// True once the shared collection is open and card queries are safe.
    private(set) var ready = false
    /// Last non-fatal error, surfaced unobtrusively in the UI.
    var lastError: String?

    init(engine: AnkiEngine = AnkiEngine(), store: PalaceStore = PalaceStore()) {
        self.engine = engine
        self.store = store
        self.palaces = store.loadAll()
    }

    // MARK: - Lifecycle

    /// Called after ReviewModel.start() has opened the backend + collection.
    func onEngineReady() {
        ready = true
        reload()
    }

    func reload() {
        palaces = store.loadAll()
    }

    func palace(_ id: UUID) -> Palace? { palaces.first { $0.id == id } }

    // MARK: - Palace CRUD

    @discardableResult
    func createPalace(name: String, capacity: Int = Palace.defaultCapacity) -> Palace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let palace = Palace(name: trimmed.isEmpty ? "Untitled place" : trimmed,
                            capacity: max(1, capacity))
        persist(palace)
        return palace
    }

    func delete(_ palace: Palace) {
        do {
            try store.delete(palace.id)
        } catch {
            lastError = "Couldn't delete palace: \(error)"
            return  // keep it in the list rather than lying about deletion
        }
        palaces.removeAll { $0.id == palace.id }
    }

    func rename(_ palace: Palace, to name: String) {
        var p = palace
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = trimmed.isEmpty ? p.name : trimmed
        persist(p)
    }

    /// Save a palace and reflect it in the in-memory list (insert or replace).
    /// Only updates the in-memory list if the disk write succeeded, so the UI
    /// never shows data as saved that never reached disk.
    private func persist(_ palace: Palace) {
        do {
            try store.save(palace)
        } catch {
            lastError = "Couldn't save palace: \(error)"
            return
        }
        if let i = palaces.firstIndex(where: { $0.id == palace.id }) {
            palaces[i] = palace
        } else {
            palaces.insert(palace, at: 0)
        }
    }

    // MARK: - Loci

    /// Attach a card to a new spot in a palace. Returns false (and sets
    /// lastError) if the palace is full. Renders the card's question once to
    /// cache a display label.
    @discardableResult
    func addLocus(
        toPalace palaceID: UUID,
        cardID: Int64,
        transform: [Float]? = nil,
        anchorID: String? = nil,
        point: PalacePoint,
        mnemonic: String = ""
    ) async -> Bool {
        guard let existing = palace(palaceID) else { return false }
        guard PalaceLogic.canPlace(in: existing) else {
            lastError = "\(existing.name) is full — capture a new place to keep going."
            return false
        }
        let label = await label(for: cardID)
        // Re-fetch after the await so a concurrent edit to the same palace
        // isn't clobbered, and re-check capacity against the fresh copy.
        guard var palace = palace(palaceID) else { return false }
        guard PalaceLogic.canPlace(in: palace) else {
            lastError = "\(palace.name) is full — capture a new place to keep going."
            return false
        }
        let locus = Locus(cardID: cardID, label: label, mnemonic: mnemonic,
                          transform: transform, anchorID: anchorID, point: point)
        palace.loci.append(locus)
        persist(palace)
        return true
    }

    func removeLocus(_ locusID: UUID, fromPalace palaceID: UUID) {
        guard var palace = palace(palaceID) else { return }
        palace.loci.removeAll { $0.id == locusID }
        persist(palace)
    }

    func setMnemonic(_ text: String, locusID: UUID, palaceID: UUID) {
        guard var palace = palace(palaceID),
              let i = palace.loci.firstIndex(where: { $0.id == locusID }) else { return }
        palace.loci[i].mnemonic = text
        persist(palace)
    }

    func markLearned(_ learned: Bool, locusID: UUID, palaceID: UUID) {
        guard var palace = palace(palaceID),
              let i = palace.loci.firstIndex(where: { $0.id == locusID }) else { return }
        palace.loci[i].learned = learned
        persist(palace)
    }

    // MARK: - Photo / world map blobs

    /// Save a UIImage as the palace's reference photo (e.g. the sample room).
    func savePhoto(_ image: UIImage, forPalace palaceID: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            lastError = "Couldn't encode photo."
            return
        }
        savePhoto(data, forPalace: palaceID)
    }

    func savePhoto(_ data: Data, forPalace palaceID: UUID) {
        guard var palace = palace(palaceID) else { return }
        do {
            try store.savePhoto(data, for: palaceID)
            palace.hasPhoto = true
            palace.photoVersion = (palace.photoVersion ?? 0) + 1
            persist(palace)
        } catch {
            lastError = "Couldn't save photo: \(error)"
        }
    }

    func photoData(forPalace palaceID: UUID) -> Data? {
        store.loadPhotoData(for: palaceID)
    }

    func saveWorldMap(_ data: Data, forPalace palaceID: UUID) {
        guard var palace = palace(palaceID) else { return }
        do {
            try store.saveWorldMap(data, for: palaceID)
            palace.hasWorldMap = true
            persist(palace)
        } catch {
            lastError = "Couldn't save spatial map: \(error)"
        }
    }

    func worldMapData(forPalace palaceID: UUID) -> Data? {
        store.loadWorldMap(for: palaceID)
    }

    // MARK: - Card queries (engine)

    /// Card ids matching an Anki search string; empty query returns all cards.
    func searchCardIDs(_ query: String) async -> [Int64] {
        guard ready else { return [] }
        do {
            return try await engine.searchCards(query)
        } catch {
            lastError = "Card search failed: \(error)"
            return []
        }
    }

    /// A short label for a card (its rendered question, HTML-stripped). Returns
    /// a placeholder if the card can't be rendered (e.g. deleted since pinning).
    func label(for cardID: Int64) async -> String {
        do {
            let rendered = try await engine.render(cardID: cardID)
            return PalaceLogic.label(fromHTML: rendered.question)
        } catch {
            return "Card #\(cardID) (unavailable)"
        }
    }

    /// Full render for the study reveal; nil if the card is gone.
    func renderCard(_ cardID: Int64) async -> RenderedCard? {
        do {
            let r = try await engine.render(cardID: cardID)
            return RenderedCard(question: r.question, answer: r.answer, css: r.css)
        } catch {
            return nil
        }
    }

    /// Grade a pinned card through the real FSRS scheduler. Returns success.
    @discardableResult
    func grade(cardID: Int64, rating: Anki_Scheduler_CardAnswer.Rating) async -> Bool {
        guard ready else {
            lastError = "Collection isn't ready yet."
            return false
        }
        do {
            _ = try await engine.gradeCard(cardID: cardID, rating: rating)
            return true
        } catch {
            lastError = "Grading failed: \(error)"
            return false
        }
    }
}
