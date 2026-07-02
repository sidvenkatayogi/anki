// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceModels — the memory-palace data model.
//
// A "memory palace" (method of loci) is a place the user knows well — a desk, a
// kitchen, a room — captured once, then used as a spatial index for flashcards:
// each vivid location (a "locus") holds one Anki card. Recall is spatial ("what
// card lives here?" / "where does this card live?").
//
// These types are intentionally free of ARKit and SwiftUI so the whole model +
// persistence layer can be unit-tested on its own. AR-specific concerns (the
// world transform) are stored as plain floats; the AR view converts to/from
// simd. Every locus ALSO carries a normalized 2-D photo position, so a palace
// can always be reviewed as a flat "snapshot with pins" when live AR isn't
// available (Simulator, no camera, or a failed relocalize on device).

import Foundation

/// A normalized 2-D point (each component in 0...1) locating a card on the
/// palace's reference photo, measured from the top-left.
struct PalacePoint: Codable, Equatable, Hashable {
    var x: Float
    var y: Float

    init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// One "spot" in a memory palace: a physical location bound to a single Anki
/// card. Carries both a world-space AR transform (device) and a 2-D photo
/// position (always), so either review mode works regardless of AR support.
struct Locus: Codable, Identifiable, Equatable {
    var id: UUID
    /// The Anki card id this locus recalls. Stable across launches while the
    /// same deck stays imported; grading this card feeds the real FSRS scheduler.
    var cardID: Int64
    /// Cached human label (first line of the card's question, HTML-stripped) so
    /// lists render without re-querying the engine. Captured once at placement
    /// time; the live card content is always re-rendered from the engine during
    /// study, so a stale label here only affects list previews, never grading.
    var label: String
    /// Optional user-authored mnemonic tying the card to the location.
    var mnemonic: String
    /// Column-major 4x4 world transform of the AR anchor as 16 floats, or nil
    /// when the locus was placed without AR (photo-only palace).
    var transform: [Float]?
    /// The ARAnchor identifier (UUID string), so the AR view can match rendered
    /// nodes back to loci after relocalization. nil for photo-only loci.
    var anchorID: String?
    /// Normalized position on the reference photo (see `PalacePoint`).
    var point: PalacePoint
    /// Whether the user has recalled this locus correctly at least once.
    var learned: Bool

    init(
        id: UUID = UUID(),
        cardID: Int64,
        label: String,
        mnemonic: String = "",
        transform: [Float]? = nil,
        anchorID: String? = nil,
        point: PalacePoint,
        learned: Bool = false
    ) {
        self.id = id
        self.cardID = cardID
        self.label = label
        self.mnemonic = mnemonic
        self.transform = transform
        self.anchorID = anchorID
        self.point = point
        self.learned = learned
    }
}

/// A memory palace: one captured place holding a bounded set of loci. The room
/// geometry lives in sibling blobs (an ARWorldMap on device and/or a reference
/// photo); this struct is the JSON-serialized metadata for the palace.
struct Palace: Codable, Identifiable, Equatable {
    /// Classic method-of-loci sizing: a handful of vivid, well-separated spots.
    static let defaultCapacity = 7

    var id: UUID
    var name: String
    var createdAt: Date
    /// Max loci before the palace is "full" and the user is asked to capture a
    /// new place to keep placing cards.
    var capacity: Int
    var loci: [Locus]
    /// A reference photo has been saved alongside (thumbnail + 2-D fallback).
    var hasPhoto: Bool
    /// An ARWorldMap has been captured for this palace (device only).
    var hasWorldMap: Bool
    /// Bumped each time the reference photo is (re)saved, so views that cache
    /// the decoded image can tell when to reload. Optional so palaces saved
    /// before this field existed still decode.
    var photoVersion: Int?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        capacity: Int = Palace.defaultCapacity,
        loci: [Locus] = [],
        hasPhoto: Bool = false,
        hasWorldMap: Bool = false,
        photoVersion: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.capacity = capacity
        self.loci = loci
        self.hasPhoto = hasPhoto
        self.hasWorldMap = hasWorldMap
        self.photoVersion = photoVersion
    }

    /// True when no more cards can be placed — the trigger to capture a new place.
    var isFull: Bool { loci.count >= capacity }

    /// How many more loci can be added before the palace is full.
    var remainingSpace: Int { max(0, capacity - loci.count) }

    /// Loci recalled correctly at least once.
    var learnedCount: Int { loci.reduce(0) { $0 + ($1.learned ? 1 : 0) } }
}
