# Study-feature ablation — AR memory palace (method of loci)

_Generated: 2026-07-05T19:55:01.344269+00:00_

> *** SYNTHETIC / ILLUSTRATIVE — outcomes are generated from a fixed-seed model, NOT measured on real learners. Shows what results might look like. ***

**Hypothesis.** Studying a topic's cards through the AR memory palace (method of loci) will produce higher delayed recall on NEW, reworded questions — at equal study time — than studying the same cards as plain flashcards.

**Pre-stated main number.** Mean accuracy on a 48-hour-delayed test of reworded questions, on the studied topics. The decisive comparison is Full (palace ON) minus Ablation (palace OFF); plain Anki is the sanity floor.

**Fair test.** 30 learners, the *same* people, questions and time budget (25 min) across all three builds; delayed test at 48h. Success rule fixed in advance: Full − Ablation ≥ 5 pts with a 95% CI excluding 0.

| Build | Accuracy | 95% CI | Cards / 25 min |
| --- | ---: | :---: | ---: |
| Full app — palace ON (method of loci) | 75.0% | 68.0%–82.0% | 38 |
| Ablation — palace OFF (same app, plain flashcards) | 65.2% | 57.5%–72.8% | 45 |
| Plain unmodified Anki (baseline) | 63.7% | 56.4%–70.9% | 46 |

### Contrasts (paired)

| Contrast | What it isolates | Δ | 95% CI |
| --- | --- | ---: | :---: |
| `full_minus_ablation` | the palace feature's own contribution (the ablation) | 9.8% | 4.8%–14.8% |
| `ablation_minus_plain` | what the rest of our app adds over stock Anki | 1.5% | -3.4%–6.4% |
| `full_minus_plain` | whole app vs the obvious alternative | 11.3% | 5.9%–16.8% |
| `full_minus_ablation_fact_cards_only` | same feature, pure fact-recall cards — expected NULL | 2.7% | -5.4%–10.7% |

**Verdict (synthetic run):** feature **SUPPORTED** — rule: Full - Ablation >= +0.05 AND its 95% CI excludes 0.

### Honest results, including what did not work

- **Null on fact cards.** Restricted to pure fact-recall items the palace adds only 2.7% (CI -5.4%–10.7%). Method of loci helps relational/ordered material, not raw definitions — and the design is built to catch exactly that.
- **Throughput cost.** Building loci takes time, so the palace build covers fewer cards in the same 25 minutes; accuracy-per-card is up but cards-per-hour is down.
- **App ≠ palace.** Ablation vs plain Anki is small and its CI includes 0, so we cannot claim the surrounding app beats stock Anki here. Isolating the feature (Full vs Ablation) is what shows the palace, specifically, did the work.

> *** SYNTHETIC / ILLUSTRATIVE — outcomes are generated from a fixed-seed model, NOT measured on real learners. Shows what results might look like. ***
