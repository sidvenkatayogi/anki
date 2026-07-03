// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PracticeModel — drives the Practice tab. The question bank and answer
// history are collection-native (see McatCollection.swift): questions are
// "MCAT MCQ" notes seeded once from the bundled `practice-seed.json`, and each
// answer is a review of that note's card, so the whole thing syncs with the
// rest of the collection (no separate server).
//
// Metrics (Performance/Readiness) are computed locally from the review log
// (contracts/data-model.md formulas via `MCATMetrics`) plus FSRS mastery
// pulled from the collection via `engine.tagMastery`. The tagMastery query is
// scoped to exclude the `mcat_practice`/`mcat_palace` tags so the practice and
// palace cards never perturb the Readiness figure.
//
// Tag-mapping deviation (must match the web round's documented deviation so
// both platforms compute identical FsrsSummary from the same collection):
// this fork's real tags are single-rooted under `MileDown::`, so
// `group_depth=1` collapses everything into one bucket. Uses `group_depth=2`
// plus substring tag-name -> category mapping, checked bio_biochem ->
// chem_phys -> psych_soc -> cars (in that order, to avoid "Biochemistry"
// matching "chem" first). Untagged/unmatched groups are excluded.

import Foundation
import SwiftUI

/// A bundled practice question, decoded from `practice-seed.json`.
/// Field-for-field match of contracts/data-model.md's SeedQuestion schema.
struct SeedQuestion: Codable, Equatable, Identifiable {
    let id: String
    let category: String // one of the 4 canonical snake_case values
    let stem: String
    let options: [String]
    let answerIndex: Int
    let explanation: String
    let difficultyB: Double

    enum CodingKeys: String, CodingKey {
        case id, category, stem, options, explanation
        case answerIndex = "answer_index"
        case difficultyB = "difficulty_b"
    }
}

@MainActor
@Observable
final class PracticeModel {
    @ObservationIgnored private let engine: AnkiEngine

    /// The current question bank, read from the collection once the engine is
    /// ready. Empty until then (the UI shows nothing rather than a spinner).
    private(set) var questions: [SeedQuestion] = []
    private(set) var loadError: String?

    /// Index of the question currently on screen.
    private(set) var currentIndex = 0

    /// Per-question interaction state for the current question only (reset
    /// on `next()`).
    private(set) var selectedOption: Int?
    private(set) var submitted = false

    private(set) var performance: Performance?
    private(set) var readiness: Readiness?

    /// True once every question has been visited (used to show a "you've
    /// gone through the deck" wrap-up rather than looping silently).
    private(set) var finished = false

    /// Practice questions joined to the collection card recording their
    /// answers. Populated by `reload()`; drives grading + metrics.
    @ObservationIgnored private var practiceCards: [McatPracticeCard] = []
    /// Bundled question bank, used only as the one-time seed source.
    @ObservationIgnored private let bundledSeed: [SeedQuestion]

    init(engine: AnkiEngine = AnkiEngine()) {
        self.engine = engine
        self.bundledSeed = Self.loadBundledSeed()
    }

    var currentQuestion: SeedQuestion? {
        guard currentIndex >= 0, currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    // MARK: - Loading (collection-native)

    /// Called once the shared collection is open (and again after a sync
    /// replaces it). Seeds the bank if needed, then loads questions + metrics
    /// from the collection.
    func onEngineReady() {
        Task { [weak self] in await self?.reload() }
    }

    /// Seed (idempotently) then read the question bank + metrics from the
    /// collection. Safe to call repeatedly.
    func reload() async {
        do {
            try await engine.seedPracticeBankIfNeeded(bundledSeed)
            let cards = try await engine.loadPracticeCards()
            practiceCards = cards
            questions = cards.map(\.question)
            loadError = questions.isEmpty
                ? "No practice questions are available yet."
                : nil
            // Resume where the (synced) answers left off — the first question
            // with no review-log entry — so progress carries across devices
            // even though only the answers sync, not the on-screen cursor.
            let history = await engine.practiceHistory(cards: cards)
            applyResumePosition(answeredIDs: Set(history.map(\.questionId)))
            await recomputeMetrics()
        } catch {
            loadError = "Couldn't load practice questions."
        }
    }

    /// Move the cursor to the first unanswered question (or the end, flagged
    /// finished, if every question has an answer). Resets per-question state.
    private func applyResumePosition(answeredIDs: Set<String>) {
        selectedOption = nil
        submitted = false
        guard !questions.isEmpty else {
            currentIndex = 0
            finished = false
            return
        }
        if let resume = questions.firstIndex(where: { !answeredIDs.contains($0.id) }) {
            currentIndex = resume
            finished = false
        } else {
            currentIndex = questions.count - 1
            finished = true
        }
    }

    private static func loadBundledSeed() -> [SeedQuestion] {
        guard let url = Bundle.main.url(forResource: "practice-seed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let questions = try? JSONDecoder().decode([SeedQuestion].self, from: data)
        else {
            return []
        }
        return questions
    }

    // MARK: - Answering

    func select(optionIndex: Int) {
        guard !submitted, currentQuestion != nil else { return }
        selectedOption = optionIndex
    }

    var canSubmit: Bool {
        !submitted && selectedOption != nil && currentQuestion != nil
    }

    /// Records the answer as a review of the question's card (correct → Good,
    /// wrong → Again), which writes a revlog entry that syncs with the rest of
    /// the collection, then recomputes metrics from the (updated) revlog.
    func submit() {
        guard canSubmit, let question = currentQuestion, let selectedOption else { return }
        // Disable immediately so a second tap can't double-grade.
        submitted = true

        let correct = selectedOption == question.answerIndex
        let cardID = practiceCards.first { $0.question.id == question.id }?.cardID
        let rating: Anki_Scheduler_CardAnswer.Rating = correct ? .good : .again

        Task { [weak self] in
            guard let self else { return }
            if let cardID {
                _ = try? await self.engine.gradeCard(cardID: cardID, rating: rating)
            }
            await self.recomputeMetrics()
        }
    }

    var isCorrect: Bool {
        guard let question = currentQuestion, let selectedOption else { return false }
        return selectedOption == question.answerIndex
    }

    /// Advances to the next question, resetting per-question state. Stops
    /// (and flags `finished`) at the end of the bank rather than wrapping.
    func next() {
        guard !questions.isEmpty else { return }
        if currentIndex + 1 < questions.count {
            currentIndex += 1
        } else {
            finished = true
        }
        selectedOption = nil
        submitted = false
    }

    /// Restart from the first question (used from the "finished" state).
    func restart() {
        currentIndex = 0
        selectedOption = nil
        submitted = false
        finished = false
    }

    // MARK: - Metrics (local, from the collection)

    /// Recomputes Performance + Readiness from the practice cards' review log
    /// plus a fresh FSRS pull. Offline-safe; a failing engine call degrades to
    /// an empty summary rather than erroring.
    func recomputeMetrics() async {
        let history = await engine.practiceHistory(cards: practiceCards)
        let perf = MCATMetrics.computePerformance(history)
        let fsrs = await buildFsrsSummary()
        let ready = MCATMetrics.computeReadiness(perf, fsrs)

        performance = perf
        readiness = ready
    }

    /// Aggregates `engine.tagMastery(groupDepth: 2, ...)` groups into the 4
    /// canonical categories via the substring rule (see file header). The
    /// query excludes the MCAT practice/palace tags so those cards never
    /// perturb Readiness. Returns an all-"not enough data" summary if the
    /// engine call throws (e.g. the collection isn't open yet).
    func buildFsrsSummary() async -> FsrsSummary {
        let emptyPerCategory = MCATCategory.allCases.map {
            FsrsCategorySummary(category: $0, averageRecall: 0, masteredFraction: 0,
                                enoughData: false, gradedReviews: 0)
        }
        let empty = FsrsSummary(perCategory: emptyPerCategory, overallMeanRecall: 0)

        guard let response = try? await engine.tagMastery(
            groupDepth: 2, masteredThreshold: 0,
            search: "-tag:\(McatSchema.practiceTag) -tag:\(McatSchema.palaceTag)")
        else {
            return empty
        }

        struct Accumulator {
            var weightedRecallSum = 0.0
            var weightSum = 0.0
            var cardsWithState = 0
            var masteredCards = 0
            var gradedReviews = 0
        }

        var byCategory: [MCATCategory: Accumulator] = [:]

        for group in response.groups {
            guard let category = Self.category(forTag: group.tag) else { continue }
            var accumulator = byCategory[category] ?? Accumulator()
            let weight = Double(group.cardsWithState)
            accumulator.weightedRecallSum += group.averageRecall * weight
            accumulator.weightSum += weight
            accumulator.cardsWithState += Int(group.cardsWithState)
            accumulator.masteredCards += Int(group.masteredCards)
            accumulator.gradedReviews += Int(group.gradedReviews)
            byCategory[category] = accumulator
        }

        let perCategory: [FsrsCategorySummary] = MCATCategory.allCases.map { category in
            guard let accumulator = byCategory[category], accumulator.cardsWithState > 0 else {
                return FsrsCategorySummary(category: category, averageRecall: 0, masteredFraction: 0,
                                            enoughData: false, gradedReviews: 0)
            }
            let averageRecall = accumulator.weightSum > 0
                ? accumulator.weightedRecallSum / accumulator.weightSum
                : 0
            let masteredFraction = accumulator.cardsWithState > 0
                ? Double(accumulator.masteredCards) / Double(accumulator.cardsWithState)
                : 0
            return FsrsCategorySummary(
                category: category,
                averageRecall: averageRecall,
                masteredFraction: masteredFraction,
                enoughData: accumulator.cardsWithState >= 20,
                gradedReviews: accumulator.gradedReviews
            )
        }

        return FsrsSummary(perCategory: perCategory, overallMeanRecall: response.overallMeanRecall)
    }

    /// Maps a raw tag string (e.g. `"MileDown::Biochemistry::Enzymes"`) onto
    /// one of the 4 canonical categories via substring match, checked in this
    /// fixed order to avoid "Biochemistry" matching "chem" first. Nil if the
    /// tag doesn't match any of the 4 — such groups are excluded entirely.
    private static func category(forTag tag: String) -> MCATCategory? {
        let lower = tag.lowercased()
        if lower.contains("bio_biochem") || lower.contains("biochem") || lower.contains("bio") {
            return .bioBiochem
        }
        if lower.contains("chem_phys") || lower.contains("chem") || lower.contains("phys") {
            return .chemPhys
        }
        if lower.contains("psych_soc") || lower.contains("psych") || lower.contains("soc") {
            return .psychSoc
        }
        if lower.contains("cars") {
            return .cars
        }
        return nil
    }
}
