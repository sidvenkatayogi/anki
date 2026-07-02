// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import { expect, test } from "vitest";

import type { FsrsSummary, PracticeHistoryItem } from "./mcatMetrics";
import { computePerformance, computeReadiness, estimateAbility } from "./mcatMetrics";

test("estimateAbility: no records stays at prior mean (0)", () => {
    expect(estimateAbility([])).toBeCloseTo(0, 6);
});

test("estimateAbility: all correct at b=0 pulls theta positive", () => {
    const theta = estimateAbility([
        { correct: true, difficulty_b: 0 },
        { correct: true, difficulty_b: 0 },
        { correct: true, difficulty_b: 0 },
        { correct: true, difficulty_b: 0 },
        { correct: true, difficulty_b: 0 },
    ]);
    expect(theta).toBeGreaterThan(0);
    expect(theta).toBeLessThanOrEqual(4);
});

test("estimateAbility: all incorrect at b=0 pulls theta negative", () => {
    const theta = estimateAbility([
        { correct: false, difficulty_b: 0 },
        { correct: false, difficulty_b: 0 },
        { correct: false, difficulty_b: 0 },
        { correct: false, difficulty_b: 0 },
        { correct: false, difficulty_b: 0 },
    ]);
    expect(theta).toBeLessThan(0);
    expect(theta).toBeGreaterThanOrEqual(-4);
});

function item(
    category: PracticeHistoryItem["category"],
    correct: boolean,
    difficulty_b = 0,
): PracticeHistoryItem {
    return { question_id: "q", category, correct, difficulty_b };
}

test("computePerformance: below MIN_N(5) reports not-enough-data", () => {
    const history: PracticeHistoryItem[] = [
        item("bio_biochem", true),
        item("bio_biochem", true),
        item("bio_biochem", false),
    ];
    const perf = computePerformance(history);
    expect(perf.overall.enough_data).toBe(false);
    expect(perf.overall.n).toBe(3);
    expect(perf.overall.p).toBe(0);

    const bio = perf.per_category.find((c) => c.category === "bio_biochem")!;
    expect(bio.enough_data).toBe(false);
    expect(bio.n).toBe(3);

    // untouched categories always show not-enough-data independently
    const cars = perf.per_category.find((c) => c.category === "cars")!;
    expect(cars.enough_data).toBe(false);
    expect(cars.n).toBe(0);
});

test("computePerformance: N>=5 in one category computes independently of overall", () => {
    const history: PracticeHistoryItem[] = [
        item("bio_biochem", true),
        item("bio_biochem", true),
        item("bio_biochem", true),
        item("bio_biochem", true),
        item("bio_biochem", true),
    ];
    const perf = computePerformance(history);
    expect(perf.overall.enough_data).toBe(true);
    expect(perf.overall.n).toBe(5);
    expect(perf.overall.p).toBeGreaterThan(0.5);

    const bio = perf.per_category.find((c) => c.category === "bio_biochem")!;
    expect(bio.enough_data).toBe(true);
    expect(bio.n).toBe(5);

    const chem = perf.per_category.find((c) => c.category === "chem_phys")!;
    expect(chem.enough_data).toBe(false);
});

function emptyFsrs(): FsrsSummary {
    return {
        per_category: [
            { category: "bio_biochem", average_recall: 0, mastered_fraction: 0, enough_data: false, graded_reviews: 0 },
            { category: "chem_phys", average_recall: 0, mastered_fraction: 0, enough_data: false, graded_reviews: 0 },
            { category: "psych_soc", average_recall: 0, mastered_fraction: 0, enough_data: false, graded_reviews: 0 },
            { category: "cars", average_recall: 0, mastered_fraction: 0, enough_data: false, graded_reviews: 0 },
        ],
        overall_mean_recall: 0,
    };
}

test("computeReadiness: no data anywhere -> score centered at 500, wide interval, not enough data", () => {
    const perf = computePerformance([]);
    const readiness = computeReadiness(perf, emptyFsrs());

    // 4 sections * 125 (proficiency 0.5 -> 118+14*0.5=125)
    expect(readiness.score_point).toBe(500);
    // 4 sections * halfwidth 7 (14/sqrt(1+0)=14, clamped to 7)
    expect(readiness.score_low).toBe(500 - 28);
    expect(readiness.score_high).toBe(500 + 28);
    expect(readiness.confidence).toBe("low");
    expect(readiness.enough_data).toBe(false);
    expect(readiness.note.length).toBeGreaterThan(0);
});

test("computeReadiness: strong mastery + strong performance in every category -> high score, high confidence", () => {
    const history: PracticeHistoryItem[] = [];
    for (const category of ["bio_biochem", "chem_phys", "psych_soc", "cars"] as const) {
        for (let i = 0; i < 30; i++) {
            history.push(item(category, true, -2));
        }
    }
    const perf = computePerformance(history);

    const fsrs: FsrsSummary = {
        per_category: (["bio_biochem", "chem_phys", "psych_soc", "cars"] as const).map((category) => ({
            category,
            average_recall: 1,
            mastered_fraction: 1,
            enough_data: true,
            graded_reviews: 500,
        })),
        overall_mean_recall: 1,
    };

    const readiness = computeReadiness(perf, fsrs);
    expect(readiness.enough_data).toBe(true);
    // Hand-computed reference: theta from 30x(correct,b=-2) ~= 1.188, so
    // p ~= 0.766; m_cat = 0.6*1 + 0.4*1 = 1; proficiency = 0.5*0.766+0.5*1
    // ~= 0.883; score_section = round(118+14*0.883) = 130 per section.
    expect(readiness.score_point).toBe(520);
    expect(readiness.score_low).toBeGreaterThan(500);
    expect(readiness.score_high).toBeLessThanOrEqual(528);
    expect(readiness.confidence).toBe("high");
});
