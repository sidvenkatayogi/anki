// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ReviewModel — the app's single source of truth. Drives the C3 (open +
// import) and C4 (review loop) flows through the shared Rust engine.
//
// Owns the AnkiEngine actor and exposes @MainActor UI state. All backend work
// hops onto the actor (serialized per the threading contract); results are
// published back on the main actor for SwiftUI to render.

import Foundation
import SwiftUI

/// High-level phase the UI renders.
enum ReviewPhase: Equatable {
    case launching          // opening backend / collection / importing
    case reviewing          // a card is on screen
    case finished           // queue empty — congrats
    case failed(String)     // a setup/RPC error to surface
}

@MainActor
@Observable
final class ReviewModel {
    // Engine is created once and reused; not observed (it's an actor). Injected
    // so the memory-palace feature can share the same opened backend/collection
    // (a single actor also keeps every backend call serialized per the contract).
    @ObservationIgnored let engine: AnkiEngine
    // Per-device automatic-grading settings (enabled flag + OpenAI key).
    @ObservationIgnored let settings: SettingsModel

    /// Live on-device speech recognizer used for spoken answers.
    let voice = VoiceAnswerRecorder()

    init(engine: AnkiEngine = AnkiEngine(),
         settings: SettingsModel? = nil) {
        self.engine = engine
        // Constructed here (inside the main-actor init) rather than as a default
        // argument, which would run in a nonisolated context and not compile.
        self.settings = settings ?? SettingsModel()
    }

    // UI state.
    private(set) var phase: ReviewPhase = .launching
    private(set) var statusLine: String = "Starting…"
    private(set) var importedNotes: UInt32 = 0

    // Current card being reviewed.
    private(set) var currentCard: Anki_Scheduler_QueuedCards.QueuedCard?
    private(set) var questionHTML: String = ""
    private(set) var answerHTML: String = ""
    private(set) var cardCSS: String = ""
    private(set) var showingAnswer: Bool = false

    // Remaining queue counts (for a lightweight progress readout).
    private(set) var newCount: UInt32 = 0
    private(set) var learningCount: UInt32 = 0
    private(set) var reviewCount: UInt32 = 0

    // Automatic-grading UI state.
    private(set) var autoGrading = false          // LLM request in flight
    private(set) var autoGradeMessage: String?    // verdict / error to surface
    @ObservationIgnored private var cardShownAt: Date?  // for response timing

    // MARK: - C3: launch → open backend, open/create collection, import apkg

    /// Full startup: open the backend and collection, then either import the
    /// bundled demo deck (signed out) or leave the collection for SyncModel to
    /// populate from the server (signed in — login-and-download model).
    func start() async {
        do {
            phase = .launching
            statusLine = "Opening backend…"
            try await engine.open(preferredLangs: ["en"])

            let paths = try sandboxPaths()

            // Sync-backed: never wipe or import the demo deck — that would fight
            // the synced collection. Open whatever is on disk (create an empty
            // collection on first run); SyncModel pulls the real collection and
            // then calls reloadAfterSync() to build the queue.
            if SyncStore.isLoggedIn {
                statusLine = "Opening collection…"
                try await engine.openCollection(
                    collectionPath: paths.collection,
                    mediaFolderPath: paths.mediaFolder,
                    mediaDbPath: paths.mediaDB
                )
                try? await selectStudyDeck()
                await advanceToNextCard()
                return
            }

            // Signed out: bundled demo-deck experience.
            let deck = try bundledDeck()
            // Import once: only (re)import when this deck hasn't been imported
            // yet, so we don't duplicate cards on every launch. Switching decks
            // (e.g. sample -> milesdown) starts from a clean collection.
            let needImport = importedDeckMarker() != deck.name
            if needImport {
                try clearCollection(paths)
            }
            statusLine = "Opening collection…"
            try await engine.openCollection(
                collectionPath: paths.collection,
                mediaFolderPath: paths.mediaFolder,
                mediaDbPath: paths.mediaDB
            )

            if needImport {
                statusLine = "Importing \(deck.name)…"
                let staged = try stageApkg(deck.url)
                importedNotes = try await engine.importAnkiPackage(packagePath: staged)
                try? FileManager.default.removeItem(atPath: staged)
                writeImportedDeckMarker(deck.name)
                statusLine = "Imported \(importedNotes) note(s)."
            }

            // The scheduler builds its queue from the CURRENT deck's subtree.
            // Right after import the current deck is the empty "Default", so we
            // must select the deck that actually holds the cards, or the queue
            // is empty ("All caught up") even though notes were imported.
            try await selectStudyDeck()

            await advanceToNextCard()
        } catch {
            phase = .failed(String(describing: error))
            statusLine = "Error: \(error)"
        }
    }

    /// Rebuild the study queue after a sync changed the on-disk collection (the
    /// Rust core has already re-opened the collection in place, so we only need
    /// to re-select a study deck and re-render the current card).
    func reloadAfterSync() async {
        // A full download clears the "imported demo" marker's relevance; the
        // demo won't be re-imported while signed in.
        try? await selectStudyDeck()
        await advanceToNextCard()
    }

    // MARK: - C4: review loop

    func revealAnswer() {
        showingAnswer = true
    }

    func answer(_ rating: Anki_Scheduler_CardAnswer.Rating) async {
        guard let card = currentCard else { return }
        do {
            _ = try await engine.answer(
                card: card,
                rating: rating,
                millisecondsTaken: UInt32(clamping: elapsedMillis())
            )
            await advanceToNextCard()
        } catch {
            phase = .failed(String(describing: error))
            statusLine = "Answer failed: \(error)"
        }
    }

    /// Surfaces the result of a "Didn't Learn" action (e.g. "Suspended 20
    /// cards") or an error, mirroring `autoGradeMessage`.
    private(set) var didntLearnMessage: String?

    /// Mark the current card's topic(s) as never learned — tags + suspends every
    /// card in the topic and moves them to the To Learn list, then advances.
    /// Topic-level and destructive, so the view confirms before calling this.
    func markDidntLearn() async {
        guard let card = currentCard else { return }
        do {
            let changes = try await engine.setNeverLearned(cardID: card.card.id)
            didntLearnMessage = changes.count == 1
                ? "Moved 1 card to To Learn"
                : "Moved \(changes.count) cards to To Learn"
            await advanceToNextCard()
        } catch {
            didntLearnMessage = "Couldn't mark as not learned: \(error.localizedDescription)"
        }
    }

    /// True when a spoken transcript is the "didn't learn" voice command rather
    /// than an answer to grade. Matched before the LLM grader so the phrase never
    /// gets scored as a (wrong) answer.
    static func isDidntLearnPhrase(_ spoken: String) -> Bool {
        let normalized = spoken
            .lowercased()
            .replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let phrases = [
            "didnt learn", "did not learn", "didn t learn",
            "never learned", "havent learned", "have not learned",
            "to learn",
        ]
        return phrases.contains(normalized)
    }

    // MARK: - C4: automatic (voice + AI) grading

    /// Start listening for a spoken answer.
    func startVoiceInput() async {
        await voice.start()
    }

    /// The automatic-grading equivalent of "press enter": stop listening, reveal
    /// the answer, have the LLM judge the transcript, and apply the rating —
    /// Again if wrong, otherwise Hard/Good/Easy by how fast they answered.
    /// Falls back to manual grading (answer shown, buttons available) when
    /// there's nothing to grade or the LLM call fails.
    func submitVoiceAnswer() async {
        guard let card = currentCard else { return }
        let spoken = voice.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = elapsedMillis()
        showingAnswer = true

        guard !spoken.isEmpty else {
            autoGradeMessage = "Didn't catch an answer — grade it yourself."
            return
        }

        // Voice command: saying "didn't learn" marks the topic as never learned
        // instead of grading the transcript. Reuses the AI-grading voice path, so
        // it's active whenever automatic grading is.
        if Self.isDidntLearnPhrase(spoken) {
            await markDidntLearn()
            return
        }

        autoGrading = true
        autoGradeMessage = nil
        let question = Self.plainText(questionHTML)
        let expected = Self.plainText(answerHTML)

        do {
            let verdict = try await LLMGrader.grade(
                question: question,
                expected: expected,
                provided: spoken,
                apiKey: settings.openAIKey
            )
            let rating: Anki_Scheduler_CardAnswer.Rating =
                verdict.correct ? LLMGrader.ease(fromElapsed: elapsed) : .again
            autoGrading = false
            _ = try await engine.answer(
                card: card,
                rating: rating,
                millisecondsTaken: UInt32(clamping: elapsed)
            )
            await advanceToNextCard()
        } catch {
            autoGrading = false
            autoGradeMessage = "Auto-grade unavailable: \(error.localizedDescription)"
            // answer stays revealed; the view shows manual buttons as a fallback
        }
    }

    private func elapsedMillis() -> Int {
        guard let shown = cardShownAt else { return 1000 }
        return max(0, Int(Date().timeIntervalSince(shown) * 1000))
    }

    /// Reduce card HTML to readable text for the grader.
    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch the next queued card (or finish), and render its Q/A.
    private func advanceToNextCard() async {
        do {
            let queue = try await engine.queuedCards(fetchLimit: 1)
            newCount = queue.newCount
            learningCount = queue.learningCount
            reviewCount = queue.reviewCount

            guard let head = queue.cards.first else {
                currentCard = nil
                showingAnswer = false
                phase = .finished
                statusLine = "All caught up."
                return
            }

            let rendered = try await engine.render(cardID: head.card.id)
            currentCard = head
            questionHTML = rendered.question
            answerHTML = rendered.answer
            cardCSS = rendered.css
            showingAnswer = false
            phase = .reviewing
            // Reset per-card automatic-grading state and start the response timer.
            cardShownAt = Date()
            autoGrading = false
            autoGradeMessage = nil
            voice.reset()
        } catch {
            phase = .failed(String(describing: error))
            statusLine = "Failed to load next card: \(error)"
        }
    }

    /// Select a deck that actually contains cards to study. Prefers a
    /// top-level deck (no "::" in its name) other than the empty Default — its
    /// subtree spans every category — so "study everything" works. Falls back
    /// to whatever deck exists.
    private func selectStudyDeck() async throws {
        let names = try await engine.deckNames()  // Default already excluded
        // Exclude the MCAT practice/palace decks — their cards are graded only
        // from the Practice/Palace tabs and must never enter the study queue.
        let studyable = names.filter { $0.name != "MCAT" && !$0.name.hasPrefix("MCAT::") }
        guard !studyable.isEmpty else { return }
        let topLevel = studyable.first(where: { !$0.name.contains("::") })
        let chosen = topLevel ?? studyable[0]
        try await engine.setCurrentDeck(chosen.id)
        // Spread new cards across every category instead of draining one subdeck
        // first (matches the desktop "Start Flashcards" interleaving).
        try await engine.ensureRandomCardGather(deckID: chosen.id)
    }

    // MARK: - Sandbox / bundled resource staging

    private struct CollectionPaths {
        let collection: String
        let mediaFolder: String
        let mediaDB: String
    }

    /// Build (and ensure the directory for) the collection paths under the
    /// app's Documents sandbox. iOS storage guards (cfg(ios)) in rslib allow
    /// SQLite/WAL here.
    private func sandboxPaths() throws -> CollectionPaths {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let mediaFolder = docs.appendingPathComponent("collection.media", isDirectory: true)
        try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        return CollectionPaths(
            collection: docs.appendingPathComponent("collection.anki2").path,
            mediaFolder: mediaFolder.path,
            mediaDB: docs.appendingPathComponent("collection.media.db2").path
        )
    }

    /// The bundled deck to study. Prefers the real MileDown deck (a
    /// media-stripped export, ~0.6 MB, bundled as milesdown.apkg) so the app
    /// shows real MCAT card content; falls back to the tiny built-in test deck
    /// (sample.apkg) if MileDown wasn't bundled. Images won't render (media was
    /// stripped to keep the bundle small), but all card text is present.
    private func bundledDeck() throws -> (url: URL, name: String) {
        if let u = Bundle.main.url(forResource: "milesdown", withExtension: "apkg") {
            return (u, "milesdown")
        }
        if let u = Bundle.main.url(forResource: "sample", withExtension: "apkg") {
            return (u, "sample")
        }
        throw AnkiEngineError.decode("no bundled .apkg found")
    }

    /// Copy a bundled .apkg into Documents (the backend imports from a real
    /// sandbox file path). Returns the destination path.
    private func stageApkg(_ src: URL) throws -> String {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let dst = docs.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
        return dst.path
    }

    private func importMarkerURL() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.appendingPathComponent(".imported_deck")
    }

    private func importedDeckMarker() -> String? {
        guard let u = try? importMarkerURL() else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    private func writeImportedDeckMarker(_ name: String) {
        if let u = try? importMarkerURL() {
            try? name.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    /// Delete the sandbox collection + media so a (re)import starts clean.
    private func clearCollection(_ paths: CollectionPaths) throws {
        let fm = FileManager.default
        for p in [paths.collection, paths.collection + "-wal", paths.collection + "-shm",
                  paths.mediaDB] where fm.fileExists(atPath: p) {
            try fm.removeItem(atPath: p)
        }
        if fm.fileExists(atPath: paths.mediaFolder) {
            try fm.removeItem(atPath: paths.mediaFolder)
        }
        try fm.createDirectory(atPath: paths.mediaFolder, withIntermediateDirectories: true)
    }
}
