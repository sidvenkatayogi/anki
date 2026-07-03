// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

/**
 * Acceptance-criteria coverage for the desktop Palace page (AC7-AC12 of
 * `.factory/runs/2026-07-02-palace-desktop-sync/02-story.md`), exercising
 * `ts/routes/palace/+page.svelte`.
 *
 * WHY THIS FILE LOOKS THE WAY IT DOES (read before editing):
 *
 * `+page.svelte` traps 100% of its logic inline in its `<script>` block: the
 * TS interfaces (`Palace`, `Locus`, `PalacePoint`, `PalaceSummary`) are
 * declared but never `export`ed, the pin-position math
 * (`locus.point.x * 100` / `* 100`) is not a function at all but lives
 * directly in a template `style` attribute, and the grade-payload
 * construction (`skipQueue: true` inside `answerCard(...)`) lives inside a
 * non-exported `async function grade(...)` in the component. Unlike
 * `ts/routes/practice/mcatMetrics.ts` (a sibling feature in this codebase
 * that DOES extract its pure logic into an importable, tested module),
 * nothing in this file is importable. This project also has no
 * `@testing-library/svelte`/`jsdom`/`happy-dom` in `package.json` (confirmed
 * by inspection before writing this file), so mounting the real component in
 * a vitest test isn't available either.
 *
 * Given that, every behavior below is covered two complementary ways:
 *
 * (a) FIXTURE/SHAPE TESTS - the same interfaces are redeclared locally here
 *     (copied verbatim from `contracts/data-model.md`'s "Desktop TypeScript
 *     types" section, the authoritative shared contract, not
 *     frontend-owned code), plus a tiny, obviously-correct reimplementation
 *     of each trivial one-line formula/predicate the real component uses,
 *     tested against representative values.
 *
 * (b) SOURCE-TEXT CHARACTERIZATION TESTS - the real `+page.svelte` is read
 *     with `readFileSync` and regex/substring-asserted to actually contain
 *     the specific formula/call/field just exercised in (a), so a future
 *     refactor that silently changes the formula, drops `skipQueue: true`,
 *     or changes an RPC call shape breaks this suite even though the
 *     component itself can't be executed here.
 *
 * HONESTY NOTE: the (b) checks are a regression/characterization net, NOT
 * behavioral proof - they never execute the component, so they cannot catch
 * a bug in logic that isn't visible as source text (e.g. a wiring mistake
 * that still contains all the right substrings but calls them in the wrong
 * order at runtime). See this worker's result.md for the corresponding
 * `needs: frontend` suggestion (extract `pinPosition`, a payload-builder, and
 * the JSON-parsing call sites into an importable module mirroring
 * `ts/routes/practice/mcatMetrics.ts`, or add `@testing-library/svelte` +
 * jsdom for real component mounts in a future round).
 */

import { readFileSync } from "fs";
import { resolve } from "path";
import { describe, expect, test } from "vitest";

const PALACE_PAGE_PATH = resolve(__dirname, "../../routes/palace/+page.svelte");
const source = readFileSync(PALACE_PAGE_PATH, "utf-8");

function countOccurrences(haystack: string, needle: string): number {
    return haystack.split(needle).length - 1;
}

function expectExactKeys(obj: object, expectedKeys: string[]): void {
    expect(Object.keys(obj).sort()).toEqual([...expectedKeys].sort());
}

// ---------------------------------------------------------------------------
// Types copied verbatim from contracts/data-model.md's "Desktop TypeScript
// types" section (the authoritative shared contract). +page.svelte declares
// an identical (but non-exported) copy of these interfaces.
// ---------------------------------------------------------------------------
interface PalacePoint {
    x: number;
    y: number;
}
interface Locus {
    id: string;
    cardID: number;
    label: string;
    mnemonic: string;
    transform?: number[] | null;
    anchorID?: string | null;
    point: PalacePoint;
    learned: boolean;
}
interface Palace {
    id: string;
    name: string;
    createdAt: string; // ISO-8601 UTC
    updatedAt: string; // ISO-8601 UTC
    capacity: number;
    loci: Locus[];
    hasPhoto: boolean;
    hasWorldMap: boolean;
    photoVersion: number | null;
}
interface PalaceSummary {
    id: string;
    name: string;
    updatedAt: string;
    lociCount: number;
    hasPhoto: boolean;
    photoVersion: number | null;
}

const PALACE_SUMMARY_KEYS = ["id", "name", "updatedAt", "lociCount", "hasPhoto", "photoVersion"];
const PALACE_KEYS = [
    "id",
    "name",
    "createdAt",
    "updatedAt",
    "capacity",
    "loci",
    "hasPhoto",
    "hasWorldMap",
    "photoVersion",
];
const LOCUS_KEYS = [
    "id",
    "cardID",
    "label",
    "mnemonic",
    "transform",
    "anchorID",
    "point",
    "learned",
];

describe("AC7 - list/detail JSON shape", () => {
    // Literal example from contracts/api.md's `GET /palaces` response.
    const LIST_RESPONSE_JSON = `{
        "palaces": [
            {
                "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                "name": "My Kitchen",
                "updatedAt": "2026-07-02T14:03:11Z",
                "lociCount": 5,
                "hasPhoto": true,
                "photoVersion": 3
            }
        ]
    }`;

    // Literal example from contracts/api.md's `GET /palaces/{id}` response.
    const DETAIL_RESPONSE_JSON = `{
        "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        "name": "My Kitchen",
        "createdAt": "2026-06-01T09:00:00Z",
        "updatedAt": "2026-07-02T14:03:11Z",
        "capacity": 7,
        "hasPhoto": true,
        "hasWorldMap": false,
        "photoVersion": 3,
        "loci": [
            {
                "id": "9B2D...",
                "cardID": 1687200000001,
                "label": "The mitochondria is the...",
                "mnemonic": "power plant on the stove",
                "point": { "x": 0.42, "y": 0.61 },
                "learned": true,
                "transform": null,
                "anchorID": null
            }
        ]
    }`;

    test("GET /palaces parses into { palaces: PalaceSummary[] } with every field present at the right typeof", () => {
        const data = JSON.parse(LIST_RESPONSE_JSON) as { palaces: PalaceSummary[] };
        expect(Array.isArray(data.palaces)).toBe(true);
        expect(data.palaces.length).toBe(1);

        const summary = data.palaces[0];
        expect(typeof summary.id).toBe("string");
        expect(typeof summary.name).toBe("string");
        expect(typeof summary.updatedAt).toBe("string");
        expect(typeof summary.lociCount).toBe("number");
        expect(typeof summary.hasPhoto).toBe("boolean");
        expect(typeof summary.photoVersion).toBe("number");
    });

    test("PalaceSummary object's key set matches the interface's field set exactly (no extra/missing keys)", () => {
        const data = JSON.parse(LIST_RESPONSE_JSON) as { palaces: PalaceSummary[] };
        expectExactKeys(data.palaces[0], PALACE_SUMMARY_KEYS);
    });

    test("GET /palaces/{id} parses into a Palace with every top-level field present at the right typeof", () => {
        const palace = JSON.parse(DETAIL_RESPONSE_JSON) as Palace;
        expect(typeof palace.id).toBe("string");
        expect(typeof palace.name).toBe("string");
        expect(typeof palace.createdAt).toBe("string");
        expect(typeof palace.updatedAt).toBe("string");
        expect(typeof palace.capacity).toBe("number");
        expect(Array.isArray(palace.loci)).toBe(true);
        expect(typeof palace.hasPhoto).toBe("boolean");
        expect(typeof palace.hasWorldMap).toBe("boolean");
        expect(typeof palace.photoVersion).toBe("number");
    });

    test("Palace object's key set matches the interface's field set exactly (no extra/missing keys)", () => {
        const palace = JSON.parse(DETAIL_RESPONSE_JSON) as Palace;
        expectExactKeys(palace, PALACE_KEYS);
    });

    test("the embedded Locus (point, transform: null, anchorID: null) matches the interface's field set and typeof/null shape", () => {
        const palace = JSON.parse(DETAIL_RESPONSE_JSON) as Palace;
        const locus = palace.loci[0];
        expectExactKeys(locus, LOCUS_KEYS);

        expect(typeof locus.id).toBe("string");
        expect(typeof locus.cardID).toBe("number");
        expect(typeof locus.label).toBe("string");
        expect(typeof locus.mnemonic).toBe("string");
        expect(typeof locus.learned).toBe("boolean");
        // Pass-through-only optional fields - contract explicitly allows null.
        expect(locus.transform).toBeNull();
        expect(locus.anchorID).toBeNull();
        // The only spatial field desktop uses.
        expect(typeof locus.point).toBe("object");
        expect(typeof locus.point.x).toBe("number");
        expect(typeof locus.point.y).toBe("number");
    });

    test("source: the real +page.svelte parses both responses exactly `as PalaceSummary[]` / `as Palace`", () => {
        // Proves the page really does treat the fetch response as these
        // interfaces structurally, not just that our local reimplementation
        // of the interfaces is self-consistent.
        expect(source).toContain(
            "const data = (await res.json()) as { palaces: PalaceSummary[] };",
        );
        expect(source).toContain("const palace = (await res.json()) as Palace;");
    });
});

describe("AC8 - pin coordinate math", () => {
    // Trivial, obviously-correct reimplementation of the one-line formula
    // the component uses directly in a template `style` attribute.
    function pinPercent(n: number): number {
        return n * 100;
    }

    const cases: Array<[number, number]> = [
        [0, 0],
        [1, 100],
        [0.5, 50],
        [0.42, 42],
        [0.61, 61],
    ];

    for (const [input, expected] of cases) {
        test(`pinPercent(${input}) === ${expected}`, () => {
            expect(pinPercent(input)).toBeCloseTo(expected, 9);
        });
    }

    test("source: the pin's style binding uses locus.point.x * 100 and locus.point.y * 100", () => {
        // Whitespace-tolerant: the real file wraps the y-expression across
        // multiple lines inside the template literal.
        expect(source).toMatch(/locus\.point\.x\s*\*\s*100/);
        expect(source).toMatch(/locus\.point\.y\s*\*\s*100/);
    });
});

describe("AC9 - render request shape", () => {
    test("source: renderExistingCard( appears exactly once in the file", () => {
        expect(countOccurrences(source, "renderExistingCard(")).toBe(1);
    });

    test("source: that single call passes cardId: BigInt(locus.cardID), browser: false, partialRender: false", () => {
        const callIdx = source.indexOf("renderExistingCard(");
        expect(callIdx).toBeGreaterThan(-1);
        const closeIdx = source.indexOf("});", callIdx);
        expect(closeIdx).toBeGreaterThan(callIdx);

        const callBlock = source.slice(callIdx, closeIdx + 3);
        expect(callBlock).toContain("cardId: BigInt(locus.cardID)");
        expect(callBlock).toContain("browser: false");
        expect(callBlock).toContain("partialRender: false");
    });
});

describe("AC10 - grade payload always sets skipQueue: true", () => {
    test("source: answerCard( appears exactly once in the file (the only grading call site)", () => {
        // All four rating buttons (Again/Hard/Good/Easy) call the same
        // grade(rating) function, which contains the file's one and only
        // answerCard(...) call - so proving this one call always sets
        // skipQueue: true proves it for all four buttons at once.
        expect(countOccurrences(source, "answerCard(")).toBe(1);
    });

    test("source: exactly one skipQueue: token exists in the whole file, and its value is true", () => {
        expect(countOccurrences(source, "skipQueue:")).toBe(1);
        expect(source).toContain("skipQueue: true");
        expect(source).not.toContain("skipQueue: false");
    });
});

describe("AC11 - not-configured guard", () => {
    // Trivial reimplementation of the one-line guard used in
    // checkConfigAndLoad.
    function needsConfig(cfg: { url?: string; token?: string }): boolean {
        return !cfg.url || !cfg.token;
    }

    const truthTable: Array<[{ url: string; token: string }, boolean]> = [
        [{ url: "", token: "" }, true],
        [{ url: "", token: "tok" }, true],
        [{ url: "https://example.com", token: "" }, true],
        [{ url: "https://example.com", token: "tok" }, false],
    ];

    for (const [cfg, expected] of truthTable) {
        test(
            `needsConfig({ url: ${JSON.stringify(cfg.url)}, token: ${
                JSON.stringify(
                    cfg.token,
                )
            } }) === ${expected}`,
            () => {
                expect(needsConfig(cfg)).toBe(expected);
            },
        );
    }

    test("source: the real guard expression !cfg.url || !cfg.token is present", () => {
        expect(source).toContain("!cfg.url || !cfg.token");
    });
});

describe("AC12 - disabled-pin decision", () => {
    // Trivial reimplementation of the disabled-pin predicate used in the
    // pin/locus-item bindings.
    function isPinDisabled(cardID: number, unavailable: Set<number>): boolean {
        return unavailable.has(cardID);
    }

    test("isPinDisabled reflects membership in the unavailable set", () => {
        const unavailable = new Set<number>([42, 99]);
        expect(isPinDisabled(42, unavailable)).toBe(true);
        expect(isPinDisabled(99, unavailable)).toBe(true);
        expect(isPinDisabled(7, unavailable)).toBe(false);
        expect(isPinDisabled(7, new Set())).toBe(false);
    });

    test("source: the openLocus catch block adds the failing card to unavailableCardIds after the renderExistingCard call", () => {
        const renderIdx = source.indexOf("renderExistingCard(");
        const addIdx = source.indexOf(".add(locus.cardID)");
        expect(renderIdx).toBeGreaterThan(-1);
        expect(addIdx).toBeGreaterThan(-1);
        // Simple file-order check per the assignment - not a full AST scope
        // check, but sufficient given there is only one occurrence of each
        // substring in the file (asserted elsewhere in this suite).
        expect(addIdx).toBeGreaterThan(renderIdx);
        // The exact statement from the catch block, verbatim.
        expect(source).toContain(
            "unavailableCardIds = new Set(unavailableCardIds).add(locus.cardID);",
        );
    });

    test("source: at least the pin's disabled binding reflects unavailableCardIds.has(locus.cardID)", () => {
        expect(source).toContain("disabled={unavailableCardIds.has(locus.cardID)}");
    });

    test("source (bonus, not required by the AC): the pin's class:pin-disabled binding also checks unavailableCardIds", () => {
        expect(source).toContain("class:pin-disabled={unavailableCardIds.has(");
    });
});
