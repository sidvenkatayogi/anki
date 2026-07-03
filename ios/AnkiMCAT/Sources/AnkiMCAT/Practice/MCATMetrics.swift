// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Pure Performance/Readiness math for the MCAT Practice tab.
//
// Every formula here is specified authoritatively in
// `.factory/runs/2026-07-02-read-practice-tabs/contracts/data-model.md`
// ("Performance formula" / "Readiness formula" sections) and is a field-for-
// field port of `ts/routes/practice/mcatMetrics.ts` -- do not "simplify" or
// approximate anything here; server, desktop-fallback, and iOS-fallback must
// produce identical numbers (cross-platform parity is a testing-domain
// regression test).
//
// Foundation-only (no networking, no SwiftUI) so
// `ios/AnkiMCAT/Tests/PracticeLogicTests/run.sh` can swiftc-compile+run this
// file standalone, with no Simulator or Xcode project needed.

import Foundation

/// The 4 canonical MCAT categories/sections, fixed order.
enum MCATCategory: String, Codable, CaseIterable {
    case bioBiochem = "bio_biochem"
    case chemPhys = "chem_phys"
    case psychSoc = "psych_soc"
    case cars = "cars"
}

struct PracticeHistoryItem {
    var questionId: String
    var category: MCATCategory
    var correct: Bool
    var difficultyB: Double
}

struct FsrsCategorySummary {
    var category: MCATCategory
    var averageRecall: Double // [0,1]
    var masteredFraction: Double // [0,1]
    var enoughData: Bool
    var gradedReviews: Int
}

struct FsrsSummary {
    var perCategory: [FsrsCategorySummary]
    var overallMeanRecall: Double
}

struct PerformanceCategory {
    var category: MCATCategory
    var p: Double // [0,1]
    var pLow: Double // [0,1] -- 90% CI lower bound (0 when !enoughData)
    var pHigh: Double // [0,1] -- 90% CI upper bound (0 when !enoughData)
    var enoughData: Bool
    var n: Int
}

struct Performance {
    var overall: (p: Double, pLow: Double, pHigh: Double, enoughData: Bool, n: Int)
    var perCategory: [PerformanceCategory]
}

enum Confidence: String {
    case high, medium, low
}

struct Readiness {
    var scorePoint: Int // [472,528]
    var scoreLow: Int
    var scoreHigh: Int
    var confidence: Confidence
    var note: String
    var enoughData: Bool
}

enum MCATMetrics {
    /// Minimum number of records required before a Performance figure is shown.
    private static let minN = 5

    /// z-score for a 90% interval (matches the Memory dashboard's 90% CI).
    private static let z90 = 1.645

    /// MAP ability estimate (Rasch / 1-PL), N(0,1) prior, Newton-Raphson.
    ///
    /// theta_0 = 0
    /// p_i(theta) = 1 / (1 + exp(-(theta - b_i)))
    /// theta_{k+1} = theta_k + [ sum_i(r_i - p_i(theta_k)) - theta_k ]
    ///                          / [ sum_i p_i(theta_k)(1 - p_i(theta_k)) + 1 ]
    ///
    /// Iterate up to 25x or until |delta| < 1e-4; clamp final theta to [-4, 4].
    static func estimateAbility(_ records: [(correct: Bool, difficultyB: Double)]) -> Double {
        var theta = 0.0

        for _ in 0..<25 {
            var numerator = -theta
            var denominator = 1.0

            for (correct, difficultyB) in records {
                let p = 1 / (1 + exp(-(theta - difficultyB)))
                numerator += (correct ? 1.0 : 0.0) - p
                denominator += p * (1 - p)
            }

            let delta = numerator / denominator
            theta += delta

            if abs(delta) < 1e-4 {
                break
            }
        }

        return max(-4, min(4, theta))
    }

    /// p = 1 / (1 + exp(-theta)) -- probability of a correct answer on a new,
    /// average-difficulty (b=0) item.
    private static func probabilityAtZeroDifficulty(_ theta: Double) -> Double {
        1 / (1 + exp(-theta))
    }

    /// Posterior standard error of the MAP ability estimate. The N(0,1) prior
    /// contributes precision 1; each item contributes Fisher information
    /// p_i(1-p_i) at the estimate. SE = 1 / sqrt(precision), so the Performance
    /// range narrows as more questions are answered.
    private static func abilityStdError(_ records: [(correct: Bool, difficultyB: Double)],
                                        _ theta: Double) -> Double {
        var precision = 1.0
        for (_, difficultyB) in records {
            let p = 1 / (1 + exp(-(theta - difficultyB)))
            precision += p * (1 - p)
        }
        return 1 / sqrt(precision)
    }

    /// The point estimate plus a 90% interval for P(correct on a new b=0 item),
    /// obtained by pushing the ability CI (theta +/- z*SE) through the logistic.
    private static func performanceEstimate(_ records: [(correct: Bool, difficultyB: Double)])
        -> (p: Double, pLow: Double, pHigh: Double) {
        let theta = estimateAbility(records)
        let se = abilityStdError(records, theta)
        return (
            probabilityAtZeroDifficulty(theta),
            probabilityAtZeroDifficulty(theta - z90 * se),
            probabilityAtZeroDifficulty(theta + z90 * se)
        )
    }

    /// Computes overall and per-category Performance from the full practice
    /// history. Each of overall/per-category is gated independently by the
    /// `N >= 5` minimum -- e.g. a category with 0 answers always shows
    /// "not enough data" even if the overall history is large.
    static func computePerformance(_ history: [PracticeHistoryItem]) -> Performance {
        let overallN = history.count
        var overall: (p: Double, pLow: Double, pHigh: Double, enoughData: Bool, n: Int)
        if overallN >= minN {
            let est = performanceEstimate(history.map { ($0.correct, $0.difficultyB) })
            overall = (est.p, est.pLow, est.pHigh, true, overallN)
        } else {
            overall = (0, 0, 0, false, overallN)
        }

        let perCategory: [PerformanceCategory] = MCATCategory.allCases.map { category in
            let records = history.filter { $0.category == category }
            let n = records.count
            if n >= minN {
                let est = performanceEstimate(records.map { ($0.correct, $0.difficultyB) })
                return PerformanceCategory(category: category, p: est.p, pLow: est.pLow,
                                            pHigh: est.pHigh, enoughData: true, n: n)
            }
            return PerformanceCategory(category: category, p: 0, pLow: 0, pHigh: 0,
                                        enoughData: false, n: n)
        }

        return Performance(overall: overall, perCategory: perCategory)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, value))
    }

    private struct SectionResult {
        var scoreSection: Int // rounded int, [118,132]
        var halfwidth: Double // [1,7] (or exactly 7 in the "no data" case)
        var hasData: Bool // performance.enoughData OR fsrs.enoughData for this section
    }

    private static func computeSection(_ perf: PerformanceCategory,
                                        _ fsrs: FsrsCategorySummary) -> SectionResult {
        let performanceHasData = perf.enoughData
        let fsrsHasData = fsrs.enoughData

        var proficiency: Double
        var nEff: Double

        if !performanceHasData && !fsrsHasData {
            // "No data" section: contributes the mean to the point estimate
            // but the maximum half-width to the interval (data-model.md
            // Step 5).
            proficiency = 0.5
            nEff = 0
        } else {
            let mCat = fsrsHasData
                ? clamp(0.6 * fsrs.averageRecall + 0.4 * fsrs.masteredFraction, 0, 1)
                : 0

            if performanceHasData && fsrsHasData {
                proficiency = 0.5 * perf.p + 0.5 * mCat
            } else if performanceHasData {
                proficiency = perf.p
            } else {
                proficiency = mCat
            }

            nEff = Double(perf.n) + 0.2 * Double(fsrs.gradedReviews)
        }

        let scoreSection = Int((clamp(118 + 14 * proficiency, 118, 132)).rounded())
        let halfwidth = clamp(14 / sqrt(1 + nEff), 1, 7)

        return SectionResult(scoreSection: scoreSection, halfwidth: halfwidth,
                              hasData: performanceHasData || fsrsHasData)
    }

    /// Computes the projected MCAT scaled-score Readiness from Performance and
    /// FsrsSummary, per data-model.md's "Readiness formula" Steps 1-5.
    static func computeReadiness(_ performance: Performance, _ fsrs: FsrsSummary) -> Readiness {
        let sections: [SectionResult] = MCATCategory.allCases.map { category in
            let perf = performance.perCategory.first { $0.category == category }
                ?? PerformanceCategory(category: category, p: 0, pLow: 0, pHigh: 0,
                                        enoughData: false, n: 0)
            let fsrsCat = fsrs.perCategory.first { $0.category == category }
                ?? FsrsCategorySummary(category: category, averageRecall: 0, masteredFraction: 0,
                                        enoughData: false, gradedReviews: 0)
            return computeSection(perf, fsrsCat)
        }

        var scorePoint = 0
        var scoreLowSum = 0.0
        var scoreHighSum = 0.0
        var halfwidthSum = 0.0
        var sectionsWithData = 0

        for section in sections {
            scorePoint += section.scoreSection
            scoreLowSum += clamp(Double(section.scoreSection) - section.halfwidth, 118, 132)
            scoreHighSum += clamp(Double(section.scoreSection) + section.halfwidth, 118, 132)
            halfwidthSum += section.halfwidth
            if section.hasData {
                sectionsWithData += 1
            }
        }

        let avgHalfwidth = halfwidthSum / Double(sections.count)
        let confidence: Confidence
        if avgHalfwidth <= 2 {
            confidence = .high
        } else if avgHalfwidth <= 4 {
            confidence = .medium
        } else {
            confidence = .low
        }

        let enoughData = sectionsWithData >= 2

        return Readiness(
            scorePoint: scorePoint,
            scoreLow: Int(scoreLowSum.rounded()),
            scoreHigh: Int(scoreHighSum.rounded()),
            confidence: confidence,
            note: enoughData
                ? ""
                : "Answer more practice questions or review more cards to see a projected score.",
            enoughData: enoughData
        )
    }
}
