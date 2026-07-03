// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Standalone assertions for the memory-palace desktop-sync data-model
// contract: `Palace.updatedAt`'s back-compat decode default, the fact that
// re-encoding always (re)writes that key, and the ISO-8601 wire round-trip
// mcat_tools relies on (contracts/data-model.md, contracts/api.md). These
// types are free of ARKit/SwiftUI/URLSession/Keychain, so they compile and
// run against the host toolchain -- no Simulator or Xcode target needed.
// Run with ./run-sync.sh (compiles PalaceModels.swift + this file with
// swiftc). Exits non-zero on any failure.
//
// Compiled + run separately from PalaceLogicTests.swift via ./run-sync.sh
// (both files declare `@main`, so they must never be compiled together in
// the same swiftc invocation).
//
// SCOPE / SAFETY NOTE -- read before extending this file:
// This suite deliberately compiles and references ONLY PalaceModels.swift.
// It does NOT compile, import, or reference PalaceSyncModel.swift or
// SyncStore.swift, and it calls no Keychain API. Those two files are
// hard-coupled to `URLSession.shared` (no injectable session) and to
// `SyncStore`, a thin Keychain wrapper using service name
// "net.ankiweb.mcat.sync" -- the SAME service shared by
// SyncModel/PracticeModel across every MCAT feature, with no
// dependency-injection seam and no test-specific service name. Exercising
// `SyncStore.save()`, or `PalaceSyncModel.push`/`pushAll`'s network branch,
// from a committed automated test would write into the real shared system
// Keychain under that fixed service name on whatever machine runs the test
// -- on a developer's real laptop that has ever configured MCAT sync (kept
// in the same Keychain item as this feature), that risks clobbering real
// stored credentials, or (if push() were then exercised) firing a live
// network PUT of fabricated test data at a real configured sync server.
// That is a real hazard, not a hypothetical, so nothing in this file may
// import or reference `PalaceSyncModel`/`SyncStore`. This is a documented,
// not-yet-fixed seam -- flagged in this run's
// domains/testing/workers/ios-palace-sync-logic.result.md as a `needs:
// frontend` suggesting a protocol-based `URLSessionProtocol` / injectable
// credentials source for `PalaceSyncModel` in a future round, if deeper
// unit coverage of the push path itself is wanted.
//
// WIRE-TYPE STAND-IN NOTE (why testing `Palace` itself is sufficient):
// `PalaceSyncModel`'s wire DTOs (`WirePalace`/`WireLocus`/`WirePoint`) are
// declared `private` inside PalaceSyncModel.swift, so they cannot be
// referenced from this file even if it were otherwise safe to import that
// source (it is not, per above). However, `WirePalace`'s field set (id,
// name, createdAt, updatedAt, capacity, loci, hasPhoto, hasWorldMap,
// photoVersion) is exactly `Palace`'s own `CodingKeys` case set,
// `WireLocus`'s fields (id, cardID, label, mnemonic, transform, anchorID,
// point, learned) are exactly `Locus`'s synthesized Codable field set, and
// `WirePoint`'s (x, y) match `PalacePoint`'s -- confirmed by reading
// PalaceSyncModel.swift's struct declarations directly. Per that file's own
// doc comment, those DTOs exist ONLY to decouple date-encoding strategy
// from the on-disk `PalaceStore` format, not to change shape. Therefore,
// decoding/encoding the real `Palace`/`Locus`/`PalacePoint` types under a
// locally-instantiated `.iso8601` `JSONEncoder`/`JSONDecoder` (tests 4-5
// below) is a faithful, field-for-field stand-in for what `PalaceSyncModel`
// actually sends and receives over the wire, even though the private
// `WirePalace` mirror itself is unreachable from this file.

import Foundation

@main
enum PalaceSyncLogicTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
    }

    static func main() {
        testBackCompatDecodeKeyAbsent()
        testBackCompatDecodeKeyPresent()
        testReEncodeAlwaysWritesKey()
        testWireISO8601RoundTripContractExample()
        testLocusPassThroughFieldsPopulated()

        print("")
        print(failures == 0 ? "ALL SYNC LOGIC TESTS PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1. Back-compat decode, key absent

    /// Hand-written to look exactly like a real pre-feature on-disk
    /// `palace.json`. `PalaceStore.swift` saves with a bare `JSONEncoder()`
    /// (`.deferredToDate`), so `Date` fields are raw `Double`
    /// `timeIntervalSinceReferenceDate` seconds on disk, NOT ISO-8601
    /// strings -- using ISO-8601 strings here would test the wrong on-disk
    /// shape. No `updatedAt` key and no `photoVersion` key at all (both
    /// postdate this fixture's vintage).
    static let oldPalaceJSONNoUpdatedAt = """
    {
        "id": "550E8400-E29B-41D4-A716-446655440000",
        "name": "Kitchen",
        "createdAt": 750000000.5,
        "capacity": 7,
        "loci": [],
        "hasPhoto": false,
        "hasWorldMap": false
    }
    """

    static func testBackCompatDecodeKeyAbsent() {
        print("== back-compat decode: updatedAt key absent ==")
        do {
            let decoded = try JSONDecoder().decode(Palace.self, from: Data(oldPalaceJSONNoUpdatedAt.utf8))
            check(decoded.updatedAt == decoded.createdAt,
                  "updatedAt defaults to createdAt exactly when the key is missing")
            check(decoded.photoVersion == nil, "photoVersion also defaults to nil when missing (sanity)")
        } catch {
            check(false, "decode of pre-feature palace.json (no updatedAt key) threw: \(error)")
        }
    }

    // MARK: - 2. Back-compat decode, key present (and different from createdAt)

    /// Same shape as case 1, but WITH an explicit `updatedAt` that differs
    /// from `createdAt` -- proves the `?? createdAt` default only kicks in
    /// when the key is truly missing, not whenever convenient.
    static let oldPalaceJSONWithUpdatedAt = """
    {
        "id": "550E8400-E29B-41D4-A716-446655440000",
        "name": "Kitchen",
        "createdAt": 750000000.5,
        "updatedAt": 750086400.25,
        "capacity": 7,
        "loci": [],
        "hasPhoto": false,
        "hasWorldMap": false
    }
    """

    static func testBackCompatDecodeKeyPresent() {
        print("== back-compat decode: updatedAt key present and distinct ==")
        do {
            let decoded = try JSONDecoder().decode(Palace.self, from: Data(oldPalaceJSONWithUpdatedAt.utf8))
            let expectedUpdatedAt = Date(timeIntervalSinceReferenceDate: 750086400.25)
            check(decoded.updatedAt == expectedUpdatedAt,
                  "updatedAt decodes to the supplied value, not a default")
            check(decoded.updatedAt != decoded.createdAt,
                  "updatedAt is distinct from createdAt -- proves the ?? default only fires when the key is truly missing")
        } catch {
            check(false, "decode of palace.json with an explicit updatedAt threw: \(error)")
        }
    }

    // MARK: - 3. Re-encoding always writes the key

    /// Take a `Palace` decoded from case 1 (no `updatedAt` in the source
    /// JSON) and re-encode it with a bare `JSONEncoder()`. The very next
    /// local save must upgrade the on-disk file to carry a concrete
    /// `updatedAt` -- relevant to AC2: a pre-feature palace becomes
    /// push-able (has a real `updatedAt` to send/compare) after its first
    /// local touch.
    static func testReEncodeAlwaysWritesKey() {
        print("== re-encode after back-compat decode always writes updatedAt ==")
        do {
            let decoded = try JSONDecoder().decode(Palace.self, from: Data(oldPalaceJSONNoUpdatedAt.utf8))
            let reEncoded = try JSONEncoder().encode(decoded)
            let obj = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
            check(obj?["updatedAt"] != nil,
                  "re-encoded JSON contains an updatedAt key even though the source JSON had none")
            if let writtenUpdatedAt = obj?["updatedAt"] as? NSNumber,
               let writtenCreatedAt = obj?["createdAt"] as? NSNumber {
                check(writtenUpdatedAt.doubleValue == writtenCreatedAt.doubleValue,
                      "the freshly-written updatedAt equals createdAt (the default applied on load)")
            } else {
                check(false, "expected updatedAt/createdAt to both re-encode as numeric (deferredToDate) values")
            }
        } catch {
            check(false, "decode-then-reencode of pre-feature palace.json threw: \(error)")
        }
    }

    // MARK: - 4. Wire ISO-8601 round-trip against the literal contracts/api.md example

    /// Copied verbatim from contracts/api.md's `GET /palaces/{id}` example.
    static let contractExampleJSON = #"""
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"My Kitchen","createdAt":"2026-06-01T09:00:00Z","updatedAt":"2026-07-02T14:03:11Z","capacity":7,"hasPhoto":true,"hasWorldMap":false,"photoVersion":3,"loci":[{"id":"9B2D0000-0000-0000-0000-000000000001","cardID":1687200000001,"label":"The mitochondria is the...","mnemonic":"power plant on the stove","point":{"x":0.42,"y":0.61},"learned":true,"transform":null,"anchorID":null}]}
    """#

    static func wireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func testWireISO8601RoundTripContractExample() {
        print("== wire ISO-8601 round trip: contracts/api.md GET /palaces/{id} example ==")
        do {
            let decoded = try wireDecoder().decode(Palace.self, from: Data(contractExampleJSON.utf8))
            check(true, "contract example decodes under .iso8601 without throwing")
            check(decoded.loci.count == 1, "loci.count == 1")
            if let locus = decoded.loci.first {
                check(locus.point.x == Float(0.42), "loci[0].point.x == 0.42")
                check(locus.point.y == Float(0.61), "loci[0].point.y == 0.61")
                check(locus.transform == nil, "loci[0].transform == nil")
                check(locus.anchorID == nil, "loci[0].anchorID == nil")
            } else {
                check(false, "expected at least one locus to inspect")
            }

            // The actual round-trip proof: re-encode and confirm the date
            // *strings* are byte-identical to the original literals, not
            // just "it decoded ok".
            let reEncoded = try wireEncoder().encode(decoded)
            let obj = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
            check(obj?["updatedAt"] as? String == "2026-07-02T14:03:11Z",
                  "re-encoded updatedAt string is byte-identical to the original literal")
            check(obj?["createdAt"] as? String == "2026-06-01T09:00:00Z",
                  "re-encoded createdAt string is byte-identical to the original literal")
        } catch {
            check(false, "wire ISO-8601 round trip of the contract example threw: \(error)")
        }
    }

    // MARK: - 5. Locus pass-through fields (transform + anchorID) populated case

    /// Same shape as the contract example, but with a locus that HAS a
    /// non-null `transform` (16-float identity matrix) and a non-null
    /// `anchorID`, per contracts/data-model.md's "pass-through only" note.
    static let contractExampleWithTransformJSON = #"""
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"My Kitchen","createdAt":"2026-06-01T09:00:00Z","updatedAt":"2026-07-02T14:03:11Z","capacity":7,"hasPhoto":true,"hasWorldMap":false,"photoVersion":3,"loci":[{"id":"9B2D0000-0000-0000-0000-000000000001","cardID":1687200000001,"label":"The mitochondria is the...","mnemonic":"power plant on the stove","point":{"x":0.42,"y":0.61},"learned":true,"transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"anchorID":"1A2B3C4D-5E6F-7890-ABCD-EF1234567890"}]}
    """#

    static func testLocusPassThroughFieldsPopulated() {
        print("== locus pass-through fields (transform, anchorID) survive the wire round trip ==")
        let expectedTransform: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let expectedAnchorID = "1A2B3C4D-5E6F-7890-ABCD-EF1234567890"
        do {
            let decoded = try wireDecoder().decode(Palace.self, from: Data(contractExampleWithTransformJSON.utf8))
            guard let locus = decoded.loci.first else {
                check(false, "expected at least one locus to inspect")
                return
            }
            check(locus.transform == expectedTransform, "decoded transform matches the 16-float identity matrix")
            check(locus.anchorID == expectedAnchorID, "decoded anchorID matches the supplied string")

            // Full round trip: encode what we just decoded, decode it
            // again, and confirm both opaque pass-through fields are still
            // exactly what they started as -- the actual "survive
            // unchanged" proof, not just a single decode.
            let reEncoded = try wireEncoder().encode(decoded)
            let roundTripped = try wireDecoder().decode(Palace.self, from: reEncoded)
            guard let roundTrippedLocus = roundTripped.loci.first else {
                check(false, "expected at least one locus after round trip")
                return
            }
            check(roundTrippedLocus.transform == expectedTransform,
                  "transform survives a full encode/decode round trip unchanged")
            check(roundTrippedLocus.anchorID == expectedAnchorID,
                  "anchorID survives a full encode/decode round trip unchanged")
            check(roundTripped == decoded, "whole Palace value is unchanged after the round trip (Equatable check)")
        } catch {
            check(false, "wire ISO-8601 round trip with populated transform/anchorID threw: \(error)")
        }
    }
}
