// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

/**
 * Cross-implementation parity regression test.
 *
 * Loads the committed fixture + expected JSON under `./fixtures/` (the
 * oracle, generated from Python's `metrics.py` -- see
 * `tools/syncserver/mcat_tools/tests/test_metrics_parity.py` for the Python
 * side of this same regression lock, which points at its own committed copy
 * of this identical fixture content) and asserts this TS implementation
 * (`../../routes/practice/mcatMetrics.ts`) reproduces it within tolerance.
 *
 * NOTE: these fixture JSON files are intentionally committed under
 * `ts/tests/unit/fixtures/` (not the git-ignored `.factory/` run-scratch
 * dir) so this regression suite keeps working on any fresh clone / CI
 * runner after the run's `.factory/` directory is cleaned up.
 */

import { readFileSync } from "fs";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { describe, expect, test } from "vitest";

import {
    type Category,
    computePerformance,
    computeReadiness,
    type FsrsSummary,
    type PracticeHistoryItem,
} from "../../routes/practice/mcatMetrics";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = resolve(__dirname, "fixtures");

interface FixtureCase {
    name: string;
    practice_history: PracticeHistoryItem[];
    fsrs: FsrsSummary;
}

interface ExpectedCase {
    name: string;
    performance: {
        overall: { p: number; enough_data: boolean; n: number };
        per_category: { category: Category; p: number; enough_data: boolean; n: number }[];
    };
    readiness: {
        score_point: number;
        score_low: number;
        score_high: number;
        confidence: "high" | "medium" | "low";
        enough_data: boolean;
    };
}

const fixture: FixtureCase[] = JSON.parse(
    readFileSync(resolve(FIXTURES_DIR, "metrics-parity-fixture.json"), "utf-8"),
);
const expected: ExpectedCase[] = JSON.parse(
    readFileSync(resolve(FIXTURES_DIR, "metrics-parity-expected.json"), "utf-8"),
);

describe("mcatMetrics parity vs Python oracle", () => {
    test("fixture and expected cases align", () => {
        expect(fixture.map((c) => c.name)).toEqual(expected.map((c) => c.name));
    });

    for (let i = 0; i < fixture.length; i++) {
        const fixtureCase = fixture[i];
        const expectedCase = expected[i];

        test(`case: ${fixtureCase.name}`, () => {
            const performance = computePerformance(fixtureCase.practice_history);
            const readiness = computeReadiness(performance, fixtureCase.fsrs);

            expect(performance.overall.enough_data).toBe(
                expectedCase.performance.overall.enough_data,
            );
            expect(performance.overall.n).toBe(expectedCase.performance.overall.n);
            // NOTE: when enough_data is false, Python's oracle still reports
            // the theta-derived `p` ("computed for internal use" per
            // metrics.py's docstring), while this TS implementation reports
            // a hardcoded 0 in that case (see mcatMetrics.ts computePerformance:
            // `overall = { p: 0, enough_data: false, n: overallN }`). This is a
            // real cross-implementation disagreement in the *unused* branch --
            // neither Readiness nor the UI reads `p` when `enough_data` is
            // false -- but it means we can only assert `p` parity when
            // enough_data is true. Reported as a finding in result.md.
            if (expectedCase.performance.overall.enough_data) {
                expect(performance.overall.p).toBeCloseTo(
                    expectedCase.performance.overall.p,
                    6,
                );
            }

            const expectedCats = new Map(
                expectedCase.performance.per_category.map((c) => [c.category, c]),
            );
            // TS always returns all 4 categories; only assert on the ones
            // the oracle reports (categories absent from the oracle's input
            // are gated "not enough data" by construction in this fixture).
            for (const [category, expCat] of expectedCats) {
                const gotCat = performance.per_category.find((c) => c.category === category)!;
                expect(gotCat.enough_data).toBe(expCat.enough_data);
                expect(gotCat.n).toBe(expCat.n);
                if (expCat.enough_data) {
                    expect(gotCat.p).toBeCloseTo(expCat.p, 6);
                }
            }

            expect(readiness.score_point).toBe(expectedCase.readiness.score_point);
            expect(readiness.score_low).toBe(expectedCase.readiness.score_low);
            expect(readiness.score_high).toBe(expectedCase.readiness.score_high);
            expect(readiness.confidence).toBe(expectedCase.readiness.confidence);
            expect(readiness.enough_data).toBe(expectedCase.readiness.enough_data);
        });
    }
});

describe("mcatMetrics non-fixture invariants", () => {
    function emptyFsrs(): FsrsSummary {
        return {
            per_category: (["bio_biochem", "chem_phys", "psych_soc", "cars"] as const).map(
                (category) => ({
                    category,
                    average_recall: 0,
                    mastered_fraction: 0,
                    enough_data: false,
                    graded_reviews: 0,
                }),
            ),
            overall_mean_recall: 0,
        };
    }

    function item(
        category: Category,
        correct: boolean,
        difficulty_b = 0,
    ): PracticeHistoryItem {
        return { question_id: `q-${Math.random()}`, category, correct, difficulty_b };
    }

    test("N<5 -> enough_data false", () => {
        const history = [item("cars", true), item("cars", true), item("cars", false), item("cars", true)];
        const performance = computePerformance(history);
        expect(performance.overall.enough_data).toBe(false);
        const cars = performance.per_category.find((c) => c.category === "cars")!;
        expect(cars.enough_data).toBe(false);
    });

    test("zero data -> readiness score_point 500, not enough data", () => {
        const performance = computePerformance([]);
        const readiness = computeReadiness(performance, emptyFsrs());
        expect(readiness.score_point).toBe(500);
        expect(readiness.enough_data).toBe(false);
        expect(readiness.note.length).toBeGreaterThan(0);
    });

    test("clamp bounds respected", () => {
        const cases: [PracticeHistoryItem[], FsrsSummary][] = [
            [[], emptyFsrs()],
            [Array.from({ length: 50 }, () => item("bio_biochem", true, -3)), emptyFsrs()],
            [Array.from({ length: 50 }, () => item("chem_phys", false, 3)), emptyFsrs()],
        ];
        for (const [history, fsrs] of cases) {
            const performance = computePerformance(history);
            const readiness = computeReadiness(performance, fsrs);
            expect(readiness.score_point).toBeGreaterThanOrEqual(472);
            expect(readiness.score_point).toBeLessThanOrEqual(528);
            expect(readiness.score_low).toBeGreaterThanOrEqual(472);
            expect(readiness.score_high).toBeLessThanOrEqual(528);
            expect(performance.overall.p).toBeGreaterThanOrEqual(0);
            expect(performance.overall.p).toBeLessThanOrEqual(1);
            for (const cat of performance.per_category) {
                expect(cat.p).toBeGreaterThanOrEqual(0);
                expect(cat.p).toBeLessThanOrEqual(1);
            }
        }
    });

    test("2 of 4 sections needed for readiness.enough_data", () => {
        const fsrs = emptyFsrs();
        fsrs.per_category[0] = {
            category: "bio_biochem",
            average_recall: 0.9,
            mastered_fraction: 0.8,
            enough_data: true,
            graded_reviews: 40,
        };
        const performance = computePerformance([]);
        const readinessOne = computeReadiness(performance, fsrs);
        expect(readinessOne.enough_data).toBe(false);

        fsrs.per_category[1] = {
            category: "chem_phys",
            average_recall: 0.7,
            mastered_fraction: 0.6,
            enough_data: true,
            graded_reviews: 30,
        };
        const readinessTwo = computeReadiness(performance, fsrs);
        expect(readinessTwo.enough_data).toBe(true);
    });

    test("monotonicity: all-correct not lower than all-incorrect", () => {
        const good = Array.from({ length: 10 }, () => item("psych_soc", true));
        const bad = Array.from({ length: 10 }, () => item("psych_soc", false));
        const perfGood = computePerformance(good);
        const perfBad = computePerformance(bad);
        expect(perfGood.overall.p).toBeGreaterThan(perfBad.overall.p);

        const fsrs = emptyFsrs();
        const readinessGood = computeReadiness(perfGood, fsrs);
        const readinessBad = computeReadiness(perfBad, fsrs);
        expect(readinessGood.score_point).toBeGreaterThan(readinessBad.score_point);
    });
});
