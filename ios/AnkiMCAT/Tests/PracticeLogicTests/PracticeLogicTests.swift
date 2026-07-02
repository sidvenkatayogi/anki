// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Standalone assertions for the Practice tab's pure core (MCATMetrics,
// PracticeStore). Mirrors the fixtures already proven in
// `ts/routes/practice/mcatMetrics.test.ts` for cross-platform parity. Run
// with ./run.sh (compiles the real Practice/*.swift sources + this file with
// swiftc). No Simulator or Xcode target needed. Exits non-zero on failure.

import Foundation

@main
enum PracticeLogicTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
    }

    static func closeTo(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        abs(a - b) < eps
    }

    static func main() {
        testEstimateAbility()
        testComputePerformance()
        testComputeReadiness()
        testPracticeStore()

        print("")
        print(failures == 0 ? "ALL LOGIC TESTS PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    static func testEstimateAbility() {
        print("== estimateAbility ==")
        check(closeTo(MCATMetrics.estimateAbility([]), 0), "no records stays at prior mean (0)")

        let allCorrect = MCATMetrics.estimateAbility(Array(repeating: (correct: true, difficultyB: 0.0), count: 5))
        check(allCorrect > 0 && allCorrect <= 4, "all correct at b=0 pulls theta positive")

        let allWrong = MCATMetrics.estimateAbility(Array(repeating: (correct: false, difficultyB: 0.0), count: 5))
        check(allWrong < 0 && allWrong >= -4, "all incorrect at b=0 pulls theta negative")
    }

    static func item(_ category: MCATCategory, _ correct: Bool, _ difficultyB: Double = 0) -> PracticeHistoryItem {
        PracticeHistoryItem(questionId: "q", category: category, correct: correct, difficultyB: difficultyB)
    }

    static func testComputePerformance() {
        print("== computePerformance ==")

        let below: [PracticeHistoryItem] = [
            item(.bioBiochem, true), item(.bioBiochem, true), item(.bioBiochem, false),
        ]
        let perfBelow = MCATMetrics.computePerformance(below)
        check(perfBelow.overall.enoughData == false, "below MIN_N(5): overall not enough data")
        check(perfBelow.overall.n == 3, "below MIN_N(5): overall n == 3")
        check(perfBelow.overall.p == 0, "below MIN_N(5): overall p == 0")

        let bio = perfBelow.perCategory.first { $0.category == .bioBiochem }!
        check(bio.enoughData == false, "below MIN_N(5): bio not enough data")
        check(bio.n == 3, "below MIN_N(5): bio n == 3")

        let cars = perfBelow.perCategory.first { $0.category == .cars }!
        check(cars.enoughData == false, "untouched category always not-enough-data")
        check(cars.n == 0, "untouched category n == 0")

        let fiveCorrect: [PracticeHistoryItem] = Array(repeating: item(.bioBiochem, true), count: 5)
        let perfFive = MCATMetrics.computePerformance(fiveCorrect)
        check(perfFive.overall.enoughData == true, "N>=5: overall enough data")
        check(perfFive.overall.n == 5, "N>=5: overall n == 5")
        check(perfFive.overall.p > 0.5, "N>=5: overall p > 0.5")

        let bio5 = perfFive.perCategory.first { $0.category == .bioBiochem }!
        check(bio5.enoughData == true, "N>=5: bio enough data")
        check(bio5.n == 5, "N>=5: bio n == 5")

        let chem5 = perfFive.perCategory.first { $0.category == .chemPhys }!
        check(chem5.enoughData == false, "N>=5 in one category doesn't spill to another")
    }

    static func emptyFsrs() -> FsrsSummary {
        FsrsSummary(perCategory: MCATCategory.allCases.map {
            FsrsCategorySummary(category: $0, averageRecall: 0, masteredFraction: 0, enoughData: false, gradedReviews: 0)
        }, overallMeanRecall: 0)
    }

    static func testComputeReadiness() {
        print("== computeReadiness ==")

        let perfEmpty = MCATMetrics.computePerformance([])
        let readinessEmpty = MCATMetrics.computeReadiness(perfEmpty, emptyFsrs())
        check(readinessEmpty.scorePoint == 500, "no data anywhere: score_point == 500")
        check(readinessEmpty.scoreLow == 500 - 28, "no data anywhere: score_low == 472")
        check(readinessEmpty.scoreHigh == 500 + 28, "no data anywhere: score_high == 528")
        check(readinessEmpty.confidence == .low, "no data anywhere: confidence == low")
        check(readinessEmpty.enoughData == false, "no data anywhere: enough_data == false")
        check(!readinessEmpty.note.isEmpty, "no data anywhere: note is non-empty")
        check(readinessEmpty.note == "Answer more practice questions or review more cards to see a projected score.",
              "no data anywhere: note text matches verbatim")

        var strongHistory: [PracticeHistoryItem] = []
        for category in MCATCategory.allCases {
            for _ in 0..<30 {
                strongHistory.append(item(category, true, -2))
            }
        }
        let perfStrong = MCATMetrics.computePerformance(strongHistory)
        let fsrsStrong = FsrsSummary(perCategory: MCATCategory.allCases.map {
            FsrsCategorySummary(category: $0, averageRecall: 1, masteredFraction: 1, enoughData: true, gradedReviews: 500)
        }, overallMeanRecall: 1)
        let readinessStrong = MCATMetrics.computeReadiness(perfStrong, fsrsStrong)
        check(readinessStrong.enoughData == true, "strong mastery: enough_data == true")
        check(readinessStrong.scorePoint == 520, "strong mastery: score_point == 520")
        check(readinessStrong.scoreLow > 500, "strong mastery: score_low > 500")
        check(readinessStrong.scoreHigh <= 528, "strong mastery: score_high <= 528")
        check(readinessStrong.confidence == .high, "strong mastery: confidence == high")
    }

    static func testPracticeStore() {
        print("== PracticeStore ==")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PracticeLogicTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PracticeStore(rootURL: tmp)
        check(store.loadAll().isEmpty, "fresh store loads empty")

        let record = PracticeRecord(clientAnswerId: "id-1", questionId: "seed-001", category: "bio_biochem",
                                     correct: true, difficultyB: 0.0, answeredAt: 1_700_000_000)
        try? store.append(record)
        check(store.loadAll().count == 1, "append adds one record")

        // Append-if-absent: re-appending the same clientAnswerId is a no-op.
        try? store.append(record)
        check(store.loadAll().count == 1, "duplicate clientAnswerId is deduped")

        let record2 = PracticeRecord(clientAnswerId: "id-2", questionId: "seed-002", category: "chem_phys",
                                      correct: false, difficultyB: 0.5, answeredAt: 1_700_000_100)
        try? store.append(record2)
        check(store.loadAll().count == 2, "distinct clientAnswerId appends a second record")

        // Tolerant load: corrupt JSON should not crash, just yield [].
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? "not valid json".data(using: .utf8)!.write(to: tmp.appendingPathComponent("history.json"))
        check(store.loadAll().isEmpty, "corrupt history.json is tolerated (loads empty, doesn't crash)")
    }
}
