# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Cross-implementation parity regression lock for Performance/Readiness math.

This test does NOT re-verify metrics.py's math from scratch (see
test_metrics.py for that) -- it loads the committed fixture + expected JSON
under `mcat_tools/tests/fixtures/` (the *oracle*, generated once by
`gen_expected.py` using this same `mcat_tools.metrics` module, and copied
here byte-identically from the run-scratch
`.factory/runs/2026-07-02-read-practice-tabs/domains/testing/fixtures/`
directory so production/CI code never depends on the git-ignored `.factory/`
tree) and asserts metrics.py still reproduces it exactly. TS
(`ts/tests/unit/mcatMetricsParity.test.ts`) and Swift
(`ios/AnkiMCAT/Tests/PracticeLogicTests/ParityFixtureTests.swift`) load their
own committed copies of the SAME fixture + expected files (owned by the
testing domain) and assert their own implementations match this oracle --
that is what proves 3-way cross-platform parity.

Run with (from `tools/syncserver/`, matching test_app.py's convention):
    python3 -m pytest mcat_tools/tests/test_metrics_parity.py -v
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from mcat_tools import metrics

# tools/syncserver/mcat_tools/tests/test_metrics_parity.py -> tests/fixtures/
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _load_json(name: str):
    path = FIXTURES_DIR / name
    with open(path) as f:
        return json.load(f)


class ParityOracleReproductionTests(unittest.TestCase):
    """Python's own metrics.py must reproduce the committed oracle exactly."""

    @classmethod
    def setUpClass(cls):
        cls.fixture = _load_json("metrics-parity-fixture.json")
        cls.expected = _load_json("metrics-parity-expected.json")
        cls.expected_by_name = {c["name"]: c for c in cls.expected}

    def test_fixture_and_expected_same_cases(self):
        fixture_names = [c["name"] for c in self.fixture]
        expected_names = [c["name"] for c in self.expected]
        self.assertEqual(fixture_names, expected_names)

    def test_every_case_reproduces_oracle(self):
        for case in self.fixture:
            name = case["name"]
            with self.subTest(case=name):
                performance = metrics.compute_performance(case["practice_history"])
                readiness = metrics.compute_readiness(performance, case["fsrs"])
                expected = self.expected_by_name[name]

                self.assertEqual(
                    performance["overall"]["enough_data"],
                    expected["performance"]["overall"]["enough_data"],
                )
                self.assertEqual(
                    performance["overall"]["n"], expected["performance"]["overall"]["n"]
                )
                self.assertAlmostEqual(
                    performance["overall"]["p"],
                    expected["performance"]["overall"]["p"],
                    places=6,
                )

                got_cats = {c["category"]: c for c in performance["per_category"]}
                exp_cats = {
                    c["category"]: c for c in expected["performance"]["per_category"]
                }
                self.assertEqual(set(got_cats.keys()), set(exp_cats.keys()))
                for cat, exp_entry in exp_cats.items():
                    got_entry = got_cats[cat]
                    self.assertEqual(got_entry["enough_data"], exp_entry["enough_data"])
                    self.assertEqual(got_entry["n"], exp_entry["n"])
                    self.assertAlmostEqual(got_entry["p"], exp_entry["p"], places=6)

                self.assertEqual(
                    readiness["score_point"], expected["readiness"]["score_point"]
                )
                self.assertEqual(
                    readiness["score_low"], expected["readiness"]["score_low"]
                )
                self.assertEqual(
                    readiness["score_high"], expected["readiness"]["score_high"]
                )
                self.assertEqual(
                    readiness["confidence"], expected["readiness"]["confidence"]
                )
                self.assertEqual(
                    readiness["enough_data"], expected["readiness"]["enough_data"]
                )


class NonFixtureInvariantTests(unittest.TestCase):
    """Pure math assertions independent of the oracle fixture."""

    def _empty_fsrs(self):
        return {
            "per_category": [
                {
                    "category": cat,
                    "average_recall": 0,
                    "mastered_fraction": 0,
                    "enough_data": False,
                    "graded_reviews": 0,
                }
                for cat in metrics.CANONICAL_CATEGORIES
            ],
            "overall_mean_recall": 0,
        }

    def test_n_lt_5_not_enough_data(self):
        history = [
            {
                "question_id": f"q{i}",
                "category": "cars",
                "correct": True,
                "difficulty_b": 0.0,
            }
            for i in range(4)
        ]
        performance = metrics.compute_performance(history)
        self.assertFalse(performance["overall"]["enough_data"])
        cars = next(c for c in performance["per_category"] if c["category"] == "cars")
        self.assertFalse(cars["enough_data"])

    def test_zero_data_readiness_not_enough_data_score_500(self):
        performance = metrics.compute_performance([])
        readiness = metrics.compute_readiness(performance, self._empty_fsrs())
        self.assertEqual(readiness["score_point"], 500)
        self.assertFalse(readiness["enough_data"])
        self.assertGreater(len(readiness["note"]), 0)

    def test_clamp_bounds_respected_across_many_random_like_inputs(self):
        # A spread of extreme/edge inputs -- score bounds and p bounds must
        # always hold regardless of input shape.
        cases = [
            ([], self._empty_fsrs()),
            (
                [
                    {
                        "question_id": f"q{i}",
                        "category": "bio_biochem",
                        "correct": True,
                        "difficulty_b": -3.0,
                    }
                    for i in range(50)
                ],
                self._empty_fsrs(),
            ),
            (
                [
                    {
                        "question_id": f"q{i}",
                        "category": "chem_phys",
                        "correct": False,
                        "difficulty_b": 3.0,
                    }
                    for i in range(50)
                ],
                self._empty_fsrs(),
            ),
        ]
        for history, fsrs in cases:
            performance = metrics.compute_performance(history)
            readiness = metrics.compute_readiness(performance, fsrs)
            self.assertGreaterEqual(readiness["score_point"], 472)
            self.assertLessEqual(readiness["score_point"], 528)
            self.assertGreaterEqual(readiness["score_low"], 472)
            self.assertLessEqual(readiness["score_high"], 528)
            self.assertGreaterEqual(performance["overall"]["p"], 0.0)
            self.assertLessEqual(performance["overall"]["p"], 1.0)
            for cat_entry in performance["per_category"]:
                self.assertGreaterEqual(cat_entry["p"], 0.0)
                self.assertLessEqual(cat_entry["p"], 1.0)

    def test_two_of_four_sections_needed_for_enough_data(self):
        fsrs = self._empty_fsrs()
        fsrs["per_category"][0]["enough_data"] = True
        fsrs["per_category"][0]["average_recall"] = 0.9
        fsrs["per_category"][0]["mastered_fraction"] = 0.8
        fsrs["per_category"][0]["graded_reviews"] = 40

        performance = metrics.compute_performance([])
        readiness = metrics.compute_readiness(performance, fsrs)
        self.assertFalse(readiness["enough_data"])  # only 1 of 4 sections

        fsrs["per_category"][1]["enough_data"] = True
        fsrs["per_category"][1]["average_recall"] = 0.7
        fsrs["per_category"][1]["mastered_fraction"] = 0.6
        fsrs["per_category"][1]["graded_reviews"] = 30
        readiness2 = metrics.compute_readiness(performance, fsrs)
        self.assertTrue(readiness2["enough_data"])  # now 2 of 4

    def test_monotonicity_all_correct_not_lower_than_all_incorrect(self):
        def history(correct: bool, n: int = 10):
            return [
                {
                    "question_id": f"q{i}",
                    "category": "psych_soc",
                    "correct": correct,
                    "difficulty_b": 0.0,
                }
                for i in range(n)
            ]

        fsrs = self._empty_fsrs()
        perf_good = metrics.compute_performance(history(True))
        perf_bad = metrics.compute_performance(history(False))

        p_good = perf_good["overall"]["p"]
        p_bad = perf_bad["overall"]["p"]
        self.assertGreater(p_good, p_bad)

        readiness_good = metrics.compute_readiness(perf_good, fsrs)
        readiness_bad = metrics.compute_readiness(perf_bad, fsrs)
        self.assertGreater(readiness_good["score_point"], readiness_bad["score_point"])


if __name__ == "__main__":
    unittest.main()
