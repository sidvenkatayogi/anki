// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PracticeStore — on-disk persistence for the Practice tab's local answer
// history, mirroring `Palace/PalaceStore.swift`'s pattern (atomic writes,
// tolerant load). Stored at Documents/PracticeHistory/history.json per
// contracts/data-model.md's "Local practice-history store" section.
//
// Records are append-only and deduped by `clientAnswerId` (generated
// client-side at submit time) so a retried save never duplicates an answer.
// Never written into the synced Anki collection -- purely local to the
// device.

import Foundation

struct PracticeRecord: Codable, Equatable {
    var clientAnswerId: String // UUID string, dedupe key
    var questionId: String
    var category: String // one of the 4 canonical snake_case values
    var correct: Bool
    var difficultyB: Double
    var answeredAt: Int64 // unix seconds

    private enum CodingKeys: String, CodingKey {
        case clientAnswerId = "client_answer_id"
        case questionId = "question_id"
        case category
        case correct
        case difficultyB = "difficulty_b"
        case answeredAt = "answered_at"
    }
}

/// The on-disk envelope: `{ "records": [ ... ] }`.
private struct PracticeHistoryFile: Codable {
    var records: [PracticeRecord]
}

struct PracticeStore {
    /// Directory that contains history.json.
    let rootURL: URL

    /// Default store lives under the app's Documents sandbox; tests inject a
    /// temp root. Falls back to the temp dir if Documents is somehow
    /// unavailable.
    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let docs = (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = docs.appendingPathComponent("PracticeHistory", isDirectory: true)
        }
    }

    private var historyURL: URL {
        rootURL.appendingPathComponent("history.json")
    }

    /// Load every stored record. Tolerant: if the top-level file is missing
    /// or unparseable, returns an empty array; if individual entries inside
    /// `records` are malformed, those entries are skipped rather than failing
    /// the whole load.
    func loadAll() -> [PracticeRecord] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }

        // First try the straightforward whole-file decode (the common case).
        if let file = try? JSONDecoder().decode(PracticeHistoryFile.self, from: data) {
            return file.records
        }

        // Fall back to decoding the "records" array element-by-element, so a
        // single corrupt record doesn't drop the entire history.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRecords = json["records"] as? [Any] else { return [] }

        let decoder = JSONDecoder()
        var records: [PracticeRecord] = []
        for raw in rawRecords {
            guard let recordData = try? JSONSerialization.data(withJSONObject: raw),
                  let record = try? decoder.decode(PracticeRecord.self, from: recordData) else { continue }
            records.append(record)
        }
        return records
    }

    /// Append a record if its `clientAnswerId` isn't already present, then
    /// write the whole history back atomically (create-if-needed).
    func append(_ record: PracticeRecord) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var records = loadAll()
        guard !records.contains(where: { $0.clientAnswerId == record.clientAnswerId }) else { return }
        records.append(record)

        let file = PracticeHistoryFile(records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: historyURL, options: .atomic)
    }
}
