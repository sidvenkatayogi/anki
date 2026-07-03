# Practice question bank — sources & licensing

`practice-seed.json` is a **data file** distributed separately from Anki's
AGPL-licensed source code. Its contents are licensed as described below. The
`answer_index` and `explanation` fields are original content authored for this
project (not copied from the sources) and may be used under the same terms as
the surrounding data file.

## Science questions (categories `bio_biochem`, `chem_phys`, `psych_soc`)

The question stems and answer options are reproduced **verbatim** from OpenStax
textbooks and are licensed under
**Creative Commons Attribution-NonCommercial-ShareAlike 4.0 (CC BY-NC-SA 4.0)**
— <https://creativecommons.org/licenses/by-nc-sa/4.0/>.

This means this bank, as a derivative, is **non-commercial** and must be
shared under the same CC BY-NC-SA 4.0 license, with attribution.

| id prefix  | category    | source (all © OpenStax, CC BY-NC-SA 4.0)                                                                    |
| ---------- | ----------- | ----------------------------------------------------------------------------------------------------------- |
| `os-bio-`  | bio_biochem | _Biology 2e_, Ch. 3 (Biological Macromolecules) — <https://openstax.org/books/biology-2e>                   |
| `os-phys-` | chem_phys   | _Physics_, multiple-choice sections — <https://openstax.org/books/physics>                                  |
| `os-psy-`  | psych_soc   | _Psychology 2e_, Ch. 1 review questions — <https://openstax.org/books/psychology-2e>                        |
| `os-soc-`  | psych_soc   | _Introduction to Sociology 3e_, Ch. 1 section quiz — <https://openstax.org/books/introduction-sociology-3e> |

> Note: OpenStax's chemistry titles publish free-response exercises rather than
> multiple-choice questions, so the `chem_phys` category is currently sourced
> from OpenStax _Physics_. Chemistry MCQs can be added later from a suitably
> licensed source.

Attribution statement (per OpenStax reuse guidelines): _"Access for free at
openstax.org."_

## CARS questions (category `cars`)

The `cars-*` reading passages were supplied by the project owner
(`questions/cars.md`). Each passage carries its own upstream attribution line
in the text (e.g. "Adapted from G. Ritzer, _The McDonaldization of Society_").
These are included on the owner's representation that they are cleared for this
use; they are **not** covered by the CC BY-NC-SA license above. `answer_index`
and `explanation` for these items were derived for this project.

## Keeping copies in sync

Identical copies of `practice-seed.json` live at:

- `tools/syncserver/mcat_tools/data/practice-seed.json` (server, authoritative)
- `qt/aqt/data/web/practice-seed.json` (desktop bundle)
- `ios/AnkiMCAT/Resources/practice-seed.json` (iOS bundle)
- `.factory/runs/2026-07-02-read-practice-tabs/contracts/practice-seed.json` (contract; read by tests)

`ts/tests/unit/practiceSeed.test.ts` asserts all copies are byte-identical.
