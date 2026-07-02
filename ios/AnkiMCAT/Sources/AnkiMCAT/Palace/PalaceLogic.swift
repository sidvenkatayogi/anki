// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceLogic — pure, dependency-light helpers for the memory palace. Kept free
// of ARKit/SwiftUI/engine so it can be unit-tested in isolation: card-label
// extraction from rendered HTML, study-session step construction, and the
// float-array <-> simd transform bridge used to persist AR anchor poses.

import Foundation
#if canImport(simd)
import simd
#endif

/// How the user is quizzed on a locus during a study session.
enum StudyMode: String, Codable, CaseIterable, Identifiable {
    /// "What card is here?" — a location is highlighted, the user recalls the card.
    case recall
    /// "Where is this?" — the card is shown, the user points to its location.
    case locate
    /// Alternate between recall and locate across the session.
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: return "What's here?"
        case .locate: return "Where is it?"
        case .mixed: return "Mixed"
        }
    }
}

/// One step of a study session: the locus under test and the concrete mode
/// (`.mixed` is expanded to `.recall`/`.locate` per step).
struct StudyStep: Equatable {
    var locusID: UUID
    var mode: StudyMode  // always .recall or .locate here
}

enum PalaceLogic {
    // MARK: - Card label extraction

    /// Turn a card's rendered question HTML into a short, single-line label:
    /// drop <style>/<script> blocks, strip tags, decode common entities,
    /// collapse whitespace, and truncate.
    static func label(fromHTML html: String, maxLength: Int = 80) -> String {
        var s = removeBlock(html, tag: "style")
        s = removeBlock(s, tag: "script")

        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        out = decodeEntities(out)

        let collapsed = out
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" || $0 == "\u{00a0}" })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(untitled card)" }
        if trimmed.count <= maxLength { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Remove `<tag ...>...</tag>` blocks (case-insensitive), including content.
    private static func removeBlock(_ s: String, tag: String) -> String {
        var result = s
        let open = "<\(tag)"
        let close = "</\(tag)>"
        while let start = result.range(of: open, options: .caseInsensitive) {
            guard let end = result.range(of: close, options: .caseInsensitive,
                                         range: start.lowerBound..<result.endIndex) else {
                // Unbalanced: drop from the opening tag onward.
                result.removeSubrange(start.lowerBound..<result.endIndex)
                break
            }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    /// Decode the handful of HTML entities that show up in card fields.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…",
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    // MARK: - Capacity

    /// Whether another card may be placed in `palace` (space remains).
    static func canPlace(in palace: Palace) -> Bool { !palace.isFull }

    /// A short status line for the capture screen.
    static func capacityStatus(_ palace: Palace) -> String {
        if palace.isFull {
            return "Room full — \(palace.loci.count)/\(palace.capacity) spots used"
        }
        return "\(palace.loci.count)/\(palace.capacity) spots used"
    }

    // MARK: - Study session

    /// Build the ordered steps for a study session. `order` is the (typically
    /// pre-shuffled) sequence of loci to test; for `.mixed`, steps alternate
    /// recall/locate starting with recall.
    static func buildSteps(order: [Locus], mode: StudyMode) -> [StudyStep] {
        order.enumerated().map { index, locus in
            let effective: StudyMode
            switch mode {
            case .recall: effective = .recall
            case .locate: effective = .locate
            case .mixed: effective = (index % 2 == 0) ? .recall : .locate
            }
            return StudyStep(locusID: locus.id, mode: effective)
        }
    }

    /// A "locate" answer is correct when the selected locus is the target.
    static func isLocateCorrect(selected: UUID, target: UUID) -> Bool {
        selected == target
    }

    // MARK: - Transform bridge

    #if canImport(simd)
    /// Flatten a 4x4 world transform to 16 column-major floats for JSON storage.
    static func floats(from m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    /// Rebuild a 4x4 transform from 16 column-major floats; nil if malformed.
    static func matrix(from a: [Float]?) -> simd_float4x4? {
        guard let a, a.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4<Float>(a[0], a[1], a[2], a[3]),
            SIMD4<Float>(a[4], a[5], a[6], a[7]),
            SIMD4<Float>(a[8], a[9], a[10], a[11]),
            SIMD4<Float>(a[12], a[13], a[14], a[15]))
    }

    /// The world-space position (translation column) of a transform.
    static func position(from a: [Float]?) -> SIMD3<Float>? {
        guard let m = matrix(from: a) else { return nil }
        return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
    #endif
}
