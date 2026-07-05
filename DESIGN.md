# Design

The visual system for the Ankinetic custom surfaces — **"Console"**: a
self-contained, near-black instrument panel with a single amber phosphor accent
and monospaced readouts. It is defined once and shared by desktop web
(`sass/mcat-tools.scss`) and iOS (`ios/AnkiMCAT/Sources/AnkiMCAT/App/Theme.swift`).

> Scope: **the whole app.** The custom MCAT surfaces (Scores/Mastery, Practice,
> To-Learn on desktop; Review, Scores, Practice, Palace, Account on iOS) are
> self-contained Console (their own `$con-*` tokens). Everything else — deck
> browser, toolbar, reviewer chrome, stats, editor, deck options, dialogs — is
> made Console by **retuning Anki's own theme at the source** and pinning the app
> to dark (see "Global theming" below), so native Qt widgets and stock web pages
> follow too.

## Global theming (whole-app Console)

Anki generates both its web CSS and native Qt colours (`_aqt.colors`) from one
source: `ts/lib/sass/_color-palette.scss` + `ts/lib/sass/_vars.scss`. To make the
*entire* app Console rather than patching each surface:

- **Force dark.** `qt/aqt/theme.py` `_determine_night_mode()` always returns
  `True`, so every native + web surface uses the dark theme regardless of OS
  preference. iOS is pinned with `.preferredColorScheme(.dark)`.
- **Retune the neutral ramp.** `_color-palette.scss` `darkgray` is a cool
  blue-graphite ramp aligned to the `$con-*` tokens (panel `#10161d`, well
  `#0c1116`, bg `#0a0e13`) — replacing Anki's warm greys.
- **Retarget the accent.** The blue accent roles in `_vars.scss` (link, focus,
  primary button, card accent, highlight, selected) now map to the `amber` ramp.
  **Semantic colours are preserved:** card-count new/learn/due, flags, and graph
  series keep their meanings.
- iOS card rendering (`CardWebView`) adds Anki's `nightMode` body class + a
  light-ink default so decks render dark, matching the desktop reviewer.

## Register

product

## Theme

Dark, always. The surfaces are pinned to a graphite "Console" ground regardless
of the host theme — Anki ships both light and dark, and iOS follows the system,
so the pages **do not inherit** `--fg`/`--canvas` (web) or system semantic greys
(iOS). Web pages wrap content in `.con-root`; iOS is pinned with
`.preferredColorScheme(.dark)` and explicit palette colours. This keeps the look
identical everywhere and lets the amber accent read as lit phosphor.

Scene: a stressed pre-med studying late against a bright screen, who needs to
trust the numbers at a glance. The instrument metaphor serves that — it reads as
a calibrated readout, not a cheerful coach.

## Color

Strategy: **Restrained** — graphite neutrals + one amber accent. Cool near-black
grounds (a faint blue cast, so it reads as a screen, not warm paper).

| Role | Web token | Hex |
|---|---|---|
| Ground | `$con-bg` | `#0A0E13` |
| Panel | `$con-panel` | `#10161D` |
| Nested / raised | `$con-panel-2` | `#161E27` |
| Inset well (tracks) | `$con-well` | `#0C1116` |
| Ink (primary) | `$con-ink` | `#DFE6EE` |
| Ink dim (secondary) | `$con-ink-dim` | `#94A2B2` |
| Ink faint (captions) | `$con-ink-faint` | `#5F6C7B` |
| **Amber accent** | `$con-amber` | `#FFB020` |
| Text on amber | `$con-amber-ink` | `#1A1206` |
| Steel (neutral magnitude) | `$con-steel` | `#8B98A8` |
| Correct (semantic) | `$con-correct` | `#3FB950` |
| Incorrect (semantic) | `$con-incorrect` | `#F85149` |

Hairlines are `rgba(148,163,184, .16)` (`$con-line`). iOS mirrors every token in
`MCATTheme` (`.bg`, `.panel`, `.amber`, `.steel`, …).

**The honesty rule (non-negotiable):**
- **Memory recall** visuals use **steel** only — never a red→green scale, and
  never amber (amber would read as "good/go"). Recall is not readiness.
- **Semantic green/red** is reserved for **real correctness** — a practice answer
  being right or wrong. Never for recall or projected scores.
- **Amber** is the interaction / wayfinding accent, and is legitimate on the
  *scored* metrics (Performance, Readiness) which are estimates, not verdicts.
- Confidence-in-the-estimate cues may use green (high) / amber (medium) — that
  grades our certainty, which is honest.

## Typography

A **mono ↔ sans** contrast pairing:
- **Mono** (`SF Mono`/`JetBrains Mono`/`ui-monospace`) is the instrument voice:
  all chrome, labels, numbers, section headers, buttons, data. `tabular-nums`
  everywhere.
- **Sans** (`system-ui`) carries long prose only — question stems, CARS
  passages, explanations — where mono would be fatiguing.

Fixed rem scale (product register — not fluid clamp headings, except the hero
score figures which scale for impact). Uppercase + wide tracking on mono labels
and section headers.

## Components / devices

Defined as SCSS mixins (`sass/mcat-tools.scss`) and SwiftUI views (`Theme.swift`):

- **Panel** (`con-panel` / `mcatCard`) — graphite surface, hairline border,
  small radius (8px). The base container. No nested cards.
- **Section header** (`con-section-header` / `MCATSectionHeader`) — leading amber
  block glyph + mono uppercase label + hairline rule to end of row. Replaces the
  AI "eyebrow"; reads as a labelled instrument channel.
- **Bracketed range scale** (`con-scale` / `MCATScale`) — the signature honest
  device: fixed axis, lit "likely" band, bright point marker. Used for every
  ranged score (recall CI, performance CI, 472–528 readiness).
- **Leader row** (`con-leader-row`) — `label ······· value` dotted leaders for
  dense, scannable readouts.
- **Blocky meter** (`con-bar` / `MCATNeutralBar`) — filled bar with a faint
  segment grid (console-meter texture). Steel for recall, amber for scored.
- **Readout figure** — big mono number + tiny uppercase unit label.
- **Chip** (`con-chip` / `MCATChip`) — bracketed mono token, not a pill.
- **Buttons** — primary = solid amber fill / dark ink / mono uppercase;
  secondary = ghost with hairline border, amber on hover.
- **Gauge** (`MCATGauge`, iOS) — ring kept for existing call sites; steel
  (neutral) or amber (scored), mono value.
- **Blinking caret** (`con-caret`) — small "powered-on" delight after the screen
  name in the masthead.

## Motion

150–250ms, `cubic-bezier(0.2, 0.8, 0.2, 1)`. Panels have a subtle staggered
entrance (`con-enter`) that **enhances an already-visible default** — the base
state is fully visible; the animation only runs under
`prefers-reduced-motion: no-preference`, so headless renderers and hidden tabs
never ship blank. Bars/scales animate width/trim on data change. Reduced-motion
disables the caret blink and transitions.

## What this is NOT (bans)

No gradient text, no glassmorphism, no side-stripe borders (Practice's old
`border-inline-start` reveal was removed in favour of a full-border tint), no
aurora/gradient hero (replaced by the amber readout + bracket scale), no
per-section eyebrows or 01/02 numbering, no cream/beige anything. Not gamified
(no confetti/XP/streaks), not cluttered legacy-Anki density.
