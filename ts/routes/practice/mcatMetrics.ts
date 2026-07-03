// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

/**
 * Pure Performance/Readiness math for the MCAT Practice tab.
 *
 * Every formula here is specified authoritatively in
 * `.factory/runs/2026-07-02-read-practice-tabs/contracts/data-model.md`
 * ("Performance formula" / "Readiness formula" sections) and must match the
 * server and iOS implementations exactly bit-for-bit-ish (cross-platform
 * parity is a testing-domain regression test) -- do not "simplify" or
 * approximate anything in here.
 *
 * No I/O, no Date.now(), no Svelte imports: this module must be importable
 * and testable in complete isolation (e.g. from a future Vitest suite).
 */

export type Category = "bio_biochem" | "chem_phys" | "psych_soc" | "cars";

/** Canonical, fixed order of the 4 MCAT sections/categories. */
export const CATEGORIES: readonly Category[] = [
    "bio_biochem",
    "chem_phys",
    "psych_soc",
    "cars",
];

export interface PracticeHistoryItem {
    question_id: string;
    category: Category;
    correct: boolean;
    difficulty_b: number;
}

export interface FsrsCategorySummary {
    category: Category;
    average_recall: number; // [0,1]
    mastered_fraction: number; // [0,1]
    enough_data: boolean;
    graded_reviews: number;
}

export interface FsrsSummary {
    per_category: FsrsCategorySummary[];
    overall_mean_recall: number;
}

export interface PerformanceCategory {
    category: Category;
    p: number; // [0,1]
    p_low: number; // [0,1] -- 90% CI lower bound (0 when !enough_data)
    p_high: number; // [0,1] -- 90% CI upper bound (0 when !enough_data)
    enough_data: boolean;
    n: number;
}

export interface Performance {
    overall: { p: number; p_low: number; p_high: number; enough_data: boolean; n: number };
    per_category: PerformanceCategory[];
}

export type Confidence = "high" | "medium" | "low";

export interface Readiness {
    score_point: number; // [472,528]
    score_low: number;
    score_high: number;
    confidence: Confidence;
    note: string;
    enough_data: boolean;
}

/** Minimum number of records required before a Performance figure is shown. */
const MIN_N = 5;

/** z-score for a 90% interval (matches the Memory dashboard's 90% CI). */
const Z_90 = 1.645;

/**
 * MAP ability estimate (Rasch / 1-PL), N(0,1) prior, Newton-Raphson.
 *
 * theta_0 = 0
 * p_i(theta) = 1 / (1 + exp(-(theta - b_i)))
 * theta_{k+1} = theta_k + [ sum_i(r_i - p_i(theta_k)) - theta_k ]
 *                          / [ sum_i p_i(theta_k)(1 - p_i(theta_k)) + 1 ]
 *
 * Iterate up to 25x or until |delta| < 1e-4; clamp final theta to [-4, 4].
 */
export function estimateAbility(
    records: { correct: boolean; difficulty_b: number }[],
): number {
    let theta = 0;

    for (let iter = 0; iter < 25; iter++) {
        let numerator = -theta;
        let denominator = 1;

        for (const { correct, difficulty_b } of records) {
            const p = 1 / (1 + Math.exp(-(theta - difficulty_b)));
            numerator += (correct ? 1 : 0) - p;
            denominator += p * (1 - p);
        }

        const delta = numerator / denominator;
        theta += delta;

        if (Math.abs(delta) < 1e-4) {
            break;
        }
    }

    return Math.max(-4, Math.min(4, theta));
}

/** p = 1 / (1 + exp(-theta)) -- probability of a correct answer on a new, average-difficulty (b=0) item. */
function probabilityAtZeroDifficulty(theta: number): number {
    return 1 / (1 + Math.exp(-theta));
}

/**
 * Posterior standard error of the MAP ability estimate. The N(0,1) prior
 * contributes precision 1; each item contributes Fisher information
 * p_i(1-p_i) at the estimate. SE = 1 / sqrt(precision), which shrinks as more
 * questions are answered -- so the Performance range narrows with evidence.
 */
function abilityStdError(
    records: { correct: boolean; difficulty_b: number }[],
    theta: number,
): number {
    let precision = 1;
    for (const { difficulty_b } of records) {
        const p = 1 / (1 + Math.exp(-(theta - difficulty_b)));
        precision += p * (1 - p);
    }
    return 1 / Math.sqrt(precision);
}

/**
 * The point estimate plus a 90% interval for P(correct on a new b=0 item),
 * obtained by pushing the ability CI (theta +/- z*SE) through the logistic.
 */
function performanceEstimate(
    records: { correct: boolean; difficulty_b: number }[],
): { p: number; p_low: number; p_high: number } {
    const theta = estimateAbility(records);
    const se = abilityStdError(records, theta);
    return {
        p: probabilityAtZeroDifficulty(theta),
        p_low: probabilityAtZeroDifficulty(theta - Z_90 * se),
        p_high: probabilityAtZeroDifficulty(theta + Z_90 * se),
    };
}

/**
 * Computes overall and per-category Performance from the full practice
 * history. Each of overall/per-category is gated independently by the
 * `N >= 5` minimum -- e.g. a category with 0 answers always shows
 * "not enough data" even if the overall history is large.
 */
export function computePerformance(history: PracticeHistoryItem[]): Performance {
    const overallN = history.length;
    let overall: { p: number; p_low: number; p_high: number; enough_data: boolean; n: number };
    if (overallN >= MIN_N) {
        overall = { ...performanceEstimate(history), enough_data: true, n: overallN };
    } else {
        overall = { p: 0, p_low: 0, p_high: 0, enough_data: false, n: overallN };
    }

    const per_category: PerformanceCategory[] = CATEGORIES.map((category) => {
        const records = history.filter((r) => r.category === category);
        const n = records.length;
        if (n >= MIN_N) {
            return { category, ...performanceEstimate(records), enough_data: true, n };
        }
        return { category, p: 0, p_low: 0, p_high: 0, enough_data: false, n };
    });

    return { overall, per_category };
}

function clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
}

interface SectionResult {
    scoreSection: number; // rounded int, [118,132]
    halfwidth: number; // [1,7] (or exactly 7 in the "no data" case)
    hasData: boolean; // performance.enough_data OR fsrs.enough_data for this section
}

function computeSection(
    perf: PerformanceCategory,
    fsrs: FsrsCategorySummary,
): SectionResult {
    const performanceHasData = perf.enough_data;
    const fsrsHasData = fsrs.enough_data;

    let proficiency: number;
    let nEff: number;

    if (!performanceHasData && !fsrsHasData) {
        // "No data" section: contributes the mean to the point estimate but
        // the maximum half-width to the interval (data-model.md Step 5).
        proficiency = 0.5;
        nEff = 0;
    } else {
        const mCat = fsrsHasData
            ? clamp(0.6 * fsrs.average_recall + 0.4 * fsrs.mastered_fraction, 0, 1)
            : 0;

        if (performanceHasData && fsrsHasData) {
            proficiency = 0.5 * perf.p + 0.5 * mCat;
        } else if (performanceHasData) {
            proficiency = perf.p;
        } else {
            proficiency = mCat;
        }

        nEff = perf.n + 0.2 * fsrs.graded_reviews;
    }

    const scoreSection = Math.round(clamp(118 + 14 * proficiency, 118, 132));
    const halfwidth = clamp(14 / Math.sqrt(1 + nEff), 1, 7);

    return {
        scoreSection,
        halfwidth,
        hasData: performanceHasData || fsrsHasData,
    };
}

/**
 * Computes the projected MCAT scaled-score Readiness from Performance and
 * FsrsSummary, per data-model.md's "Readiness formula" Steps 1-5.
 */
export function computeReadiness(performance: Performance, fsrs: FsrsSummary): Readiness {
    const sections: SectionResult[] = CATEGORIES.map((category) => {
        const perf = performance.per_category.find((p) => p.category === category) ?? {
            category,
            p: 0,
            p_low: 0,
            p_high: 0,
            enough_data: false,
            n: 0,
        };
        const fsrsCat = fsrs.per_category.find((f) => f.category === category) ?? {
            category,
            average_recall: 0,
            mastered_fraction: 0,
            enough_data: false,
            graded_reviews: 0,
        };
        return computeSection(perf, fsrsCat);
    });

    let scorePoint = 0;
    let scoreLow = 0;
    let scoreHigh = 0;
    let halfwidthSum = 0;
    let sectionsWithData = 0;

    for (const section of sections) {
        scorePoint += section.scoreSection;
        scoreLow += clamp(section.scoreSection - section.halfwidth, 118, 132);
        scoreHigh += clamp(section.scoreSection + section.halfwidth, 118, 132);
        halfwidthSum += section.halfwidth;
        if (section.hasData) {
            sectionsWithData++;
        }
    }

    const avgHalfwidth = halfwidthSum / sections.length;
    let confidence: Confidence;
    if (avgHalfwidth <= 2) {
        confidence = "high";
    } else if (avgHalfwidth <= 4) {
        confidence = "medium";
    } else {
        confidence = "low";
    }

    const enoughData = sectionsWithData >= 2;

    return {
        score_point: scorePoint,
        score_low: Math.round(scoreLow),
        score_high: Math.round(scoreHigh),
        confidence,
        note: enoughData
            ? ""
            : "Answer more practice questions or review more cards to see a projected score.",
        enough_data: enoughData,
    };
}
