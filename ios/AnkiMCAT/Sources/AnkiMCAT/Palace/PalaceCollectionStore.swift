// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceCollectionStore — mirrors memory palaces into the Anki collection so
// they ride native sync (replacing the old `mcat_tools` HTTP sidecar +
// PalaceSyncModel). Each palace is one "MCAT Memory Palace" note whose
// `Structure` field is the palace JSON (loci, points, mnemonics — everything
// but the photo bytes) and whose `Photo` field is an `<img src="…">` reference
// into the collection's media folder, so the photo syncs as a media file and
// Anki's media check treats it as "used".
//
// Two directions, both best-effort/silent-fail so they never block or error
// the palace UI:
//   • push  — upsert one palace note (+ media) after a local edit
//   • pull  — merge collection palaces newer than local into the on-disk
//             PalaceStore (last-write-wins by updatedAt), so a palace built on
//             another device (or restored on a fresh install via full sync)
//             appears here.
//
// The on-disk `PalaceStore` remains the local source of truth the AR/2D views
// read from; this type keeps it and the collection reconciled.

import Foundation
import UIKit

actor PalaceCollectionStore {
    static let schemaVersion = 1

    private let engine: AnkiEngine
    /// The collection's media folder (must match ReviewModel's sandbox paths),
    /// where palace photos are read back from after a sync.
    private let mediaFolder: URL
    /// Photo versions already uploaded this session, so an unchanged photo
    /// isn't re-encoded/re-added on every metadata save. In-memory only —
    /// a fresh launch re-uploads once, which is harmless.
    private var lastPushedPhotoVersion: [UUID: Int] = [:]

    init(engine: AnkiEngine, mediaFolder: URL? = nil) {
        self.engine = engine
        if let mediaFolder {
            self.mediaFolder = mediaFolder
        } else {
            let docs = (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.mediaFolder = docs.appendingPathComponent("collection.media", isDirectory: true)
        }
    }

    // MARK: - Wire format (Structure field JSON; ISO-8601 dates + schemaVersion)

    private struct WirePoint: Codable {
        var x: Float
        var y: Float
    }

    private struct WireLocus: Codable {
        var id: UUID
        var cardID: Int64
        var label: String
        var mnemonic: String
        var transform: [Float]?
        var anchorID: String?
        var point: WirePoint
        var learned: Bool
    }

    private struct WirePalace: Codable {
        var schemaVersion: Int
        var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var capacity: Int
        var loci: [WireLocus]
        var hasPhoto: Bool
        var hasWorldMap: Bool
        var photoVersion: Int?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Push (local edit -> collection)

    /// Upsert one palace note (+ its photo media). `photoData` is the freshly
    /// captured bytes when a photo was just saved; otherwise `localPhoto`
    /// provides the on-disk bytes if a (re)upload is needed.
    func push(_ palace: Palace, photoData: Data?, localPhoto: @Sendable () -> Data?) async {
        guard let structureJSON = encodeStructure(palace) else { return }

        var photoField = ""
        if palace.hasPhoto {
            let version = palace.photoVersion ?? 1
            let filename = Self.photoFilename(palaceID: palace.id, version: version)
            photoField = Self.imgTag(filename)
            if lastPushedPhotoVersion[palace.id] != version,
               let data = photoData ?? localPhoto(),
               let jpeg = Self.downscaledJPEG(data) {
                if let stored = try? await engine.addMediaFile(desiredName: filename, data: jpeg) {
                    photoField = Self.imgTag(stored)
                    lastPushedPhotoVersion[palace.id] = version
                }
            }
        }

        try? await engine.upsertPalaceNote(
            fields: [palace.id.uuidString, palace.name, structureJSON, photoField])
    }

    /// Push every local palace (launch-time reconciliation, so the collection
    /// picks up edits made while offline).
    func pushAll(_ palaces: [Palace], photoProvider: @Sendable @escaping (UUID) -> Data?) async {
        for palace in palaces {
            await push(palace, photoData: nil, localPhoto: { photoProvider(palace.id) })
        }
    }

    // MARK: - Pull (collection -> local)

    /// Merge collection palaces that are newer than (or absent from) the local
    /// store into it, copying each photo out of the media folder. Best-effort.
    func pull(into store: PalaceStore) async {
        guard let notes = try? await engine.loadPalaceNotes() else { return }
        let localByID = Dictionary(store.loadAll().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for note in notes {
            guard let data = note.structureJSON.data(using: .utf8),
                  let wire = try? Self.decoder.decode(WirePalace.self, from: data)
            else { continue }
            let incoming = palace(from: wire)
            if let existing = localByID[incoming.id], existing.updatedAt >= incoming.updatedAt {
                continue
            }
            try? store.save(incoming)
            if incoming.hasPhoto, let filename = Self.photoFilename(fromField: note.photoField) {
                let url = mediaFolder.appendingPathComponent(filename)
                if let photo = try? Data(contentsOf: url) {
                    try? store.savePhoto(photo, for: incoming.id)
                }
            }
        }
    }

    // MARK: - Conversions / helpers

    private func encodeStructure(_ palace: Palace) -> String? {
        let wire = WirePalace(
            schemaVersion: Self.schemaVersion,
            id: palace.id,
            name: palace.name,
            createdAt: palace.createdAt,
            updatedAt: palace.updatedAt,
            capacity: palace.capacity,
            loci: palace.loci.map {
                WireLocus(id: $0.id, cardID: $0.cardID, label: $0.label, mnemonic: $0.mnemonic,
                          transform: $0.transform, anchorID: $0.anchorID,
                          point: WirePoint(x: $0.point.x, y: $0.point.y), learned: $0.learned)
            },
            hasPhoto: palace.hasPhoto,
            hasWorldMap: palace.hasWorldMap,
            photoVersion: palace.photoVersion
        )
        guard let data = try? Self.encoder.encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func palace(from wire: WirePalace) -> Palace {
        Palace(
            id: wire.id,
            name: wire.name,
            createdAt: wire.createdAt,
            capacity: wire.capacity,
            loci: wire.loci.map {
                Locus(id: $0.id, cardID: $0.cardID, label: $0.label, mnemonic: $0.mnemonic,
                      transform: $0.transform, anchorID: $0.anchorID,
                      point: PalacePoint(x: $0.point.x, y: $0.point.y), learned: $0.learned)
            },
            hasPhoto: wire.hasPhoto,
            hasWorldMap: wire.hasWorldMap,
            photoVersion: wire.photoVersion,
            updatedAt: wire.updatedAt
        )
    }

    private static func photoFilename(palaceID: UUID, version: Int) -> String {
        "mcat-palace-\(palaceID.uuidString.lowercased())-v\(version).jpg"
    }

    private static func imgTag(_ filename: String) -> String {
        "<img src=\"\(filename)\">"
    }

    /// Extract the media filename from a `Photo` field. Tolerates a bare
    /// filename as well as a full `<img src="…">` tag.
    static func photoFilename(fromField field: String) -> String? {
        if let range = field.range(of: "src=\"") {
            let rest = field[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Downscale + re-encode a photo for storage/sync (max 1600px, JPEG q≈0.7,
    /// with a 5 MB hard cap). Falls back to the input bytes if decoding fails.
    private static func downscaledJPEG(
        _ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7, maxBytes: Int = 5_000_000
    ) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }

        guard var jpeg = resized.jpegData(compressionQuality: quality) else { return data }
        var q = quality
        while jpeg.count > maxBytes, q > 0.3 {
            q -= 0.1
            guard let smaller = resized.jpegData(compressionQuality: q) else { break }
            jpeg = smaller
        }
        return jpeg
    }
}
