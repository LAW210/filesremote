# StackShot — first draft

Manual-control focus-stacking camera for iOS. Blueprint: `../../docs/focus-stack-ios/BLUEPRINT.md`.

**Status: compiles and unit-tests green in CI; never yet run on a phone.** GitHub Actions
builds the app, runs the unit tests, and separately compile-checks the embedded C++ engine
path on every push. On-device behaviour (focus sweep, peaking, stack quality) is still
entirely unvalidated — the first device session is the next milestone.

## Building

Requires a Mac with Xcode 16+ (current XcodeGen emits project format 77), and a
physical iPhone (the Simulator has no camera).

```bash
brew install xcodegen
cd ios/StackShot
xcodegen generate
open StackShot.xcodeproj
```

Set your signing team, select your device, run.

## What works out of the box (once it compiles)

- One **lens button** cycling the available back cameras; **EV compensation** (positive
  only — a light box meters bright and darkens the subject) with a **live luminance
  histogram**; **Kelvin white balance** with light-box presets + tint; one Lock that
  freezes exposure and colour for the whole stack. ISO and shutter are the camera's to
  choose and are deliberately not shown.
- Manual focus slider with **focus peaking** (green edge overlay) and the **3× loupe**
  (pinch 2×–6×, tap the viewfinder to move it) for confirming sharpness.
- **Set Near / Set Far** anchors → adjustable-count bracket (default 8, inclusive endpoints)
  with a 2 s start timer, per-step focus settle-wait, and RAW (DNG) capture with HEIF fallback.
- Each capture is a StackSet folder: `manifest.json` (capture settings + frame metadata)
  plus the merged result. The RAW frames themselves are deleted once the stack succeeds.
- **Library screen** to browse, export, and swipe-delete saved stacks, plus an
  **Acknowledgements screen** for the shipped licenses.
- A **native Swift fallback stacker** (per-pixel sharpest-source depth map — Method-B-style,
  no alignment) so the end-to-end flow works before the C++ engine is wired in.
- **Depth-map view toggle** in the review/library UI to inspect the per-pixel source map.
- **Persisted capture settings** (EV bias, Kelvin, tint, step count, overlay toggles,
  output format) carried across app launches.
- **Settings sheet** (gear icon): stacked output as **JPEG quality 95 (default — eBay and
  other listing sites accept JPEG, not HEIC)** or **PNG (lossless master, ~4–6× larger,
  for edit-then-export workflows)**.
- **Torch** and **zebra** as corner icon buttons — occasional tools, checked when the
  lighting or a reel's finish changes rather than during every shot.
- **Files-app visibility**: the app's stacks are browsable in Files and over cable in
  Finder, for dragging masters straight into a desktop editor.
- **Per-frame capture retry**: one transient AVFoundation failure no longer aborts (and
  deletes) the whole bracket.
- **Sound-only capture feedback** — a tick per frame and a chime when the stack is done.
  Deliberately no haptics: vibration would shake the tripod during exposure.
- The **zebra overlay** paints blown highlights red. It earns its place because in a
  light box the histogram is permanently pegged by the white backdrop, so only a
  positional warning distinguishes "background clipping, fine" from "chrome rim
  clipping, unrecoverable".
- **EXIF on the stacked file** (capture date, device, ISO, shutter) via CGImageDestination,
  so outputs date and attribute correctly in Photos and editors.
- **RAW frames are deleted automatically** once the stacked image is safely written —
  only the final image is kept (so stacks can't be re-processed; re-shoot instead).
- **Exact-bytes save & share**: Save to Photos and the share sheet both use the encoded
  file on disk directly (no decode/re-encode), so the quality-95 JPEG is compressed
  exactly once, ever.
- **Auto-save to Photos** (on by default): the finished JPEG file lands in your photo
  library the moment stacking completes — capture → stack → saved, no taps.
- **1:1 crop guide** (Settings): dims what a square eBay-thumbnail crop would discard,
  so you frame for the listing before spending a stack.
- **Background handling**: the camera session pauses when the app is backgrounded and
  resumes on return.
- **Peaking on/off button** alongside the existing focus peaking overlay.
- **One-tap gray-card white balance** lock using the device's gray-world estimate.
- **Automatic cleanup** of failed or cancelled brackets so partial captures don't linger on disk.

## Running tests

```bash
xcodegen generate
```

then open `StackShot.xcodeproj` in Xcode and run the StackShot scheme's tests with **⌘U**.
Unit tests cover bracket spacing, settings persistence, and manifest coding, and run on
every push via `.github/workflows/ios-tests.yml`.

## Embedding the real engine (focus-stack + OpenCV)

The fallback stacker is deliberately simple. For production quality run:

```bash
./scripts/fetch_engine.sh
```

That vendors the MIT `focus-stack` sources plus OpenCV's iOS `opencv2.framework`. The
`project-engine.yml` spec wires both into a build with `ENGINE_EMBEDDED` enabled, and CI's
`build-engine` job compiles exactly that on every push — so the ObjC++ bridge and the C++
core are known to build for iOS. To run it on device, mirror those settings into
`project.yml` (the `ENGINE_EMBEDDED` flags are commented out there) and regenerate.

## Licenses shipped

- [PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack) — MIT
- [OpenCV](https://opencv.org) — Apache-2.0

## Known first-draft gaps

- The fallback stacker is CPU-bound (~seconds per stack at 2048 px) and does no alignment;
  the embedded C++ engine replaces it for production quality and speed.
- The C++ engine is not yet vendored by default — see "Embedding the real engine" above.
- Loupe LiDAR distance readout is not implemented.
- Diopter (macro) spacing is deferred.
