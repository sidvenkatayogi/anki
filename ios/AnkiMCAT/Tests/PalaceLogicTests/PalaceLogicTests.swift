// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Standalone assertions for the memory palace's pure core (models, logic,
// store). These types are deliberately free of ARKit/SwiftUI/engine, so they
// compile and run against the host toolchain — no Simulator or Xcode target
// needed. Run with ./run.sh (compiles the real Palace/*.swift sources + this
// file with swiftc). Exits non-zero on any failure.

import Foundation
import simd

@main
enum PalaceLogicTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
    }

    static func main() {
        testLabel()
        testCapacity()
        testStudySteps()
        testTransformBridge()
        testStoreRoundtrip()
        testStats()

        print("")
        print(failures == 0 ? "ALL LOGIC TESTS PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    static func testStats() {
        print("== stats ==")
        check(PalaceLogic.accuracyPercent(correct: 3, total: 4) == 75, "accuracy 75%")
        check(PalaceLogic.accuracyPercent(correct: 0, total: 0) == 0, "accuracy empty -> 0")
        check(PalaceLogic.accuracyPercent(correct: 1, total: 3) == 33, "accuracy rounds to 33")
        check(PalaceLogic.accuracyPercent(correct: 2, total: 3) == 67, "accuracy rounds to 67")
        var p = Palace(name: "x", capacity: 4)
        check(PalaceLogic.learnedFraction(p) == 0, "empty learnedFraction is 0")
        p.loci = [
            Locus(cardID: 1, label: "a", point: PalacePoint(x: 0, y: 0), learned: true),
            Locus(cardID: 2, label: "b", point: PalacePoint(x: 0, y: 0), learned: false),
        ]
        check(PalaceLogic.learnedFraction(p) == 0.5, "half learned -> 0.5")
    }

    static func testLabel() {
        print("== label(fromHTML:) ==")
        check(PalaceLogic.label(fromHTML: "<b>Krebs cycle</b>") == "Krebs cycle", "strips tags")
        check(PalaceLogic.label(fromHTML: "<style>.x{}</style>Acetyl&amp;CoA") == "Acetyl&CoA",
              "drops style block, decodes entity")
        check(PalaceLogic.label(fromHTML: "a\n\n  b\tc") == "a b c", "collapses whitespace")
        check(PalaceLogic.label(fromHTML: "<div></div>") == "(untitled card)", "empty -> placeholder")
        check(PalaceLogic.label(fromHTML: String(repeating: "x", count: 200), maxLength: 10).hasSuffix("…"),
              "truncates with ellipsis")
        check(PalaceLogic.label(fromHTML: "MileDown::Gen_Chem::Atoms In element notation X")
              == "Atoms In element notation X", "strips deck breadcrumb")
        check(PalaceLogic.stripBreadcrumb("A::B::leaf text here") == "leaf text here", "strip helper")
        check(PalaceLogic.stripBreadcrumb("no breadcrumb here") == "no breadcrumb here", "no-op without ::")
        check(PalaceLogic.stripBreadcrumb("has space :: y") == "has space :: y",
              "no strip when prefix has spaces (real content)")
    }

    static func testCapacity() {
        print("== capacity ==")
        var p = Palace(name: "Desk", capacity: 3)
        check(!p.isFull && p.remainingSpace == 3, "empty not full")
        for i in 0..<3 { p.loci.append(Locus(cardID: Int64(i), label: "c\(i)", point: PalacePoint(x: 0.1, y: 0.1))) }
        check(p.isFull && p.remainingSpace == 0 && !PalaceLogic.canPlace(in: p), "full at capacity")
        p.loci[0].learned = true
        check(p.learnedCount == 1, "learnedCount")
    }

    static func testStudySteps() {
        print("== study steps ==")
        let order = (0..<4).map { Locus(cardID: Int64($0), label: "c\($0)", point: PalacePoint(x: 0, y: 0)) }
        let recall = PalaceLogic.buildSteps(order: order, mode: .recall)
        check(recall.count == 4 && recall.allSatisfy { $0.mode == .recall }, "recall all recall")
        let mixed = PalaceLogic.buildSteps(order: order, mode: .mixed)
        check(mixed.map(\.mode) == [.recall, .locate, .recall, .locate], "mixed alternates")
        check(PalaceLogic.isLocateCorrect(selected: order[1].id, target: order[1].id), "locate correct")
        check(!PalaceLogic.isLocateCorrect(selected: order[0].id, target: order[1].id), "locate wrong")
    }

    static func testTransformBridge() {
        print("== transform bridge ==")
        let m = simd_float4x4(SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16))
        let arr = PalaceLogic.floats(from: m)
        check(arr.count == 16 && arr[12] == 13, "flatten col-major")
        check(PalaceLogic.matrix(from: arr) == m, "roundtrip matrix")
        check(PalaceLogic.matrix(from: [1, 2, 3]) == nil, "malformed -> nil")
        check(PalaceLogic.position(from: arr) == SIMD3<Float>(13, 14, 15), "position column")
    }

    static func testStoreRoundtrip() {
        print("== store roundtrip ==")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palacetest-\(UUID().uuidString)")
        let store = PalaceStore(rootURL: tmp)
        let arr = PalaceLogic.floats(from: matrix_identity_float4x4)
        var p = Palace(name: "Kitchen", capacity: 5)
        p.loci.append(Locus(cardID: 42, label: "mitochondria", transform: arr,
                            anchorID: "abc", point: PalacePoint(x: 0.5, y: 0.5), learned: true))
        do {
            try store.save(p)
            try store.savePhoto(Data([0xFF, 0xD8, 0xFF]), for: p.id)
            try store.saveWorldMap(Data([1, 2, 3, 4]), for: p.id)
            let loaded = store.loadAll()
            check(loaded.count == 1 && loaded[0].name == "Kitchen", "load saved palace")
            check(loaded[0].loci.first?.cardID == 42 && loaded[0].loci.first?.transform == arr,
                  "locus persisted with transform")
            check(store.loadPhotoData(for: p.id) == Data([0xFF, 0xD8, 0xFF]), "photo blob roundtrip")
            check(store.hasWorldMap(p.id) && store.loadWorldMap(for: p.id) == Data([1, 2, 3, 4]),
                  "worldmap blob roundtrip")
            try store.delete(p.id)
            check(store.loadAll().isEmpty, "delete removes palace")
        } catch {
            check(false, "store threw: \(error)")
        }
        try? FileManager.default.removeItem(at: tmp)
    }
}
