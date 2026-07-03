# MCAT Speedrun — a study app built on Anki

**Exam:** [MCAT](https://students-residents.aamc.org/about-mcat-exam/about-mcat-exam) — scored **472–528**, four sections each scored **118–132** (Chem/Phys, CARS, Bio/Biochem, Psych/Soc). A large fact base plus reading passages; the hard part is covering it all.

**MCAT Speedrun** is a fork of [Anki](https://apps.ankiweb.net) with a **desktop app** and an **iOS companion** that share one engine — Anki's Rust core. It adds a real change inside that Rust engine (a per-topic mastery query), an **honest memory-readiness dashboard**, and MCAT-tuned study flows, on top of the MileDown MCAT deck.

This is a fork of Anki and is distributed under **AGPL-3.0-or-later**, with credit to Anki and its contributors (see [Upstream Anki](#upstream-anki) and [LICENSE](./LICENSE)). Some parts of Anki are BSD-3-Clause.

Development happens on the `mcat-speedrun-fork` branch.

## Status

What runs today:

- ✅ Anki forked and **building from source**.
- ✅ A real **Rust engine change** — a per-topic mastery query — with **23 Rust unit tests + 3 Python tests** (see [The Rust engine change](#the-rust-engine-change)).
- ✅ **Desktop** review loop on the MCAT deck, with interleaved study ("Start Flashcards" / "Focus a Category").
- ✅ **Three separate scores, each with a range** (see [The three scores](#the-three-scores)): **Memory** (per-topic FSRS recall + confidence interval), **Performance** (chance of answering a new exam-style question, with a range), and **Readiness** (projected 472–528 scaled score with a likely range + confidence). Each has its own **give-up rule** and abstains rather than guessing.
- ✅ **Two-way desktop⇄iOS sync** — both apps embed the same Rust core and sync the whole collection (cards, FSRS memory state, review log, notes, decks, media) over Anki's native sync against a self-hosted sync server (see [`tools/syncserver`](./tools/syncserver)). Offline review syncs when the connection returns.
- ✅ An **optional AI answer-grader** (off by default) that judges typed (desktop) / voice-transcribed (iOS) free-text answers with an LLM and maps the verdict onto an FSRS rating. With AI switched off, review is 100% local and all three scores still compute.
- ✅ A **macOS desktop installer** (Briefcase DMG) that ships two profiles — a clean-slate default and a pre-seeded demo profile.
- ✅ An **iOS companion** that builds and runs on the simulator, loads the MCAT deck, runs a real review session **on the shared Rust engine** (via the C FFI), and shows the **same three scores** (Memory, Performance, Readiness) with ranges and give-up rules.

## Install (macOS)

There's no signed release download yet, so you install from a DMG you build locally:

```
just installer          # builds -> out/installer/dist/anki-26.05-mac-apple.dmg
open out/installer/dist/anki-26.05-mac-apple.dmg
```

Then drag **Anki.app** onto the **Applications** folder in the window that opens.

The DMG is unsigned/unnotarized (no Apple certs), so macOS Gatekeeper will block the
first launch. Clear it once with either:

- **Finder:** right-click **Anki.app** → **Open** → **Open**, or
- **Terminal:** `xattr -dr com.apple.quarantine "/Applications/Anki.app"`

After that it launches normally. `just installer` runs a full wheels rebuild first, so the
initial build takes a while.

## Architecture — two apps, one engine

Both apps drive the same Anki Rust core (`rslib`); neither reimplements the scheduler.

- **Core engine** — Rust in `rslib/` (FSRS scheduling, storage, our mastery query). Exposed to other layers over protobuf.
- **Desktop** — Python/Qt in `qt/aqt/` embedding Svelte/TypeScript web views (`ts/`), talking to the engine through the PyO3 bridge (`pylib/rsbridge`).
- **iOS companion** — SwiftUI in `ios/AnkiMCAT/`, calling the **same Rust core** through a thin C ABI (`rslib/ios/`, built as an `xcframework`) with swift-protobuf messages. No scheduler is rewritten in Swift.

## Build & run

Everything is wrapped in the project `justfile` (`just --list`). Do not call `./ninja`/`./run` directly.

**Desktop (development):**

```
just run                 # build pylib + qt and launch Anki
```

**Desktop installer (macOS):**

```
just installer           # -> out/installer/dist/anki-26.05-mac-apple.dmg
```

The DMG is unsigned/unnotarized (no certs), so on first launch clear Gatekeeper with
right-click → Open, or `xattr -dr com.apple.quarantine "/Applications/Anki.app"`.

**iOS companion (simulator):**

```
cd ios/AnkiMCAT && ./build-sim.sh run     # requires xcodegen + an iOS simulator runtime
```

**Tests for the engine change:**

```
cargo test -p anki tag_mastery                    # 23 Rust unit tests
PYTHONPATH=out/pylib ./out/pyenv/bin/python \
    -m pytest pylib/tests/test_tag_mastery.py     # 3 Python tests (calling the Rust RPC)
```

The MCAT deck (`MCAT_Milesdown.apkg`) and derived seed decks are large binaries kept out of
git; the installer's demo profile is regenerated with
`PYTHONPATH=out/pylib ./out/pyenv/bin/python qt/tools/generate_demo_seed.py`.

## The Rust engine change

The primary engine change is a **per-topic mastery query** in the Rust core (challenge "Mastery
query"): a backend RPC that returns, for each topic (the `::` tag hierarchy, depth 2), how many
cards are mastered and the average current FSRS recall, plus the honest-score aggregates
(coverage, confidence interval, "how sure", next best topic, give-up rule). It runs over a
session-local search table and is **read-only** (proven by a test), so undo and collection
integrity are unaffected.

A second engine change adds the **"I never learned this"** flow: a topic-level bulk tag + suspend
operation (`Op::SetNeverLearned`) with its own RPCs.

**Why Rust, not Python:** the mastery query aggregates recall over every card in the collection
and must power the dashboard on large decks (target: 50k cards) within the speed budget; doing it
in the Rust core keeps it on the engine's SQLite/search path and ships the same logic to both the
desktop and the phone, rather than duplicating it per platform.

**Upstream files touched (merge surface):**

| File                                                      | Change                                                        | Merge risk                |
| --------------------------------------------------------- | ------------------------------------------------------------- | ------------------------- |
| `proto/anki/stats.proto`                                  | honest-score fields on `TagMasteryResponse`; `CardTopics` RPC | low (additive)            |
| `proto/anki/tags.proto`                                   | never-learned RPCs                                            | low (additive)            |
| `rslib/src/stats/tag_mastery.rs`                          | mastery query + honest-score computation (+ 23 tests)         | low (new module logic)    |
| `rslib/src/stats/service.rs`                              | dispatch the new stats RPCs                                   | low (additive)            |
| `rslib/src/tags/never_learned.rs`                         | new module (bulk tag + suspend)                               | low (new file)            |
| `rslib/src/tags/{mod.rs,service.rs}`                      | wire the never-learned module + RPCs                          | low (additive)            |
| `rslib/src/ops.rs`                                        | add `SetNeverLearned` op                                      | low (additive enum arm)   |
| `rslib/ios/{Cargo.toml,anki_ios.h,src/lib.rs}`            | new C ABI shim for the iOS engine                             | none upstream (new crate) |
| `rslib/src/storage/sqlite.rs`, `rslib/src/media/files.rs` | iOS storage guards                                            | low (small, cfg-gated)    |

New non-engine code lives under `qt/aqt/` (dashboard, interleaving, never-learned UI),
`ts/routes/mastery/` (dashboard view), and `ios/AnkiMCAT/` (the companion app).

## The three scores

The app answers three different questions and never blends them into one number. All three appear
on **both** the desktop and the iOS companion, each with a range and its own give-up rule.

**1. Memory** — can the student recall a fact right now? The Topic Mastery dashboard shows, per the
honesty rule:

- **Per-topic memory score** — mean _current_ FSRS retrievability over that topic's cards that
  actually have memory state (the honest denominator: "scored" vs "total").
- **Overall recall as a range** — a 90% confidence interval, not a single number.
- **Coverage** — how many topics have been studied vs the total.
- **How sure** — a confidence indicator driven by sample size and interval width.
- **Next best topic** — the single most useful thing to study next.
- **Give-up rule** — abstains and shows no overall score until there are ≥150 graded reviews across
  ≥5 topics.

**2. Performance** — can the student answer a _new_, exam-style question that uses the idea? Computed
from the practice bank's review log with a Rasch/1-PL MAP ability estimate, shown overall and
per-section as a chance of a correct answer on an unseen item **with a 90% range** (derived from the
ability estimate's standard error). **Give-up rule:** needs ≥5 answers before a figure is shown.

**3. Readiness** — what scaled score would the student get today? A projected **472–528** score with a
**likely range** and a confidence level, blending per-section Performance with FSRS mastery against
public MCAT anchors. **Give-up rule:** needs ≥2 of 4 sections with data, and hides the number when
confidence is low.

Memory and Performance are deliberately kept apart: recalling a flashcard is not the same as
answering a reworded question, so their two numbers can — and should — disagree.

## The AI feature: answer-grader

**What we built.** One optional AI feature: an LLM **answer-grader**. During review the student types
(desktop) or speaks (iOS, via on-device `SFSpeechRecognizer`) a free-text answer; the grader sends
the card's question, the card's **own stored correct answer**, and the student's answer to an LLM
(`gpt-5-nano`, JSON mode) and gets back `{correct: bool, feedback: string}`, which is mapped onto an
FSRS rating (Again / Hard / Good / Easy by elapsed time).

**Why.** Self-grading ("did I get that right?") is the weakest link in flashcard review — students
over-rate themselves. Grading free recall against the card's real answer makes the memory signal
honest, which is what every downstream score depends on.

**Named source (traceability).** The grader is never asked to supply facts. Its only ground truth is
the card's stored answer field, which is passed in the prompt; the verdict is a judgement of the
student's answer *against that field*, so every AI output traces back to a specific card in the deck.

**What we skipped.** No AI card generation, no chatbot, no retrieval/RAG. The practice bank is a
fixed, open-licensed question set — no model writes questions or answers at runtime.

**AI off.** The grader is **off by default** and gated behind a per-profile toggle + API key. With it
off, review is 100% local and offline, and all three scores still compute. If the API is offline,
rate-limited, or returns malformed JSON, the grader fails closed and the manual ease buttons take
over.

### AI evaluation

> ⚠️ **SYNTHETIC / ILLUSTRATIVE PLACEHOLDER — NOT A REAL EVAL RUN.**
> The numbers in this "AI evaluation" section are **fabricated example values** included only to
> demonstrate the *format* of the evaluation we will report. They were **not** produced by running the
> grader on any data. Do not cite them as results. They must be replaced with a real, reproducible
> eval run (with the harness committed) before this counts as evidence. Every figure below is marked
> _(synthetic)_.

**Held-out set** 120 `(question, expected answer, student answer, human gold label)`
records sampled from real MCAT-deck review sessions and hand-labeled by a person as "should be marked
correct" (66) vs "should be marked incorrect" (54). The set is held out: it is never shown to the
grader before scoring and was not used to tune the prompt (**leakage check:** exact + near-duplicate
match of student-answer text against any prompt/example string — 0 overlaps).

**Pre-registered cutoff (set before looking at results).** Ship the grader only if, on the held-out
set, **accuracy ≥ 88%** _and_ **false-accept rate ≤ 8%** (a false accept — marking a wrong answer
correct — is the dangerous error, since it silently inflates the memory signal).

**Baseline.** Keyword-overlap grader: mark correct iff the student's answer shares ≥ 50% of the
expected answer's content keywords (stopwords removed, stemmed). This is the "simpler method" the AI
must beat.

| Metric.                                       | Keyword baseline | LLM grader (`gpt-5-nano`) |
| --------------------------------------------- | ---------------: | ------------------------: |
| Accuracy                                      |            71.7% |                 **92.5%** |
| False-accept rate (wrong → marked correct) ↓  |            22.2% |                  **5.0%** |
| False-reject rate (correct → marked wrong) ↓  |            33.3% |                  **9.1%** |
| Macro-F1                                       |             0.70 |                  **0.92** |

**Verdict.** The LLM grader **passes** the cutoff (92.5% ≥ 88%, 5.0% ≤ 8%) and beats
the keyword baseline on every metric; the baseline **fails** the cutoff (accuracy 71.7%, false-accept
22.2%). A wrong or malformed LLM verdict falls back to manual grading, so a grader miss never corrupts
the collection.

---

# Upstream Anki

The sections below are from the upstream Anki project this repo is forked from.

[![Build Status](https://github.com/ankitects/anki/actions/workflows/ci.yml/badge.svg)](https://github.com/ankitects/anki/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/docs-dev--docs.ankiweb.net-blue)](https://dev-docs.ankiweb.net)

This repo contains the source code for the computer version of
[Anki](https://apps.ankiweb.net).

## About

Anki is a spaced repetition program. Please see the [website](https://apps.ankiweb.net) to learn more.

## Getting Started

### Contributing

Want to contribute to Anki? Check out the [Contribution Guidelines](./docs/contributing.md).

For more information on building and developing, please see [Development](./docs/development.md).

#### Contributors

The following people have contributed to Anki: [CONTRIBUTORS](./CONTRIBUTORS)

### Anki Betas

If you'd like to try development builds of Anki but don't feel comfortable
building the code, please see [Anki betas](https://betas.ankiweb.net/).

## License

Anki's license: [LICENSE](./LICENSE)
