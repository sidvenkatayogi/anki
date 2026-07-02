# Memory Palace (iOS)

A spatial study mode for the Anki MCAT app, built on the *method of loci*: you
capture a place you know well (a desk, a kitchen, a room), pin flashcards to
specific spots in it, and later recall them **by location** — "what card lives
here?" and "where does this card live?". Every recall grades the underlying card
through the real **FSRS** scheduler, so palace practice counts toward your
reviews.

It lives in the second tab of the app (**Review** | **Palace**).

## How it works

1. **Capture a place.** Create a palace and give it a name and a spot capacity
   (default 7 — classic loci sizing).
   - **On a real device**, capture uses **live AR** (ARKit world tracking): point
     at a real surface and tap to drop a card "pin" as a persistent world anchor.
     The room is saved as an `ARWorldMap` so pins reappear in the same physical
     spots next time. LiDAR devices additionally get a dense scene mesh; non-LiDAR
     devices fall back to feature-point tracking. **No LiDAR is required.**
   - **In the Simulator / on devices without AR / as a fallback**, capture uses a
     **room photo**: choose a picture from your library, or tap **"Use a sample
     room"** (a built-in illustrated room, no setup needed), then tap spots to
     drop pins. Pins are joined by a numbered **journey route** as you place them.
2. **Pick a card per spot.** Tapping a spot opens a searchable picker over your
   existing MCAT cards (Anki query syntax, e.g. `tag:biochem`). Tapping a placed
   spot later opens its detail sheet: view the card, write a vivid **memory hook
   (mnemonic)**, mark it recalled, or remove it.
3. **Space runs out.** Each palace holds a bounded number of spots. When it fills
   up, placement is blocked and you're prompted to **capture a new place** — a
   fresh room makes new cards easier to recall.
4. **Study by location.** Pick a mode and go:
   - **Recall ("what's here?")** — a spot lights up; recall the card, reveal it,
     and grade Again/Hard/Good/Easy.
   - **Locate ("where is it?")** — a card is shown; tap the spot it lives in; see
     if you were right, then grade.
   - **Mixed** — alternates the two.
   Grading round-trips through the shared Rust scheduler (`answer_card`), updating
   real FSRS due dates. The session ends on a **visual recap**: an accuracy ring
   plus your room map with each spot recolored green (recalled) or red (review).

### Visualizations
- **Journey route** — pins connected by an animated numbered path (the loci route
  you "walk"), shown on the capture screen, the palace detail map, and the recap.
- **Progress rings** — per-palace learned fraction in the list and a large stat
  ring on the detail screen.
- **Study recap** — accuracy ring + outcome-colored room map + counts, with
  "Study again".
- **Sample room** — a room illustration drawn in-app (`Canvas` + `ImageRenderer`),
  so the whole loop works with zero setup and is UI-testable in the Simulator.

## Architecture

The feature shares the app's single `AnkiEngine` actor (one opened
backend/collection, serialized per the threading contract) and adds a self-
contained `Palace/` module. Nothing in the Rust/proto layers changed.

```
Sources/AnkiMCAT/
  App/
    AnkiMCATApp.swift     ← creates ONE engine, injects into both models, root TabView
    ReviewModel.swift     ← now takes an injected engine (default arg keeps it backward-compatible)
  Engine/
    AnkiEngine.swift      ← + searchCards(29,1), schedulingStates(13,23), gradeCard(→13,4)
  Palace/
    PalaceModels.swift    ← Palace / Locus / PalacePoint (Codable, ARKit-free)
    PalaceLogic.swift     ← pure helpers: HTML→label, capacity, study steps, simd⇄[Float]
    PalaceStore.swift     ← on-disk persistence (Documents/MemoryPalaces/<uuid>/)
    PalaceModel.swift     ← @MainActor @Observable orchestrator over store + engine
    PalaceListView.swift  ← home list, new-palace sheet, per-palace detail
    CardPickerView.swift  ← searchable card picker (lazy labels)
    PhotoPalaceView.swift ← photo + tappable pins (Simulator/fallback + snapshot)
    ARPalaceView.swift    ← ARSCNView world-anchor capture/study + world-map persistence
    PalaceCaptureView.swift ← capture orchestration (AR vs photo), placement → picker
    PalaceStudyView.swift ← study session (recall/locate/mixed) → FSRS grading + recap
    LocusDetailView.swift ← per-spot sheet: view card, edit mnemonic, remove
    PalaceVisuals.swift   ← ProgressRing / StatRing
    PalaceSampleRoom.swift ← in-app illustrated room (Canvas + ImageRenderer)
```

### Persistence layout
```
Documents/MemoryPalaces/<palace-uuid>/
  palace.json           metadata + loci (card id, label, mnemonic, transform, 2-D point, learned)
  photo.jpg             reference photo / AR snapshot (thumbnail + 2-D fallback)
  worldmap.arworldmap   archived ARWorldMap (device only)
```
Card **content** is always fetched live from the engine by card id, so it never
goes stale. Each locus stores **both** a world transform (AR) and a normalized
2-D photo point, so a palace can always be reviewed as a flat "snapshot with
pins" even if AR relocalization fails.

## Building & running

The Xcode project is generated by **XcodeGen** from `project.yml` (the
`.xcodeproj` is gitignored). `sources:` are folder paths, so the `Palace/` files
are picked up automatically — regenerate with `xcodegen generate` (or just run
`./build-sim.sh`, which does it for you). New build settings (e.g. the camera
usage description) go in `project.yml`, not the generated pbxproj.

Simulator build (arm64 only, matching the xcframework slices):

```
xcodebuild -project ios/AnkiMCAT/AnkiMCAT.xcodeproj -scheme AnkiMCAT \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES build
```

Tests (drives the app in a booted simulator, incl. the palace create flow):
```
xcodebuild test -project ios/AnkiMCAT/AnkiMCAT.xcodeproj -scheme AnkiMCAT \
  -destination 'id=<booted-sim-id>' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO -only-testing:AnkiMCATUITests
```

## Running the AR experience on a physical iPhone

ARKit produces no camera frames in the Simulator, so the immersive AR capture/
study only runs on a real device. To run on hardware:

1. **Device slice of `Anki.xcframework`.** `ios/build-xcframework.sh` now packages
   **both** the `aarch64-apple-ios` (device) and `aarch64-apple-ios-sim` slices, so
   the app builds and links for a real iPhone out of the box. (Pass `SIM_ONLY=1`
   for a faster sim-only rebuild.) Rerun it after any Rust change.
2. **Signing.** Set your development team in Xcode (or via `DEVELOPMENT_TEAM`) to
   install on a device — the repo builds unsigned for the Simulator.
3. **Camera permission** is already declared (`INFOPLIST_KEY_NSCameraUsageDescription`
   in `project.yml`). No `arkit` *required-capability* is set, so non-AR devices
   still install and use the photo path.

### On-device verification checklist
- [ ] Palace tab → New place → capture screen shows the **live camera** (AR), not the photo prompt.
- [ ] Tap a surface → a numbered pin anchors in space and stays put as you move.
- [ ] Pick a card → the pin persists; add several until the room is "full".
- [ ] Leave and reopen the palace → "Finding your room…" → pins relocalize to the same spots.
- [ ] Study → Recall: the highlighted pin pulses in AR; reveal + grade updates the card.
- [ ] Study → Locate: tap the correct pin; grade.

## Limitations / notes
- **AR is unverified on hardware** in this build (developed against the Simulator,
  which has no camera/ARKit). The AR code compiles and is logically complete; the
  photo path is UI-tested. Verify AR on a device using the checklist above.
- **Relocalization without LiDAR** needs similar viewpoint/lighting; a failed
  relocalize falls back to the 2-D snapshot review rather than dead-ending.
- Pinned cards are referenced by **card id**, stable while the same deck stays
  imported. If the deck is switched (which clears the collection), a palace's
  cards show as "unavailable" and are skipped gracefully.
