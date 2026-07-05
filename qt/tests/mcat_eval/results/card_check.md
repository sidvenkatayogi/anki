# MCAT Speedrun — AI CARD-CHECK (generated-card quality gate)

_Generated: 2026-07-05T20:12:18.124922+00:00_

**Source (one, open-licensed):** OpenStax Biology 2e, Chapter 3: Biological Macromolecules (CC BY 4.0)

**Gold set:** 50 known-correct Q&A pairs (`card_gold_set.json`). **Generated cards checked:** 50 (`generated_cards.json`).

> *** CARD-CHECK verdicts are a CAPTURED STAND-IN (no OPENAI_API_KEY) — the classifications come from pre-recorded checker verdicts in generated_cards.json, NOT a live model run. Set OPENAI_API_KEY and re-run for a live model check. ***

## Three counts

| Class | Count | Disposition |
| --- | ---: | --- |
| (1) correct & useful | 40 | allowed |
| (2) **wrong (wrong fact — worst)** | 5 | **blocked** |
| (3) correct-but-bad-teaching (vague/trivial/duplicate) | 5 | **blocked** |

**Blocked:** 10 / 50 · **allowed through:** 40 · **wrong allowed through:** 0 (must be 0).

**Checker vs seeded ground truth:** 50/50 (100.0%) _(stand-in classifications vs the seeded ground-truth labels)_

## Verdict

Pre-registered cutoff (fixed before results): **correct_useful ≥ 80%** and **wrong-allowed-through ≤ 0**; block policy: block any card not classified correct_useful.

- correct_useful = 80.0%, wrong-through = 0 → **PASS**

## Per-card verdicts

| Card | Area | Classification | Blocked | Reason |
| --- | --- | --- | :---: | --- |
| c-01 | macromolecule_synthesis | correct_useful |  | Matches gold: dehydration synthesis releases water; back names the mechanism. |
| c-02 | macromolecule_synthesis | correct_useful |  | Matches gold (hydrolysis) and explains the etymology/mechanism. |
| c-03 | macromolecule_synthesis | correct_useful |  | Correct per gold; adds concrete examples. |
| c-04 | macromolecule_synthesis | correct_bad_teaching | yes | Factually correct but trivial: a yes/no with no content; does not teach the four classes or anything testable. |
| c-05 | macromolecule_synthesis | correct_useful |  | Correct per gold; adds why (catalyst lowering activation energy). |
| c-06 | carbohydrates | correct_useful |  | Matches gold formula and states the C:H:O ratio. |
| c-07 | carbohydrates | wrong | yes | WRONG FACT: glucose is C6H12O6, not C5H10O5. Contradicts the gold answer. |
| c-08 | carbohydrates | correct_useful |  | Correct per gold. |
| c-09 | carbohydrates | correct_useful |  | Correct per gold; also names the bond. |
| c-10 | carbohydrates | correct_useful |  | Correct per gold; adds a memorable context (milk sugar). |
| c-11 | carbohydrates | correct_useful |  | Correct per gold. |
| c-12 | carbohydrates | correct_useful |  | Correct per gold; links to the reaction type. |
| c-13 | carbohydrates | correct_useful |  | Correct per gold; names the two components. |
| c-14 | carbohydrates | wrong | yes | WRONG FACT: glycogen is the ANIMAL storage polysaccharide (liver/muscle); plants store glucose as starch. Contradicts the gold. |
| c-15 | carbohydrates | correct_useful |  | Correct per gold; states its structural role. |
| c-16 | carbohydrates | correct_useful |  | Correct per gold; adds the nitrogen detail. |
| c-17 | carbohydrates | correct_useful |  | Correct per gold; defines isomer. |
| c-18 | lipids | correct_useful |  | Correct per gold; explains why (nonpolar). |
| c-19 | lipids | correct_useful |  | Correct per gold; uses the prefix as a mnemonic. |
| c-20 | lipids | correct_useful |  | Correct per gold; adds the reaction that forms it. |
| c-21 | lipids | correct_useful |  | Correct per gold; connects structure to packing. |
| c-22 | lipids | correct_useful |  | Correct per gold; notes the kink. |
| c-23 | lipids | correct_useful |  | Correct per gold; names the bilayer. |
| c-24 | lipids | correct_useful |  | Correct per gold; explains amphipathic consequence. |
| c-25 | lipids | correct_useful |  | Correct per gold. |
| c-26 | lipids | correct_useful |  | Correct per gold. |
| c-27 | lipids | correct_useful |  | Correct per gold; ties to packing and gives examples. |
| c-28 | lipids | correct_useful |  | Correct per gold. |
| c-29 | lipids | correct_useful |  | Correct per gold. |
| c-30 | proteins | correct_bad_teaching | yes | Circular/non-answer: restates 'monomer' as 'building block' without naming amino acid. Technically not false but teaches nothing. |
| c-31 | proteins | wrong | yes | WRONG FACT: the standard answer is 20 amino acids, not 22. Contradicts the gold. |
| c-32 | proteins | wrong | yes | WRONG FACT: amino acids are joined by peptide bonds; glycosidic bonds join sugars. Contradicts the gold. |
| c-33 | proteins | correct_bad_teaching | yes | Vague/hand-wavy: not false but gives no usable content -- fails to say the R group varies and determines chemical properties. |
| c-34 | proteins | correct_useful |  | Correct per gold; adds what holds it and where the sequence comes from. |
| c-35 | proteins | correct_useful |  | Correct per gold. |
| c-36 | proteins | correct_useful |  | Correct per gold; specifies which backbone atoms. |
| c-37 | proteins | correct_useful |  | Correct per gold; names the driving interactions. |
| c-38 | proteins | correct_useful |  | Correct per gold. |
| c-39 | proteins | correct_bad_teaching | yes | Vague: 'changes' is too loose to be useful; omits loss of 3D shape/function from heat or pH. Not wrong, but poor teaching. |
| c-40 | proteins | correct_useful |  | Correct per gold; states their function. |
| c-41 | proteins | correct_useful |  | Correct per gold. |
| c-42 | nucleic_acids | correct_useful |  | Correct per gold. |
| c-43 | nucleic_acids | correct_useful |  | Correct per gold. |
| c-44 | nucleic_acids | correct_useful |  | Correct per gold; all three components named. |
| c-45 | nucleic_acids | wrong | yes | WRONG FACT: DNA contains deoxyribose; ribose is the RNA sugar. Contradicts the gold. |
| c-46 | nucleic_acids | correct_useful |  | Correct per gold. |
| c-47 | nucleic_acids | correct_useful |  | Correct per gold. |
| c-48 | nucleic_acids | correct_useful |  | Correct per gold; adds the double-ring cue. |
| c-49 | nucleic_acids | correct_useful |  | Correct per gold; both pairings given. |
| c-50 | macromolecule_synthesis | correct_bad_teaching | yes | DUPLICATE: same fact (hydrolysis, gold g-02) as card c-02, which already teaches it more fully. A near-identical redundant card adds no value and should be blocked. |

> *** CARD-CHECK verdicts are a CAPTURED STAND-IN (no OPENAI_API_KEY) — the classifications come from pre-recorded checker verdicts in generated_cards.json, NOT a live model run. Set OPENAI_API_KEY and re-run for a live model check. ***
