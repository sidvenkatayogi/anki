// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceStore — on-disk persistence for memory palaces. Each palace is a folder
// under Documents/MemoryPalaces/<uuid>/ holding:
//   palace.json          metadata + loci (this struct's Codable payload)
//   photo.jpg            reference room image (thumbnail + 2-D fallback)
//   worldmap.arworldmap  archived ARWorldMap for relocalization (device only)
//
// Foundation-only and root-injectable, so it can be unit-tested against a temp
// directory without a running app. The AR view owns ARWorldMap (un)archiving and
// hands this store a plain Data blob.

import Foundation

struct PalaceStore {
    /// Directory that contains one subfolder per palace.
    let rootURL: URL

    /// Default store lives under the app's Documents sandbox; tests inject a temp
    /// root. Falls back to the temp dir if Documents is somehow unavailable.
    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let docs = (try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = docs.appendingPathComponent("MemoryPalaces", isDirectory: true)
        }
    }

    // MARK: - Paths

    func palaceDir(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func jsonURL(_ id: UUID) -> URL {
        palaceDir(id).appendingPathComponent("palace.json")
    }

    func photoURL(_ id: UUID) -> URL {
        palaceDir(id).appendingPathComponent("photo.jpg")
    }

    func worldMapURL(_ id: UUID) -> URL {
        palaceDir(id).appendingPathComponent("worldmap.arworldmap")
    }

    // MARK: - Palace metadata

    /// Load every palace, newest first. Skips any folder whose JSON is missing
    /// or unreadable rather than failing the whole load.
    func loadAll() -> [Palace] {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        let decoder = JSONDecoder()
        var palaces: [Palace] = []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let url = entry.appendingPathComponent("palace.json")
            guard let data = try? Data(contentsOf: url),
                  let palace = try? decoder.decode(Palace.self, from: data) else { continue }
            palaces.append(palace)
        }
        return palaces.sorted { $0.createdAt > $1.createdAt }
    }

    /// Write a palace's metadata (creates its folder if needed).
    func save(_ palace: Palace) throws {
        try FileManager.default.createDirectory(at: palaceDir(palace.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(palace)
        try data.write(to: jsonURL(palace.id), options: .atomic)
    }

    /// Remove a palace and all its blobs.
    func delete(_ id: UUID) throws {
        let dir = palaceDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Photo

    func savePhoto(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: palaceDir(id), withIntermediateDirectories: true)
        try data.write(to: photoURL(id), options: .atomic)
    }

    func loadPhotoData(for id: UUID) -> Data? {
        try? Data(contentsOf: photoURL(id))
    }

    // MARK: - World map (opaque blob; archiving handled by the AR view)

    func saveWorldMap(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: palaceDir(id), withIntermediateDirectories: true)
        try data.write(to: worldMapURL(id), options: .atomic)
    }

    func loadWorldMap(for id: UUID) -> Data? {
        try? Data(contentsOf: worldMapURL(id))
    }

    func hasWorldMap(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: worldMapURL(id).path)
    }
}
