# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Unit tests for mcat_tools.metrics, per contracts/data-model.md.

Run with (from `tools/syncserver/`, matching test_app.py's convention):
    python3 -m pytest mcat_tools/tests/test_metrics.py -v
or, from the repo root, with tools/syncserver/ on PYTHONPATH:
    PYTHONPATH=tools/syncserver python3 -m pytest tools/syncserver/mcat_tools/tests -v
"""

from __future__ import annotations

import math
import unittest

from mcat_tools import metrics


class EstimateThetaTests(unittest.TestCase):
    def test_empty_records_theta_zero(self):
        self.assertEqual(metrics.estimate_theta([]), 0.0)

    def test_five_correct_at_average_difficulty(self):
        # Hand-derived Newton-Raphson trace (theta_0 = 0):
        # records = [(1, 0.0)] * 5
        # Iter 1: p_i(0) = 1/(1+exp(0)) = 0.5 for all 5 records
        #   numerator   = 5*(1-0.5) - 0        = 2.5
        #   denominator = 5*(0.5*0.5) + 1      = 2.25
        #   delta = 2.5 / 2.25 = 1.111111111111...  -> theta_1 = 1.111111111111
        # Iter 2: p_i(theta_1) = 1/(1+exp(-1.111111111111)) ~= 0.752233...
        #   numerator   = 5*(1-0.752233) - 1.111111 = 1.238837 - 1.111111 = ...
        #   (full arithmetic reproduced by running this exact algorithm below)
        # Converges (|delta| < 1e-4) after 3 iterations to:
        expected_theta = 1.17750526415356
        records = [(1, 0.0)] * 5
        theta = metrics.estimate_theta(records)
        self.assertAlmostEqual(theta, expected_theta, places=9)

        expected_p = 1.0 / (1.0 + math.exp(-expected_theta))
        self.assertAlmostEqual(expected_p, 0.7644989471692879, places=9)

    def test_mixed_records(self):
        # records = [(1,0.0), (0,0.0), (1,-1.0), (0,1.0), (1,0.5)]
        # Derived by running the exact Newton-Raphson algorithm specified in
        # data-model.md (theta_0=0, N(0,1) prior, up to 25 iterations or
        # |delta theta| < 1e-4):
        #   theta_1 = 0.2924778052103771
        #   theta_2 = 0.29214833243021704 (delta ~ -3.29e-4)
        #   theta_3 = 0.29214833412777014 (delta ~ 1.7e-9 < 1e-4, converged)
        records = [(1, 0.0), (0, 0.0), (1, -1.0), (0, 1.0), (1, 0.5)]
        expected_theta = 0.29214833412777014
        theta = metrics.estimate_theta(records)
        self.assertAlmostEqual(theta, expected_theta, places=9)

    def test_theta_clamped_to_range(self):
        # All correct with very easy items should still clamp to [-4, 4].
        records = [(1, -10.0)] * 30
        theta = metrics.estimate_theta(records)
        self.assertLessEqual(theta, 4.0)
        self.assertGreaterEqual(theta, -4.0)


class PerformanceBucketTests(unittest.TestCase):
    def test_below_minimum_n_not_enough_data(self):
        records = [(1, 0.0), (0, 0.0), (1, 0.0), (0, 0.0)]  # N=4 < 5
        bucket = metrics.performance_bucket(records)
        self.assertEqual(bucket["n"], 4)
        self.assertFalse(bucket["enough_data"])
        # p is still computed even when not enough data.
        self.assertIsInstance(bucket["p"], float)

    def test_at_minimum_n_enough_data(self):
        records = [(1, 0.0)] * 5
        bucket = metrics.performance_bucket(records)
        self.assertEqual(bucket["n"], 5)
        self.assertTrue(bucket["enough_data"])
        self.assertAlmostEqual(bucket["p"], 0.7644989471692879, places=9)

    def test_empty_records(self):
        bucket = metrics.performance_bucket([])
        self.assertEqual(bucket["n"], 0)
        self.assertFalse(bucket["enough_data"])
        self.assertAlmostEqual(bucket["p"], 0.5)


class ComputePerformanceTests(unittest.TestCase):
    def test_only_categories_present_in_input(self):
        history = [
            {
                "question_id": "q1",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": 0.0,
            },
            {
                "question_id": "q2",
                "category": "cars",
                "correct": False,
                "difficulty_b": 0.0,
            },
        ]
        result = metrics.compute_performance(history)
        categories = {entry["category"] for entry in result["per_category"]}
        self.assertEqual(categories, {"bio_biochem", "cars"})
        self.assertNotIn("chem_phys", categories)
        self.assertNotIn("psych_soc", categories)
        self.assertEqual(result["overall"]["n"], 2)
        self.assertFalse(result["overall"]["enough_data"])

    def test_enough_data_overall_and_per_category(self):
        history = [
            {
                "question_id": f"q{i}",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": 0.0,
            }
            for i in range(5)
        ]
        result = metrics.compute_performance(history)
        self.assertTrue(result["overall"]["enough_data"])
        self.assertEqual(result["overall"]["n"], 5)
        self.assertAlmostEqual(result["overall"]["p"], 0.7644989471692879, places=9)
        bio_entry = next(
            e for e in result["per_category"] if e["category"] == "bio_biochem"
        )
        self.assertTrue(bio_entry["enough_data"])
        self.assertEqual(bio_entry["n"], 5)

    def test_repeated_question_id_counts_multiple_times(self):
        history = [
            {
                "question_id": "q1",
                "category": "cars",
                "correct": True,
                "difficulty_b": 0.0,
            }
        ] * 5
        result = metrics.compute_performance(history)
        self.assertEqual(result["overall"]["n"], 5)
        self.assertTrue(result["overall"]["enough_data"])


def _fsrs_entry(
    category,
    average_recall=0.0,
    mastered_fraction=0.0,
    enough_data=False,
    graded_reviews=0,
):
    return {
        "category": category,
        "average_recall": average_recall,
        "mastered_fraction": mastered_fraction,
        "enough_data": enough_data,
        "graded_reviews": graded_reviews,
    }


def _perf_entry(category, p=0.5, enough_data=False, n=0):
    return {"category": category, "p": p, "enough_data": enough_data, "n": n}


class ComputeReadinessTests(unittest.TestCase):
    def test_zero_fsrs_zero_practice_not_enough_data(self):
        performance = {
            "overall": {"p": 0.5, "enough_data": False, "n": 0},
            "per_category": [],
        }
        fsrs = {"per_category": [], "overall_mean_recall": 0.0}
        readiness = metrics.compute_readiness(performance, fsrs)
        self.assertFalse(readiness["enough_data"])
        # No data anywhere -> every section proficiency=0.5 -> score=125*4=500
        self.assertEqual(readiness["score_point"], 500)
        # No evidence anywhere -> max halfwidth (7) per section -> low/high
        self.assertEqual(readiness["score_low"], 500 - 7 * 4)
        self.assertEqual(readiness["score_high"], 500 + 7 * 4)
        self.assertEqual(readiness["confidence"], "low")
        self.assertNotEqual(readiness["note"], "")

    def test_two_of_four_sections_enough_data_true(self):
        performance = {
            "overall": {"p": 0.6, "enough_data": True, "n": 20},
            "per_category": [
                _perf_entry("bio_biochem", p=0.7, enough_data=True, n=20),
                _perf_entry("chem_phys", p=0.6, enough_data=True, n=20),
            ],
        }
        fsrs = {
            "per_category": [
                _fsrs_entry(
                    "bio_biochem",
                    average_recall=0.8,
                    mastered_fraction=0.5,
                    enough_data=True,
                    graded_reviews=100,
                ),
                _fsrs_entry(
                    "chem_phys",
                    average_recall=0.7,
                    mastered_fraction=0.4,
                    enough_data=True,
                    graded_reviews=80,
                ),
            ],
            "overall_mean_recall": 0.75,
        }
        readiness = metrics.compute_readiness(performance, fsrs)
        self.assertTrue(readiness["enough_data"])
        self.assertEqual(readiness["note"], "")
        self.assertGreaterEqual(readiness["score_point"], 472)
        self.assertLessEqual(readiness["score_point"], 528)

    def test_monotonic_better_recall_and_mastery_increases_score(self):
        def build(average_recall, mastered_fraction):
            performance = {
                "overall": {"p": 0.5, "enough_data": False, "n": 0},
                "per_category": [],
            }
            fsrs = {
                "per_category": [
                    _fsrs_entry(
                        "bio_biochem",
                        average_recall=average_recall,
                        mastered_fraction=mastered_fraction,
                        enough_data=True,
                        graded_reviews=50,
                    ),
                    _fsrs_entry(
                        "chem_phys",
                        average_recall=average_recall,
                        mastered_fraction=mastered_fraction,
                        enough_data=True,
                        graded_reviews=50,
                    ),
                ],
                "overall_mean_recall": average_recall,
            }
            return metrics.compute_readiness(performance, fsrs)

        low = build(0.3, 0.2)
        high = build(0.9, 0.8)
        self.assertLess(low["score_point"], high["score_point"])

    def test_proficiency_one_caps_section_at_132_and_total_at_528(self):
        per_category = []
        fsrs_per_category = []
        for category in metrics.CANONICAL_CATEGORIES:
            per_category.append(_perf_entry(category, p=1.0, enough_data=True, n=1000))
            fsrs_per_category.append(
                _fsrs_entry(
                    category,
                    average_recall=1.0,
                    mastered_fraction=1.0,
                    enough_data=True,
                    graded_reviews=1000,
                )
            )
        performance = {
            "overall": {"p": 1.0, "enough_data": True, "n": 4000},
            "per_category": per_category,
        }
        fsrs = {"per_category": fsrs_per_category, "overall_mean_recall": 1.0}
        readiness = metrics.compute_readiness(performance, fsrs)
        self.assertEqual(readiness["score_point"], 528)
        self.assertLessEqual(readiness["score_high"], 528)
        self.assertTrue(readiness["enough_data"])

    def test_confidence_high_with_lots_of_evidence(self):
        per_category = []
        fsrs_per_category = []
        for category in metrics.CANONICAL_CATEGORIES:
            per_category.append(_perf_entry(category, p=0.5, enough_data=True, n=200))
            fsrs_per_category.append(
                _fsrs_entry(
                    category,
                    average_recall=0.5,
                    mastered_fraction=0.5,
                    enough_data=True,
                    graded_reviews=500,
                )
            )
        performance = {
            "overall": {"p": 0.5, "enough_data": True, "n": 800},
            "per_category": per_category,
        }
        fsrs = {"per_category": fsrs_per_category, "overall_mean_recall": 0.5}
        readiness = metrics.compute_readiness(performance, fsrs)
        self.assertEqual(readiness["confidence"], "high")


if __name__ == "__main__":
    unittest.main()
