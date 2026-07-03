// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

// Acceptance-criteria coverage: AC7 (seeded questions across all 4 categories), AC8 (question
// shape: stem/4 options/answer/explanation/category), AC9 (bundled data source, not inlined in
// view code — verified here by asserting the desktop, iOS, and contract copies of the JSON bank
// are all identical).
//
// The bank was replaced with open-licensed questions (OpenStax, CC BY-NC-SA 4.0) for the three
// science categories plus user-provided CARS passages; see data/ATTRIBUTION.md. Counts below
// track that bank (31 total: 7/7/7 science + 10 CARS) rather than the original 5-per-category.
//
// This test intentionally reads the JSON files straight off disk (Node fs), rather than importing
// through any view/component code, precisely to prove the seed bank is a standalone data artifact.

import { readFileSync } from "fs";
import { resolve } from "path";
import { describe, expect, it } from "vitest";

const REPO_ROOT = resolve(__dirname, "../../..");

const DESKTOP_SEED_PATH = resolve(REPO_ROOT, "qt/aqt/data/web/practice-seed.json");
const IOS_SEED_PATH = resolve(REPO_ROOT, "ios/AnkiMCAT/Resources/practice-seed.json");
const CONTRACT_SEED_PATH = resolve(
    REPO_ROOT,
    ".factory/runs/2026-07-02-read-practice-tabs/contracts/practice-seed.json",
);

const CANONICAL_CATEGORIES = ["bio_biochem", "chem_phys", "psych_soc", "cars"] as const;
const EXPECTED_KEYS = [
    "id",
    "category",
    "stem",
    "options",
    "answer_index",
    "explanation",
    "difficulty_b",
].sort();

interface SeedQuestion {
    id: string;
    category: string;
    stem: string;
    options: string[];
    answer_index: number;
    explanation: string;
    difficulty_b: number;
}

function loadRaw(path: string): string {
    return readFileSync(path, "utf-8");
}

function loadJson(path: string): unknown {
    return JSON.parse(loadRaw(path));
}

describe("practice-seed.json bundle (AC9: bundled data source)", () => {
    it("desktop, iOS, and contract copies are byte-identical (after trailing-whitespace normalization)", () => {
        const desktopRaw = loadRaw(DESKTOP_SEED_PATH).replace(/\s+$/, "");
        const iosRaw = loadRaw(IOS_SEED_PATH).replace(/\s+$/, "");
        const contractRaw = loadRaw(CONTRACT_SEED_PATH).replace(/\s+$/, "");

        expect(iosRaw).toBe(desktopRaw);
        expect(contractRaw).toBe(desktopRaw);
    });

    it("desktop, iOS, and contract copies are deep-equal as parsed JSON", () => {
        const desktop = loadJson(DESKTOP_SEED_PATH);
        const ios = loadJson(IOS_SEED_PATH);
        const contract = loadJson(CONTRACT_SEED_PATH);

        expect(ios).toEqual(desktop);
        expect(contract).toEqual(desktop);
    });
});

describe("practice-seed.json content/shape (AC7, AC8)", () => {
    const seed = loadJson(DESKTOP_SEED_PATH) as SeedQuestion[];

    it("is a valid JSON array of exactly 31 entries", () => {
        expect(Array.isArray(seed)).toBe(true);
        expect(seed.length).toBe(31);
    });

    it("has the expected per-category counts, and no other category values", () => {
        const EXPECTED_COUNTS: Record<(typeof CANONICAL_CATEGORIES)[number], number> = {
            bio_biochem: 7,
            chem_phys: 7,
            psych_soc: 7,
            cars: 10,
        };

        const counts: Record<string, number> = {};
        for (const q of seed) {
            counts[q.category] = (counts[q.category] ?? 0) + 1;
        }

        const seenCategories = Object.keys(counts).sort();
        expect(seenCategories).toEqual([...CANONICAL_CATEGORIES].sort());

        for (const category of CANONICAL_CATEGORIES) {
            expect(counts[category]).toBe(EXPECTED_COUNTS[category]);
        }
    });

    it("has unique, non-empty ids", () => {
        const ids = seed.map((q) => q.id);
        for (const id of ids) {
            expect(typeof id).toBe("string");
            expect(id.length).toBeGreaterThan(0);
        }
        expect(new Set(ids).size).toBe(ids.length);
    });

    it("every entry matches the documented schema exactly (no extra/missing keys)", () => {
        for (const q of seed) {
            expect(Object.keys(q).sort()).toEqual(EXPECTED_KEYS);
        }
    });

    it("every entry has a non-empty stem", () => {
        for (const q of seed) {
            expect(typeof q.stem).toBe("string");
            expect(q.stem.trim().length).toBeGreaterThan(0);
        }
    });

    it("every entry has exactly 4 non-empty options", () => {
        for (const q of seed) {
            expect(Array.isArray(q.options)).toBe(true);
            expect(q.options.length).toBe(4);
            for (const opt of q.options) {
                expect(typeof opt).toBe("string");
                expect(opt.trim().length).toBeGreaterThan(0);
            }
        }
    });

    it("every entry has an answer_index in [0,3]", () => {
        for (const q of seed) {
            expect(Number.isInteger(q.answer_index)).toBe(true);
            expect(q.answer_index).toBeGreaterThanOrEqual(0);
            expect(q.answer_index).toBeLessThanOrEqual(3);
        }
    });

    it("every entry has a non-empty explanation", () => {
        for (const q of seed) {
            expect(typeof q.explanation).toBe("string");
            expect(q.explanation.trim().length).toBeGreaterThan(0);
        }
    });

    it("every entry has a numeric difficulty_b within a reasonable range [-2,2]", () => {
        for (const q of seed) {
            expect(typeof q.difficulty_b).toBe("number");
            expect(Number.isFinite(q.difficulty_b)).toBe(true);
            expect(q.difficulty_b).toBeGreaterThanOrEqual(-2);
            expect(q.difficulty_b).toBeLessThanOrEqual(2);
        }
    });
});
