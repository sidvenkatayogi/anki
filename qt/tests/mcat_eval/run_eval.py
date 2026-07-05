"""One-command entrypoint for the AI answer-grader evaluation.

Run it directly (flat imports resolve via the sys.path insert below):

    PYTHONPATH=qt:out/pylib ./out/pyenv/bin/python qt/tests/mcat_eval/run_eval.py

It runs the REAL keyword baseline, the LLM grader (real if OPENAI_API_KEY is
set, otherwise a clearly-labeled deterministic SIMULATION), and the REAL
leakage check; prints a side-by-side report; and writes machine- and
human-readable results to ``results/latest.{json,md}``.

Honesty rule enforced here: whenever the LLM row is simulated, stdout, the
Markdown, and the JSON all say so loudly (``"simulated": true``). Simulated
numbers are never presented as real measurements.
"""

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PKG = _HERE if os.path.basename(_HERE) == "mcat_eval" else os.path.join(_HERE, "mcat_eval")
sys.path.insert(0, _PKG)

import datetime  # noqa: E402
import json  # noqa: E402

import baseline  # noqa: E402
import dataset  # noqa: E402
import injection_eval  # noqa: E402
import leakage  # noqa: E402
import llm_driver  # noqa: E402
import metrics  # noqa: E402

# mcat_eval -> tests -> qt -> <repo root>
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
RESULTS_DIR = os.path.join(_HERE, "results")

SIMULATED_BANNER = (
    "*** LLM grader row is SIMULATED (no OPENAI_API_KEY) — "
    "illustrative, not a measurement. ***"
)

# Shown when the LLM row is the Claude agent stand-in (no OPENAI_API_KEY, but
# captured agent verdicts are available). It IS a real LLM grading measurement,
# but it is NOT the shipping model — so we never call it "REAL" gpt-5-nano.
STAND_IN_BANNER = (
    "*** LLM grader row is a Claude AGENT STAND-IN for the shipping gpt-5-nano "
    "(no OPENAI_API_KEY set). It is a real LLM grading measurement on a blind "
    "copy of the set, but NOT the shipping model. The authoritative shipping "
    "gpt-5-nano number is 99.2% accuracy / 0.0% false-accept — see "
    "BASELINE_COMPARISON.md. Set OPENAI_API_KEY and re-run for live numbers. ***"
)

# Metrics shown in the side-by-side table: (dict key, display label).
_TABLE_ROWS = [
    ("accuracy", "Accuracy"),
    ("false_accept_rate", "False-accept rate"),
    ("false_reject_rate", "False-reject rate"),
    ("macro_f1", "Macro-F1"),
]


def _rel(path: str) -> str:
    try:
        return os.path.relpath(path, REPO_ROOT)
    except ValueError:
        return path


def _verdict(passed: bool) -> str:
    return "PASS" if passed else "FAIL"


def compute() -> dict:
    """Run baseline, LLM (real/simulated) and leakage; return a results dict."""
    records = dataset.load_records()
    meta = dataset.load_meta()
    gold = [bool(rec["gold_correct"]) for rec in records]
    n_pos = sum(gold)
    n_neg = len(gold) - n_pos

    # --- Baseline (REAL, local) ---
    baseline_preds = [
        baseline.grade(rec["expected"], rec["student_answer"]) for rec in records
    ]
    baseline_metrics = metrics.score(gold, baseline_preds)

    # --- LLM grader: real OpenAI key > real agent verdicts > labeled SIMULATION ---
    api_key = os.environ.get("OPENAI_API_KEY")
    agent_verdicts_path = os.path.join(_HERE, "agent_verdicts.json")
    if isinstance(api_key, str) and api_key.strip():
        llm_result = llm_driver.grade_all(records, api_key)
        llm_label = "LLM grader (gpt-5-nano)"
    elif os.path.exists(agent_verdicts_path):
        llm_result = llm_driver.load_agent_verdicts(records, agent_verdicts_path)
        # A Claude agent standing in for the shipping gpt-5-nano — a real LLM
        # grading measurement, but NOT the shipping model. Do not label it "REAL"
        # (that reads as gpt-5-nano). The authoritative shipping-model number lives
        # in BASELINE_COMPARISON.md (gpt-5-nano: 99.2% accuracy, 0% false-accept).
        llm_label = "LLM grader (Claude stand-in)"
    else:
        llm_result = llm_driver.grade_all(records, None)
        llm_label = "LLM grader (SIMULATED)"
    llm_metrics = metrics.score(gold, llm_result["predictions"])
    simulated = llm_result["simulated"]

    # --- Leakage (REAL, local) ---
    leak = leakage.scan(records, leakage.grader_corpus())

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "dataset": {
            "total": len(records),
            "gold_correct": n_pos,
            "gold_incorrect": n_neg,
            "meta": meta,
        },
        "simulated": simulated,
        "llm_source": llm_result.get("source", "simulation" if simulated else "openai"),
        "llm_note": llm_result["note"],
        "cutoff": metrics.CUTOFF,
        "baseline": {
            "label": "Keyword baseline (REAL)",
            "simulated": False,
            "metrics": baseline_metrics,
            "passes_cutoff": metrics.passes_cutoff(baseline_metrics),
        },
        "llm": {
            "label": llm_label,
            "simulated": simulated,
            "stand_in": llm_result.get("source") == "agent",
            "metrics": llm_metrics,
            "passes_cutoff": metrics.passes_cutoff(llm_metrics),
        },
        "leakage": leak,
    }


def _table_lines(results: dict, sep: str = " | ") -> list[str]:
    baseline_label = results["baseline"]["label"]
    llm_label = results["llm"]["label"]
    baseline_m = results["baseline"]["metrics"]
    llm_m = results["llm"]["metrics"]

    metric_w = max(len("Metric"), *(len(label) for _, label in _TABLE_ROWS))
    col_w = max(len(baseline_label), len(llm_label), len("0.000"))

    def row(name: str, left: str, right: str) -> str:
        return f"{name:<{metric_w}}{sep}{left:>{col_w}}{sep}{right:>{col_w}}"

    lines = [row("Metric", baseline_label, llm_label)]
    lines.append(
        f"{'-' * metric_w}{sep}{'-' * col_w}{sep}{'-' * col_w}"
    )
    for key, label in _TABLE_ROWS:
        lines.append(row(label, f"{baseline_m[key]:.3f}", f"{llm_m[key]:.3f}"))
    return lines


def render_report(results: dict) -> str:
    """Human-readable plain-text report (also printed to stdout)."""
    ds = results["dataset"]
    leak = results["leakage"]
    simulated = results["simulated"]
    stand_in = results.get("llm_source") == "agent"
    clean = leak["exact_overlaps"] == 0 and leak["near_dup_overlaps"] == 0

    out: list[str] = []
    out.append("=" * 64)
    out.append(" Ankinetic — AI answer-grader evaluation")
    out.append("=" * 64)
    out.append(
        f"Dataset: {ds['total']} records  "
        f"(gold-correct: {ds['gold_correct']}, gold-incorrect: {ds['gold_incorrect']})"
    )
    out.append("Source: grader_eval_set.json (hand-curated, held-out)")
    out.append("")

    out.append("Leakage check (held-out items vs grader prompt/examples):")
    out.append(f"  exact substring overlaps : {leak['exact_overlaps']}")
    out.append(
        f"  near-duplicate overlaps  : {leak['near_dup_overlaps']}"
        f"   (max Jaccard {leak['max_jaccard']:.4f}, threshold {leakage.NEAR_DUP_THRESHOLD})"
    )
    if clean:
        out.append("  => CLEAN: no held-out item leaked into the grader.")
    else:
        out.append(f"  => LEAKAGE DETECTED. Flagged ids: {', '.join(leak['flagged'])}")
    out.append("")

    if simulated:
        out.append(SIMULATED_BANNER)
        out.append("")
    elif stand_in:
        out.append(STAND_IN_BANNER)
        out.append("")

    out.extend(_table_lines(results))
    out.append("")
    out.append(f"LLM grader: {results['llm_note']}")
    out.append("")

    if simulated:
        out.append(SIMULATED_BANNER)
        out.append("")

    cutoff = results["cutoff"]
    out.append(
        f"Pre-registered cutoff: accuracy >= {cutoff['accuracy']:.2f} "
        f"AND false-accept rate <= {cutoff['false_accept_rate']:.2f}"
    )
    for block in (results["baseline"], results["llm"]):
        m = block["metrics"]
        if block["simulated"]:
            tag = "  [SIMULATED — not a real measurement]"
        elif block.get("stand_in"):
            tag = "  [Claude stand-in, not the shipping gpt-5-nano]"
        else:
            tag = ""
        out.append(
            f"  {block['label']:<26} {_verdict(block['passes_cutoff'])} "
            f"(accuracy {m['accuracy']:.3f}, false-accept {m['false_accept_rate']:.3f})"
            f"{tag}"
        )
    out.append("")
    out.append(f"Wrote: {_rel(os.path.join(RESULTS_DIR, 'latest.json'))}")
    out.append(f"Wrote: {_rel(os.path.join(RESULTS_DIR, 'latest.md'))}")
    return "\n".join(out)


def render_markdown(results: dict) -> str:
    """Markdown mirror of the report (SIMULATED labeling preserved)."""
    ds = results["dataset"]
    leak = results["leakage"]
    simulated = results["simulated"]
    stand_in = results.get("llm_source") == "agent"
    clean = leak["exact_overlaps"] == 0 and leak["near_dup_overlaps"] == 0
    cutoff = results["cutoff"]
    baseline_m = results["baseline"]["metrics"]
    llm_m = results["llm"]["metrics"]

    lines: list[str] = []
    lines.append("# Ankinetic — AI answer-grader evaluation")
    lines.append("")
    lines.append(f"_Generated: {results['timestamp']}_")
    lines.append("")
    lines.append(
        f"**Dataset:** {ds['total']} records "
        f"(gold-correct: {ds['gold_correct']}, gold-incorrect: {ds['gold_incorrect']}) — "
        "`grader_eval_set.json`, hand-curated, held-out."
    )
    lines.append("")

    if simulated:
        lines.append(f"> {SIMULATED_BANNER}")
        lines.append(">")
        lines.append(f"> {results['llm_note']}")
        lines.append("")
    elif stand_in:
        lines.append(f"> {STAND_IN_BANNER}")
        lines.append(">")
        lines.append(f"> {results['llm_note']}")
        lines.append("")

    lines.append("## Leakage check")
    lines.append("")
    lines.append(f"- exact substring overlaps: **{leak['exact_overlaps']}**")
    lines.append(
        f"- near-duplicate overlaps: **{leak['near_dup_overlaps']}** "
        f"(max Jaccard {leak['max_jaccard']:.4f}, threshold {leakage.NEAR_DUP_THRESHOLD})"
    )
    if clean:
        lines.append("- **CLEAN** — no held-out item leaked into the grader.")
    else:
        lines.append(f"- **LEAKAGE DETECTED** — flagged ids: {', '.join(leak['flagged'])}")
    lines.append("")

    lines.append("## Results")
    lines.append("")
    lines.append(
        f"| Metric | {results['baseline']['label']} | {results['llm']['label']} |"
    )
    lines.append("| --- | ---: | ---: |")
    for key, label in _TABLE_ROWS:
        lines.append(f"| {label} | {baseline_m[key]:.3f} | {llm_m[key]:.3f} |")
    lines.append("")
    lines.append(f"_LLM grader: {results['llm_note']}_")
    lines.append("")
    if simulated:
        lines.append(f"> {SIMULATED_BANNER}")
        lines.append("")
    elif stand_in:
        lines.append(f"> {STAND_IN_BANNER}")
        lines.append("")

    lines.append("## Verdict")
    lines.append("")
    lines.append(
        f"Pre-registered cutoff: **accuracy ≥ {cutoff['accuracy']:.2f}** and "
        f"**false-accept rate ≤ {cutoff['false_accept_rate']:.2f}**."
    )
    lines.append("")
    for block in (results["baseline"], results["llm"]):
        m = block["metrics"]
        if block["simulated"]:
            tag = " _(SIMULATED — not a real measurement)_"
        elif block.get("stand_in"):
            tag = " _(Claude stand-in, not the shipping gpt-5-nano)_"
        else:
            tag = ""
        lines.append(
            f"- **{block['label']}: {_verdict(block['passes_cutoff'])}** "
            f"(accuracy {m['accuracy']:.3f}, false-accept {m['false_accept_rate']:.3f})"
            f"{tag}"
        )
    lines.append("")
    return "\n".join(lines)


def _write_results(results: dict) -> None:
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(os.path.join(RESULTS_DIR, "latest.json"), "w", encoding="utf-8") as fh:
        json.dump(results, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(RESULTS_DIR, "latest.md"), "w", encoding="utf-8") as fh:
        fh.write(render_markdown(results))


def run() -> dict:
    """Compute everything, print the report, write results; return results dict."""
    results = compute()
    print(render_report(results))
    _write_results(results)
    return results


def main() -> int:
    """Return 0 on a successful eval run; non-zero only if leakage is found.

    Leakage is a hard gate: a held-out item leaking into the grader prompt
    invalidates the whole evaluation, so that (and only that) fails the command.
    The prompt-injection eval is run and printed too (challenge: section 10),
    but it does not gate this command — it has its own entrypoint/exit code.
    """
    results = run()

    # Also run the prompt-injection resistance eval so `just eval-ai` surfaces
    # it in one place (writes results/injection.{md,json}).
    print()
    injection_eval.run()

    leak = results["leakage"]
    if leak["exact_overlaps"] > 0 or leak["near_dup_overlaps"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
