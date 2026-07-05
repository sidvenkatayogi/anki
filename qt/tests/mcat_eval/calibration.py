"""Memory-model calibration — reliability diagram + Brier / log loss.

*** SYNTHETIC / ILLUSTRATIVE DATA ***
Rubric Step 1 (section 9) asks us to show the Memory model is *calibrated*: when
it says 80%, the student should recall about 80% of the time — proven on
held-out reviews with a calibration chart and a proper score (Brier or log loss).

We do not have a held-out slice of real review telemetry yet, so — per the
assignment's explicit synthetic-data allowance — this generates a held-out set of
(predicted_recall, actual_outcome) pairs from a fixed-seed model that is
*deliberately slightly over-confident*, then computes the real calibration
machinery on it: 10-bin reliability table, Brier score, log loss, and Expected
Calibration Error, plus an SVG reliability diagram. The scoring code is real and
stdlib-only; only the input pairs are synthetic. Every banner says so.

The predicted probabilities stand in for the FSRS current-retrievability our
Rust `tag_mastery` RPC already computes per card (rslib/src/stats/tag_mastery.rs).

Run:
    PYTHONPATH=qt:out/pylib ./out/pyenv/bin/python qt/tests/mcat_eval/calibration.py
or:
    just eval-calibration
"""

from __future__ import annotations

import datetime
import json
import math
import os
import random

_HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(_HERE, "results")

SYNTHETIC_BANNER = (
    "*** SYNTHETIC / ILLUSTRATIVE — (predicted, outcome) pairs are generated, "
    "NOT measured. The Brier/log-loss/ECE math is real; the inputs are not. ***"
)

N_REVIEWS = 2000
N_BINS = 10
SEED = 20260705
# The generator makes the model a touch over-confident (a realistic FSRS failure
# mode): true recall = predicted shrunk toward the mean. Amount of shrink:
_OVERCONFIDENCE = 0.06


def _clip(p: float, lo: float = 1e-6, hi: float = 1 - 1e-6) -> float:
    return max(lo, min(hi, p))


def simulate_pairs() -> list[tuple[float, int]]:
    rng = random.Random(SEED)
    pairs: list[tuple[float, int]] = []
    for _ in range(N_REVIEWS):
        # Predicted recall spread across the range, skewed high like real decks.
        pred = _clip(rng.betavariate(5, 2))
        # True prob is the prediction pulled toward 0.5 (over-confidence).
        true_p = _clip(pred + (0.5 - pred) * _OVERCONFIDENCE)
        outcome = 1 if rng.random() < true_p else 0
        pairs.append((pred, outcome))
    return pairs


def brier(pairs: list[tuple[float, int]]) -> float:
    return sum((p - y) ** 2 for p, y in pairs) / len(pairs)


def log_loss(pairs: list[tuple[float, int]]) -> float:
    total = 0.0
    for p, y in pairs:
        p = _clip(p)
        total += -(y * math.log(p) + (1 - y) * math.log(1 - p))
    return total / len(pairs)


def reliability_bins(pairs: list[tuple[float, int]], n_bins: int = N_BINS) -> list[dict]:
    bins: list[dict] = []
    for i in range(n_bins):
        lo, hi = i / n_bins, (i + 1) / n_bins
        sel = [(p, y) for p, y in pairs if (lo <= p < hi or (i == n_bins - 1 and p == hi))]
        if sel:
            mean_pred = sum(p for p, _ in sel) / len(sel)
            frac_pos = sum(y for _, y in sel) / len(sel)
        else:
            mean_pred = frac_pos = 0.0
        bins.append(
            {
                "lo": lo,
                "hi": hi,
                "n": len(sel),
                "mean_predicted": mean_pred,
                "observed_frequency": frac_pos,
                "gap": mean_pred - frac_pos,
            }
        )
    return bins


def expected_calibration_error(bins: list[dict], total: int) -> float:
    return sum(b["n"] / total * abs(b["gap"]) for b in bins if b["n"])


def render_svg(bins: list[dict]) -> str:
    """A dependency-free reliability diagram (perfect calibration = the diagonal)."""
    W = H = 320
    pad = 40
    plot = W - 2 * pad

    def x(v: float) -> float:
        return pad + v * plot

    def y(v: float) -> float:
        return H - pad - v * plot

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}" font-family="monospace" font-size="10">',
        f'<rect width="{W}" height="{H}" fill="#0A0E13"/>',
        # axes
        f'<line x1="{pad}" y1="{H-pad}" x2="{W-pad}" y2="{H-pad}" stroke="#5F6C7B"/>',
        f'<line x1="{pad}" y1="{pad}" x2="{pad}" y2="{H-pad}" stroke="#5F6C7B"/>',
        # perfect-calibration diagonal
        f'<line x1="{x(0)}" y1="{y(0)}" x2="{x(1)}" y2="{y(1)}" '
        f'stroke="#5F6C7B" stroke-dasharray="4 3"/>',
    ]
    # the model's reliability curve (amber)
    pts = [(b["mean_predicted"], b["observed_frequency"]) for b in bins if b["n"]]
    if pts:
        path = " ".join(f"{x(px):.1f},{y(py):.1f}" for px, py in pts)
        parts.append(
            f'<polyline points="{path}" fill="none" stroke="#FFB020" stroke-width="2"/>'
        )
        for px, py in pts:
            parts.append(f'<circle cx="{x(px):.1f}" cy="{y(py):.1f}" r="3" fill="#FFB020"/>')
    parts.append(
        f'<text x="{W/2:.0f}" y="{H-12}" fill="#94A2B2" text-anchor="middle">'
        "predicted recall</text>"
    )
    parts.append(
        f'<text x="14" y="{H/2:.0f}" fill="#94A2B2" text-anchor="middle" '
        f'transform="rotate(-90 14 {H/2:.0f})">observed recall</text>'
    )
    parts.append(
        f'<text x="{pad+4}" y="{pad-8}" fill="#DFE6EE">Memory calibration (synthetic)</text>'
    )
    parts.append("</svg>")
    return "\n".join(parts)


def compute() -> dict:
    pairs = simulate_pairs()
    bins = reliability_bins(pairs)
    b = brier(pairs)
    ll = log_loss(pairs)
    ece = expected_calibration_error(bins, len(pairs))
    base_rate = sum(y for _, y in pairs) / len(pairs)
    # Baseline: predicting the base rate for everyone (a "reference" Brier).
    baseline_brier = base_rate * (1 - base_rate)
    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "synthetic": True,
        "n_reviews": len(pairs),
        "base_rate": base_rate,
        "brier": b,
        "brier_baseline_predict_base_rate": baseline_brier,
        "brier_skill_score": 1 - b / baseline_brier if baseline_brier else 0.0,
        "log_loss": ll,
        "expected_calibration_error": ece,
        "bins": bins,
    }


def render_report(r: dict) -> str:
    out: list[str] = []
    out.append("=" * 64)
    out.append(" Ankinetic — Memory-model calibration (held-out reviews)")
    out.append("=" * 64)
    out.append(SYNTHETIC_BANNER)
    out.append("")
    out.append(f"Held-out reviews : {r['n_reviews']}")
    out.append(f"Base recall rate : {r['base_rate']:.3f}")
    out.append(f"Brier score      : {r['brier']:.4f}   (lower = better; 0 = perfect)")
    out.append(
        f"  vs base-rate    : {r['brier_baseline_predict_base_rate']:.4f}   "
        f"(skill score {r['brier_skill_score']:+.3f}, >0 beats the base rate)"
    )
    out.append(f"Log loss         : {r['log_loss']:.4f}")
    out.append(f"Expected Cal Err : {r['expected_calibration_error']:.4f}   (mean |pred-obs|)")
    out.append("")
    out.append(f"{'bin':>10}{'n':>7}{'pred':>8}{'obs':>8}{'gap':>8}")
    out.append("-" * 41)
    for bn in r["bins"]:
        if not bn["n"]:
            continue
        out.append(
            f"{f'{bn['lo']:.1f}-{bn['hi']:.1f}':>10}{bn['n']:>7}"
            f"{bn['mean_predicted']:>8.3f}{bn['observed_frequency']:>8.3f}{bn['gap']:>+8.3f}"
        )
    out.append("")
    out.append("Reading it: 'gap' = predicted − observed. Small positive gaps across")
    out.append("the high bins = mild over-confidence (the failure mode we seeded).")
    out.append("Chart written to results/calibration.svg")
    out.append("")
    out.append(SYNTHETIC_BANNER)
    return "\n".join(out)


def render_markdown(r: dict) -> str:
    lines: list[str] = []
    lines.append("# Memory-model calibration (held-out reviews)")
    lines.append("")
    lines.append(f"_Generated: {r['timestamp']}_")
    lines.append("")
    lines.append(f"> {SYNTHETIC_BANNER}")
    lines.append("")
    lines.append(
        f"**Held-out reviews:** {r['n_reviews']} · **base rate:** {r['base_rate']:.3f}"
    )
    lines.append("")
    lines.append("| Proper score | Value | Note |")
    lines.append("| --- | ---: | --- |")
    lines.append(f"| Brier | {r['brier']:.4f} | lower better; 0 = perfect |")
    lines.append(
        f"| Brier (predict base rate) | {r['brier_baseline_predict_base_rate']:.4f} | "
        f"skill score {r['brier_skill_score']:+.3f} vs this baseline |"
    )
    lines.append(f"| Log loss | {r['log_loss']:.4f} | |")
    lines.append(f"| Expected Calibration Error | {r['expected_calibration_error']:.4f} | mean \\|pred−obs\\| |")
    lines.append("")
    lines.append("![reliability diagram](./calibration.svg)")
    lines.append("")
    lines.append("### Reliability table")
    lines.append("")
    lines.append("| Bin | n | Mean predicted | Observed | Gap |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for bn in r["bins"]:
        if not bn["n"]:
            continue
        lines.append(
            f"| {bn['lo']:.1f}–{bn['hi']:.1f} | {bn['n']} | {bn['mean_predicted']:.3f} "
            f"| {bn['observed_frequency']:.3f} | {bn['gap']:+.3f} |"
        )
    lines.append("")
    lines.append(
        "The curve tracks the diagonal with small positive gaps in the top bins — "
        "the mild over-confidence we deliberately seeded, which is what a real FSRS "
        "calibration check is meant to surface (and would then correct)."
    )
    lines.append("")
    lines.append(f"> {SYNTHETIC_BANNER}")
    lines.append("")
    return "\n".join(lines)


def run() -> dict:
    r = compute()
    print(render_report(r))
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(os.path.join(RESULTS_DIR, "calibration.json"), "w") as fh:
        json.dump(r, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(RESULTS_DIR, "calibration.md"), "w") as fh:
        fh.write(render_markdown(r))
    with open(os.path.join(RESULTS_DIR, "calibration.svg"), "w") as fh:
        fh.write(render_svg(r["bins"]))
    return r


if __name__ == "__main__":
    run()
