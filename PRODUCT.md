# Product

## Register

product

## Users

Pre-med students preparing for the MCAT (scored 472–528 across four sections:
Chem/Phys, CARS, Bio/Biochem, Psych/Soc). They are under real time pressure and
high stakes, working through an enormous fact base plus reading-comprehension
passages. Their core job: cover everything, know honestly what they've retained
and what they haven't, and decide what to study next. They use the app in long,
focused review sessions on desktop and in shorter spaced sessions on the iOS
companion — often the same collection synced across both.

## Product Purpose

MCAT Speedrun is a spaced-repetition study app built as a fork of Anki, sharing
Anki's Rust core across a desktop app and an iOS companion. Beyond the standard
review loop, it adds a per-topic mastery query in the engine and an **honest
memory-readiness dashboard**: three separate, ranged scores — **Memory**
(per-topic FSRS recall + confidence interval), **Performance** (chance of
answering a new exam-style question), and **Readiness** (projected 472–528
scaled score with a likely range). Each score has its own give-up rule and
abstains rather than guessing. Success is a student who trusts the numbers
enough to act on them — and never feels falsely reassured.

## Brand Personality

Clinical, authoritative, dense. The interface should read like a serious,
data-forward instrument, not a cheerful coach. Voice is precise and calm:
confident about what it knows, explicit about what it doesn't. Emotional goal is
**earned trust** — the student under pressure should feel the tool is telling
them the truth and disappearing into the work, not performing enthusiasm at them.

## Anti-references

- **Generic AI-SaaS.** No cream/beige body backgrounds, gradient-text heroes,
  identical icon-card grids, or tracked-uppercase eyebrows on every section. The
  existing "Clinical Aurora" system (deep teal + aurora sweep) is the identity;
  don't drift toward the SaaS monoculture.
- **Gamified edtech (Duolingo).** No mascots, confetti, XP bars, streak guilt,
  or badge overload. Motivation comes from honest signal, not manipulation.
- **Cluttered legacy Anki.** Don't inherit the dated, options-everywhere
  power-user density that overwhelms a first-time MCAT student. Custom MCAT
  surfaces should be focused and legible even though they sit inside Anki.

## Design Principles

- **Honesty over reassurance.** Never overstate readiness. Memory recall is not
  exam readiness — keep the three scores distinct, always show ranges, and abstain
  when data is thin. This is the product's spine, not a nicety.
- **Color carries meaning, not decoration.** Semantic green/red is reserved for
  *real* correctness (a practice answer right or wrong). Memory-recall visuals use
  neutral magnitude fills — never a red→green scale — so nobody misreads recall as
  readiness.
- **The tool disappears into the task.** Earned familiarity over novelty. Standard
  affordances, consistent component vocabulary, density where a studying user needs
  it. Delight is saved for moments, not pages.
- **One engine, one voice.** Desktop and iOS share the Rust core; the three scores,
  their ranges, and their give-up rules must read identically across both surfaces.
- **Respect the fork.** Custom MCAT surfaces adapt to Anki's light/dark themes via
  its theme variables and stay cohesive with the shared design system rather than
  fighting the host app.

## Accessibility & Inclusion

Best-effort, no formal WCAG target committed. Follow good practice: body text
should clear a legible contrast bar against its background in both light and dark
themes, honor `prefers-reduced-motion`, and never rely on color alone to convey
state — especially important given the semantic-color honesty rule (pair
green/red correctness with text or iconography).
