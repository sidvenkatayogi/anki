// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PracticeModel — drives the Practice tab: a bundled offline question bank
// (`Resources/practice-seed.json`), one-question-at-a-time flow, local
// answer history (`PracticeStore`), and Performance/Readiness metrics.
//
// Metrics are always computed locally first (offline-safe, contracts/
// data-model.md formulas via `MCATMetrics`, using FSRS mastery pulled from
// the shared collection via `engine.tagMastery`). If the self-hosted sync
// server is reachable, `POST {endpoint}metrics/compute` is tried afterwards
// and its numbers -- if they come back -- supersede the local calculation.
// A network failure here must never block or error the UI (AC21): the local
// numbers set by `recomputeMetrics()` simply remain in effect.
//
// Tag-mapping deviation (must match the web round's documented deviation so
// both platforms compute identical FsrsSummary from the same collection):
// this fork's real tags are single-rooted under `MileDown::`, so
// `group_depth=1` collapses everything into one bucket. Uses `group_depth=2`
// (matches `qt/aqt/focus_category.py`'s proven precedent) plus substring
// tag-name -> category mapping, checked bio_biochem -> chem_phys ->
// psych_soc -> cars (in that order, to avoid "Biochemistry" matching "chem"
// first). Untagged/unmatched groups are excluded from all 4 categories.

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
    @ObservationIgnored private let store: PracticeStore

    /// The full bundled question bank, decoded once at init (offline, no
    /// loading state needed per spec).
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

    /// Which numbers are currently in effect -- lets the UI show a subtle
    /// "server" vs "on this device" indicator.
    private(set) var metricsSource: MetricsSource = .local

    enum MetricsSource: String {
        case local
        case server
    }

    init(engine: AnkiEngine = AnkiEngine(), store: PracticeStore = PracticeStore()) {
        self.engine = engine
        self.store = store
        self.questions = Self.loadSeedQuestions()
        if questions.isEmpty {
            loadError = "No practice questions are bundled with this build."
        }
        Task { [weak self] in
            await self?.recomputeMetrics()
            await self?.refreshServerMetrics()
        }
    }

    var currentQuestion: SeedQuestion? {
        guard currentIndex >= 0, currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    /// True once every question has been visited (used to show a "you've
    /// gone through the deck" wrap-up rather than looping silently).
    private(set) var finished = false

    // MARK: - Loading the bundled seed

    private static func loadSeedQuestions() -> [SeedQuestion] {
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

    /// Records the answer once (guarded against double taps), reveals the
    /// correct answer/explanation, then recomputes metrics -- local first
    /// (synchronous/offline-safe), then an async, non-blocking overlay from
    /// the sync server if one is configured and reachable.
    func submit() {
        guard canSubmit, let question = currentQuestion, let selectedOption else { return }
        // Disable immediately so a second tap (or a retried gesture) can
        // never generate a second client_answer_id for the same answer.
        submitted = true

        let record = PracticeRecord(
            clientAnswerId: UUID().uuidString,
            questionId: question.id,
            category: question.category,
            correct: selectedOption == question.answerIndex,
            difficultyB: question.difficultyB,
            answeredAt: Int64(Date().timeIntervalSince1970)
        )
        try? store.append(record)

        Task { [weak self] in
            await self?.recomputeMetrics()
            await self?.refreshServerMetrics()
        }
    }

    var isCorrect: Bool {
        guard let question = currentQuestion, let selectedOption else { return false }
        return selectedOption == question.answerIndex
    }

    /// Advances to the next question, resetting per-question state. Stops
    /// (and flags `finished`) at the end of the bank rather than wrapping,
    /// so the "you've gone through everything" state is visible; the user
    /// can still review Performance/Readiness below.
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

    // MARK: - Metrics (local, always available offline)

    /// Recomputes Performance + Readiness from the full local history plus a
    /// fresh FSRS pull. Always local/offline-safe; `refreshServerMetrics()`
    /// may overlay server numbers afterwards.
    func recomputeMetrics() async {
        let history: [PracticeHistoryItem] = store.loadAll().compactMap { record in
            guard let category = MCATCategory(rawValue: record.category) else { return nil }
            return PracticeHistoryItem(
                questionId: record.questionId,
                category: category,
                correct: record.correct,
                difficultyB: record.difficultyB
            )
        }

        let perf = MCATMetrics.computePerformance(history)
        let fsrs = await buildFsrsSummary()
        let ready = MCATMetrics.computeReadiness(perf, fsrs)

        performance = perf
        readiness = ready
        metricsSource = .local
    }

    /// Aggregates `engine.tagMastery(groupDepth: 2, ...)` groups into the 4
    /// canonical categories via the substring rule (see file header). If the
    /// engine call throws (e.g. the collection isn't open yet), returns an
    /// all-"not enough data" empty summary rather than failing the caller.
    func buildFsrsSummary() async -> FsrsSummary {
        let emptyPerCategory = MCATCategory.allCases.map {
            FsrsCategorySummary(category: $0, averageRecall: 0, masteredFraction: 0,
                                enoughData: false, gradedReviews: 0)
        }
        let empty = FsrsSummary(perCategory: emptyPerCategory, overallMeanRecall: 0)

        guard let response = try? await engine.tagMastery(groupDepth: 2, masteredThreshold: 0, search: "")
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
    /// one of the 4 canonical categories via substring match, checked in
    /// this fixed order to avoid "Biochemistry" matching "chem" first. Nil
    /// if the tag doesn't match any of the 4 -- such groups are excluded
    /// entirely, never folded into a category.
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

    // MARK: - Server overlay (optional, non-blocking)

    private struct MetricsComputeRequest: Encodable {
        struct HistoryItem: Encodable {
            let questionId: String
            let category: String
            let correct: Bool
            let difficultyB: Double

            enum CodingKeys: String, CodingKey {
                case questionId = "question_id"
                case category, correct
                case difficultyB = "difficulty_b"
            }
        }
        struct FsrsCategoryWire: Encodable {
            let category: String
            let averageRecall: Double
            let masteredFraction: Double
            let enoughData: Bool
            let gradedReviews: Int

            enum CodingKeys: String, CodingKey {
                case category
                case averageRecall = "average_recall"
                case masteredFraction = "mastered_fraction"
                case enoughData = "enough_data"
                case gradedReviews = "graded_reviews"
            }
        }
        struct FsrsWire: Encodable {
            let perCategory: [FsrsCategoryWire]
            let overallMeanRecall: Double

            enum CodingKeys: String, CodingKey {
                case perCategory = "per_category"
                case overallMeanRecall = "overall_mean_recall"
            }
        }
        let practiceHistory: [HistoryItem]
        let fsrs: FsrsWire

        enum CodingKeys: String, CodingKey {
            case practiceHistory = "practice_history"
            case fsrs
        }
    }

    private struct MetricsComputeResponse: Decodable {
        struct OverallWire: Decodable {
            let p: Double
            let enoughData: Bool
            let n: Int
            enum CodingKeys: String, CodingKey { case p; case enoughData = "enough_data"; case n }
        }
        struct PerCategoryWire: Decodable {
            let category: String
            let p: Double
            let enoughData: Bool
            let n: Int
            enum CodingKeys: String, CodingKey {
                case category, p
                case enoughData = "enough_data"
                case n
            }
        }
        struct PerformanceWire: Decodable {
            let overall: OverallWire
            let perCategory: [PerCategoryWire]
            enum CodingKeys: String, CodingKey { case overall; case perCategory = "per_category" }
        }
        struct ReadinessWire: Decodable {
            let scorePoint: Int
            let scoreLow: Int
            let scoreHigh: Int
            let confidence: String
            let note: String
            let enoughData: Bool
            enum CodingKeys: String, CodingKey {
                case scorePoint = "score_point"
                case scoreLow = "score_low"
                case scoreHigh = "score_high"
                case confidence, note
                case enoughData = "enough_data"
            }
        }
        let performance: PerformanceWire
        let readiness: ReadinessWire
    }

    /// Best-effort `POST {endpoint}metrics/compute` overlay. Silently keeps
    /// the local numbers already set by `recomputeMetrics()` on any failure
    /// (not configured, offline, non-2xx, bad JSON) -- never surfaces an
    /// error or blocks the UI (AC21).
    func refreshServerMetrics() async {
        guard let creds = SyncStore.load(), !creds.endpoint.isEmpty, !creds.mcatToolsToken.isEmpty
        else { return }

        let history: [PracticeHistoryItem] = store.loadAll().compactMap { record in
            guard let category = MCATCategory(rawValue: record.category) else { return nil }
            return PracticeHistoryItem(questionId: record.questionId, category: category,
                                        correct: record.correct, difficultyB: record.difficultyB)
        }
        let fsrs = await buildFsrsSummary()

        let body = MetricsComputeRequest(
            practiceHistory: history.map {
                .init(questionId: $0.questionId, category: $0.category.rawValue,
                      correct: $0.correct, difficultyB: $0.difficultyB)
            },
            fsrs: .init(
                perCategory: fsrs.perCategory.map {
                    .init(category: $0.category.rawValue, averageRecall: $0.averageRecall,
                          masteredFraction: $0.masteredFraction, enoughData: $0.enoughData,
                          gradedReviews: $0.gradedReviews)
                },
                overallMeanRecall: fsrs.overallMeanRecall
            )
        )

        var base = creds.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "metrics/compute") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(creds.mcatToolsToken, forHTTPHeaderField: "X-Mcat-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let encoded = try? JSONEncoder().encode(body) else { return }
        request.httpBody = encoded

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MetricsComputeResponse.self, from: data)
        else {
            return
        }

        let overallCategory = decoded.performance.perCategory.compactMap { wire -> PerformanceCategory? in
            guard let category = MCATCategory(rawValue: wire.category) else { return nil }
            return PerformanceCategory(category: category, p: wire.p, enoughData: wire.enoughData, n: wire.n)
        }
        performance = Performance(
            overall: (p: decoded.performance.overall.p, enoughData: decoded.performance.overall.enoughData,
                      n: decoded.performance.overall.n),
            perCategory: overallCategory
        )
        readiness = Readiness(
            scorePoint: decoded.readiness.scorePoint,
            scoreLow: decoded.readiness.scoreLow,
            scoreHigh: decoded.readiness.scoreHigh,
            confidence: Confidence(rawValue: decoded.readiness.confidence) ?? .low,
            note: decoded.readiness.note,
            enoughData: decoded.readiness.enoughData
        )
        metricsSource = .server
    }
}
