// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ReadModel — drives the Read tab: fetches a short passage + MCQ quiz from the
// self-hosted sync server's `GET /read/passage` (contracts/api.md), lets the
// user answer, then reveals correct/incorrect + explanation once submitted.
// Everything here is in-memory only: passages/quizzes/answers are never
// persisted anywhere and never feed Performance/Readiness (Read is a separate,
// disconnected feature from Practice per the spec).

import Foundation
import SwiftUI

@MainActor
@Observable
final class ReadModel {
    // MARK: - Wire types (contracts/api.md `GET /read/passage`)

    struct QuizQuestion: Codable, Equatable, Identifiable {
        let id: String
        let stem: String
        let options: [String]
        let answerIndex: Int
        let explanation: String

        enum CodingKeys: String, CodingKey {
            case id, stem, options, explanation
            case answerIndex = "answer_index"
        }
    }

    struct ReadPassage: Codable, Equatable {
        let passageId: String
        let source: String
        let title: String
        let text: String
        let url: String
        let quiz: [QuizQuestion]

        enum CodingKeys: String, CodingKey {
            case source, title, text, url, quiz
            case passageId = "passage_id"
        }
    }

    private struct ErrorEnvelope: Codable {
        struct Body: Codable {
            let code: String?
            let message: String?
        }
        let error: Body?
    }

    // MARK: - Published state

    enum Phase: Equatable {
        case notConfigured
        case loading
        case loaded
        case error(String)
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var passage: ReadPassage?

    /// Selected option index per question id (nil = unanswered).
    private(set) var selections: [String: Int] = [:]
    private(set) var submitted = false

    // MARK: - Init

    init() {}

    // MARK: - Config

    var isConfigured: Bool {
        let creds = SyncStore.load()
        return !(creds?.endpoint.isEmpty ?? true) && !(creds?.mcatToolsToken.isEmpty ?? true)
    }

    /// Saves the server URL/token from the inline config form (there is no
    /// separate settings dialog on iOS either, mirroring the web round's
    /// documented decision — see domains/frontend/report.md item #2), then
    /// loads a passage.
    func saveConfig(endpoint: String, token: String) {
        let endpoint = normalize(endpoint)
        SyncStore.saveToolsToken(token, endpoint: endpoint)
        Task { await load() }
    }

    // MARK: - Loading

    /// Loads a passage if configured, else surfaces the inline config form.
    func load() async {
        guard let creds = SyncStore.load(), !creds.endpoint.isEmpty, !creds.mcatToolsToken.isEmpty
        else {
            phase = .notConfigured
            return
        }
        await fetchPassage(endpoint: creds.endpoint, token: creds.mcatToolsToken)
    }

    /// Retry from the error state — identical to load().
    func retry() async {
        await load()
    }

    /// "New passage" — clears in-memory quiz state and fetches again.
    func reset() async {
        passage = nil
        selections = [:]
        submitted = false
        await load()
    }

    private func fetchPassage(endpoint: String, token: String) async {
        phase = .loading
        passage = nil
        selections = [:]
        submitted = false

        let base = normalize(endpoint)
        guard let url = URL(string: base + "read/passage") else {
            phase = .error("Invalid server URL.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Mcat-Token")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                phase = .error("Couldn't reach the server.")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?
                    .error?.message
                phase = .error(message ?? "Couldn't reach the server (status \(http.statusCode)).")
                return
            }
            let decoded = try JSONDecoder().decode(ReadPassage.self, from: data)
            passage = decoded
            selections = [:]
            submitted = false
            phase = .loaded
        } catch {
            phase = .error("Couldn't reach the server. Check your connection and try again.")
        }
    }

    // MARK: - Quiz interaction

    func select(optionIndex: Int, forQuestion questionId: String) {
        guard !submitted else { return }
        selections[questionId] = optionIndex
    }

    /// All questions must be answered before submit is allowed (a reasonable
    /// gate, since the reveal doesn't make sense with unanswered questions).
    var canSubmit: Bool {
        guard let passage, !submitted else { return false }
        return !passage.quiz.isEmpty && passage.quiz.allSatisfy { selections[$0.id] != nil }
    }

    /// Disables further edits immediately (no double-submit, AC) and reveals
    /// correct/incorrect. There is no network call — everything is in-memory.
    func submit() {
        guard canSubmit else { return }
        submitted = true
    }

    func isCorrect(_ question: QuizQuestion) -> Bool {
        selections[question.id] == question.answerIndex
    }

    // MARK: - Internals

    /// Accept "host:port" or a bare host and ensure a trailing slash.
    private func normalize(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return e }
        if !e.contains("://") { e = "http://" + e }
        if !e.hasSuffix("/") { e += "/" }
        return e
    }
}
