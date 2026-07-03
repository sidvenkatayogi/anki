// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// McatCollection — the collection-native storage schema for the MCAT fork's
// "extra" data (practice questions/answers, memory palaces), plus the
// high-level AnkiEngine operations that read/write it.
//
// Everything the fork used to keep in a separate `mcat_tools` sidecar now
// lives in the Anki collection itself, so it rides native sync (AnkiWeb or a
// self-hosted server) with the cards + FSRS state — no extra backend, no
// per-user auth surface:
//
//   • Practice questions  -> "MCAT MCQ" notes (one card each)
//   • Practice answers     -> the review log of those cards
//   • Memory palaces        -> "MCAT Memory Palace" notes (structure JSON)
//   • Palace photos          -> collection media files
//
// The two notetypes are deliberately tagged `mcat_practice` / `mcat_palace`
// (neither string matches the FSRS category mapper's substrings — bio/chem/
// phys/psych/soc/cars), and their cards live under the `MCAT::` deck subtree,
// so they never leak into the MileDown study queue or the Readiness/tagMastery
// computation (which is additionally scoped to exclude these tags).

import Foundation
import SwiftProtobuf

/// Names, tags, deck paths, field layouts, and notetype builders for the two
/// MCAT notetypes. Field order here is authoritative: the desktop reader
/// (`qt/aqt/mediasrv.py`) and this app both address fields positionally, so
/// changing the order is a breaking, cross-platform change.
enum McatSchema {
    // MARK: Practice ("MCAT MCQ")

    static let mcqNotetypeName = "MCAT MCQ"
    /// Field order — do not reorder (positional contract with desktop).
    static let mcqFields = [
        "QuestionId", "Stem", "Options", "AnswerIndex", "Explanation",
        "Category", "DifficultyB",
    ]
    static let practiceDeckName = "MCAT::Practice Bank"
    static let practiceTag = "mcat_practice"
    /// Synced marker so the bank is seeded exactly once across all devices.
    static let practiceSeedVersionKey = "mcat.practiceSeedVersion"
    static let practiceSeedVersion = 1

    // MARK: Palace ("MCAT Memory Palace")

    static let palaceNotetypeName = "MCAT Memory Palace"
    /// Field order — do not reorder (positional contract with desktop).
    static let palaceFields = ["PalaceId", "Name", "Structure", "Photo"]
    static let palaceDeckName = "MCAT::Palaces"
    static let palaceTag = "mcat_palace"

    // MARK: MCQ field (de)serialization

    /// The 7 field values for one practice question, in `mcqFields` order.
    static func mcqFieldValues(for q: SeedQuestion) -> [String] {
        [
            q.id,
            q.stem,
            encodeOptions(q.options),
            String(q.answerIndex),
            q.explanation,
            q.category,
            String(q.difficultyB),
        ]
    }

    /// Rebuild a `SeedQuestion` from a note's fields (nil if malformed).
    static func seedQuestion(fromFields fields: [String]) -> SeedQuestion? {
        guard fields.count >= 7 else { return nil }
        let options = decodeOptions(fields[2])
        guard let answerIndex = Int(fields[3].trimmingCharacters(in: .whitespaces)),
              let difficultyB = Double(fields[6].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return SeedQuestion(
            id: fields[0],
            category: fields[5],
            stem: fields[1],
            options: options,
            answerIndex: answerIndex,
            explanation: fields[4],
            difficultyB: difficultyB
        )
    }

    private static func encodeOptions(_ options: [String]) -> String {
        guard let data = try? JSONEncoder().encode(options),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decodeOptions(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let options = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return options
    }

    /// A stable, deterministic note GUID for a question id, so a re-seed on the
    /// same device is idempotent (Anki import/merge matches notes by GUID).
    static func mcqGuid(forQuestionId id: String) -> String {
        "mcat-practice::" + id
    }

    // MARK: Notetype builders

    static func mcqNotetype() -> Anki_Notetypes_Notetype {
        notetype(
            name: mcqNotetypeName,
            fields: mcqFields,
            css: ".card{font-family:-apple-system,system-ui,sans-serif;}",
            front: "{{Stem}}",
            back: "{{FrontSide}}<hr>{{Explanation}}"
        )
    }

    static func palaceNotetype() -> Anki_Notetypes_Notetype {
        notetype(
            name: palaceNotetypeName,
            fields: palaceFields,
            css: ".card{font-family:-apple-system,system-ui,sans-serif;}",
            front: "{{Name}}",
            back: "{{FrontSide}}"
        )
    }

    /// Build a minimal normal notetype. The core fills in `reqs`, ids, and
    /// mtimes on add — callers only supply names, fields, and one template.
    private static func notetype(
        name: String, fields: [String], css: String, front: String, back: String
    ) -> Anki_Notetypes_Notetype {
        var nt = Anki_Notetypes_Notetype()
        nt.name = name
        var config = Anki_Notetypes_Notetype.Config()
        config.kind = .normal
        config.css = css
        nt.config = config
        nt.fields = fields.enumerated().map { index, fieldName in
            var field = Anki_Notetypes_Notetype.Field()
            var ord = Anki_Generic_UInt32()
            ord.val = UInt32(index)
            field.ord = ord
            field.name = fieldName
            field.config = Anki_Notetypes_Notetype.Field.Config()
            return field
        }
        var template = Anki_Notetypes_Notetype.Template()
        var tord = Anki_Generic_UInt32()
        tord.val = 0
        template.ord = tord
        template.name = "Card 1"
        var tconfig = Anki_Notetypes_Notetype.Template.Config()
        tconfig.qFormat = front
        tconfig.aFormat = back
        template.config = tconfig
        nt.templates = [template]
        return nt
    }
}

/// One practice question joined to the collection card that records its
/// answers (its review log is the answer history).
struct McatPracticeCard {
    let question: SeedQuestion
    let cardID: Int64
}

/// A palace note as stored in the collection: its note id plus raw fields
/// (`[PalaceId, Name, Structure, Photo]`).
struct McatPalaceNote {
    let noteID: Int64
    let fields: [String]

    var palaceID: String { fields.first ?? "" }
    /// The JSON `Structure` blob (index 2), or empty if malformed.
    var structureJSON: String { fields.count > 2 ? fields[2] : "" }
    /// The `Photo` field (index 3): an `<img src="…">` reference or empty.
    var photoField: String { fields.count > 3 ? fields[3] : "" }
}

extension AnkiEngine {
    // MARK: - Notetypes

    func ensureMcqNotetype() throws -> Int64 {
        if let id = try notetypeIdByName(McatSchema.mcqNotetypeName) { return id }
        return try addNotetype(McatSchema.mcqNotetype())
    }

    func ensurePalaceNotetype() throws -> Int64 {
        if let id = try notetypeIdByName(McatSchema.palaceNotetypeName) { return id }
        return try addNotetype(McatSchema.palaceNotetype())
    }

    // MARK: - Practice bank

    /// Idempotently seed the practice bank. Guarded by a synced config marker
    /// AND an existence check, so it never duplicates the bank whether re-run
    /// on one device or after a sync brought the bank from another device.
    func seedPracticeBankIfNeeded(_ questions: [SeedQuestion]) throws {
        if let data = try getConfigJson(key: McatSchema.practiceSeedVersionKey),
           let version = try? JSONDecoder().decode(Int.self, from: data),
           version >= McatSchema.practiceSeedVersion {
            return
        }

        let existing = (try? searchNotes("note:\"\(McatSchema.mcqNotetypeName)\"")) ?? []
        if existing.isEmpty, !questions.isEmpty {
            let notetypeID = try ensureMcqNotetype()
            let deckID = try ensureDeck(name: McatSchema.practiceDeckName)
            for question in questions {
                var note = try newNote(notetypeID: notetypeID)
                note.guid = McatSchema.mcqGuid(forQuestionId: question.id)
                note.fields = McatSchema.mcqFieldValues(for: question)
                note.tags = [McatSchema.practiceTag]
                _ = try addNote(note, deckID: deckID)
            }
        }

        let marker = try JSONEncoder().encode(McatSchema.practiceSeedVersion)
        try setConfigJson(key: McatSchema.practiceSeedVersionKey, valueJson: marker)
    }

    /// Every practice question in the collection, joined to the card that
    /// records its answers. Ordered by note id (assigned in seed order and
    /// identical across synced devices), so the question sequence — and thus
    /// the resume position — is stable everywhere.
    func loadPracticeCards() throws -> [McatPracticeCard] {
        let noteIDs = try searchNotes("note:\"\(McatSchema.mcqNotetypeName)\"").sorted()
        var cards: [McatPracticeCard] = []
        for noteID in noteIDs {
            guard let note = try? getNote(noteID: noteID),
                  let question = McatSchema.seedQuestion(fromFields: note.fields),
                  let cardID = (try? searchCards("nid:\(noteID)"))?.first
            else { continue }
            cards.append(McatPracticeCard(question: question, cardID: cardID))
        }
        return cards
    }

    /// Reconstruct the flat practice-answer history from the review log of the
    /// practice cards (`buttonChosen >= 3` = correct). Skips non-answer revlog
    /// entries (`buttonChosen == 0`, e.g. manual reschedules).
    func practiceHistory(cards: [McatPracticeCard]) -> [PracticeHistoryItem] {
        var items: [PracticeHistoryItem] = []
        for card in cards {
            guard let category = MCATCategory(rawValue: card.question.category) else { continue }
            let logs = (try? reviewLogs(cardID: card.cardID)) ?? []
            for log in logs where log.buttonChosen >= 1 {
                items.append(PracticeHistoryItem(
                    questionId: card.question.id,
                    category: category,
                    correct: log.buttonChosen >= 3,
                    difficultyB: card.question.difficultyB
                ))
            }
        }
        return items
    }

    // MARK: - Palaces

    /// Upsert a palace note (matched by its `PalaceId` field). `fields` must be
    /// in `McatSchema.palaceFields` order: `[PalaceId, Name, Structure, Photo]`.
    func upsertPalaceNote(fields: [String]) throws {
        let notetypeID = try ensurePalaceNotetype()
        let palaceID = fields.first ?? ""
        if let existing = try loadPalaceNotes().first(where: { $0.palaceID == palaceID }) {
            var note = try getNote(noteID: existing.noteID)
            note.fields = fields
            try updateNotes([note])
        } else {
            let deckID = try ensureDeck(name: McatSchema.palaceDeckName)
            var note = try newNote(notetypeID: notetypeID)
            note.fields = fields
            note.tags = [McatSchema.palaceTag]
            _ = try addNote(note, deckID: deckID)
        }
    }

    /// All palace notes currently in the collection.
    func loadPalaceNotes() throws -> [McatPalaceNote] {
        let noteIDs = try searchNotes("tag:\(McatSchema.palaceTag)")
        var notes: [McatPalaceNote] = []
        for noteID in noteIDs {
            guard let note = try? getNote(noteID: noteID), note.fields.count >= 4 else { continue }
            notes.append(McatPalaceNote(noteID: noteID, fields: note.fields))
        }
        return notes
    }
}
