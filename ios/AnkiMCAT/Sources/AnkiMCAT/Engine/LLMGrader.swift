// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// LLMGrader — asks OpenAI whether a spoken answer is correct, and maps a
// correct answer's response time onto an FSRS rating. Mirrors the desktop
// qt/aqt/llm_grade.py so both platforms grade the same way. The API key is
// supplied by the caller (from the Keychain via SettingsStore).

import Foundation

enum LLMGraderError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No OpenAI API key set."
        case let .http(code, body): return "OpenAI error \(code): \(body)"
        case .badResponse: return "Unexpected response from OpenAI."
        }
    }
}

enum LLMGrader {
    /// The cheapest current OpenAI GPT model. gpt-5-nano is a reasoning model,
    /// so we request minimal reasoning effort and don't send a temperature.
    /// Kept in one place so it's trivial to swap.
    static let model = "gpt-5-nano"
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let timeout: TimeInterval = 30

    // Spoken answers are quicker than desktop typing, so these bands are tighter
    // than the desktop ones. Tunable in one place.
    static let easyMaxMillis = 8_000
    static let goodMaxMillis = 20_000

    /// Map how long a *correct* answer took onto Hard/Good/Easy.
    static func ease(fromElapsed millis: Int) -> Anki_Scheduler_CardAnswer.Rating {
        if millis <= easyMaxMillis { return .easy }
        if millis <= goodMaxMillis { return .good }
        return .hard
    }

    struct Verdict {
        let correct: Bool
        let feedback: String
    }

    private static let systemPrompt = """
    You are grading a flashcard answer. You are given the question, the correct \
    answer, and the student's spoken answer (transcribed, so expect minor \
    transcription errors). Decide whether the student's answer is essentially \
    correct: it should capture the key meaning of the correct answer, even if \
    phrased differently, less complete, or with minor mistakes. Ignore \
    capitalization and punctuation. Respond with ONLY a JSON object of the form \
    {"correct": true or false, "feedback": "one short sentence"}.
    """

    /// Ask the LLM whether `provided` answers the card. Throws on any error so
    /// the caller can fall back to manual grading.
    static func grade(
        question: String,
        expected: String,
        provided: String,
        apiKey: String
    ) async throws -> Verdict {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMGraderError.missingKey }

        let userContent = """
        Question:
        \(question)

        Correct answer:
        \(expected)

        Student's answer:
        \(provided)
        """

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "response_format": ["type": "json_object"],
            "reasoning_effort": "minimal",
            "max_completion_tokens": 2000,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMGraderError.badResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMGraderError.http(http.statusCode, String(body.prefix(500)))
        }

        // The model returns a JSON string in choices[0].message.content.
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let contentData = content.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        else {
            throw LLMGraderError.badResponse
        }

        let correct = (object["correct"] as? Bool) ?? false
        let feedback = (object["feedback"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Verdict(correct: correct, feedback: feedback)
    }
}
