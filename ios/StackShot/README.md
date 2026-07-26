# StackShot — first draft

Manual-control focus-stacking camera for iOS. Blueprint: `../../docs/focus-stack-ios/BLUEPRINT.md`.

**Status: compiles and unit-tests green in CI; never yet run on a phone.** GitHub Actions
builds the app, runs the unit tests, and separately compile-checks the embedded C++ engine
path on every push. On-device behaviour (focus sweep, peaking, stack quality) is still
entirely unvalidated — the first device session is the next milestone, and
[`FIRST-SESSION.md`](../../docs/focus-stack-ios/FIRST-SESSION.md) is the protocol for it:
what to shoot, in what order, what to check at each step, and which diagnostic to read
when something looks wrong.

## Building

Requires a Mac with Xcode 16+ (current XcodeGen emits project format 77). A physical
iPhone is required for anything involving the camera; the Simulator runs in **preview
mode** (synthetic frames on a timer, marked with a red `PREVIEW · no camera` badge) so the
UI can be exercised without hardware — but nothing it shows is real capture output.

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
  (pinch 2×–6×, tap the viewfinder to move it) for confirming sharpness. A yellow reticle
  marks what the loupe is showing, and the loupe dodges to the opposite side so it never
  covers the region it's magnifying.
- The lens button **defaults to the closest-focusing camera** — on modern iPhones that's
  the ultra-wide, which is the macro lens and the one you want for a reel.
- **Set Near / Set Far** anchors → adjustable-count bracket (default 8, inclusive endpoints)
  with a 2 s start timer, per-step focus settle-wait, and RAW (DNG) capture with HEIF fallback.
- Each capture is a StackSet folder: `manifest.json` (capture settings + frame metadata)
  plus the merged result. The RAW frames themselves are deleted once the stack succeeds.
- **Library screen** to browse, export, and swipe-delete saved stacks, plus an
  **Acknowledgements screen** for the shipped licenses.
- A **native Swift fallback stacker** (per-pixel sharpest-source depth map — Method-B-style)
  so the end-to-end flow works before the C++ engine is wired in. It is what runs on device
  today, and two of its limits look like bugs if you don't expect them: it **downscales to
  2048 px** on the long edge to bound memory, and it does **no alignment between frames**,
  so rig drift shows as doubling. Both go away with the C++ engine below.
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
- **Capture log** (`capture-log.txt`) written into each stack's folder and shareable from
  the Library detail: per frame, the target lens position, the position actually reached,
  whether the lens settled or timed out, capture attempts used, and RAW vs HEIF — then the
  engine, duration and output size. It's how a soft or banded stack gets diagnosed rather
  than guessed at. [`FIRST-SESSION.md`](../../docs/focus-stack-ios/FIRST-SESSION.md) has a
  table for reading it.

## Running tests

```bash
xcodegen generate
```

then open `StackShot.xcodeproj` in Xcode and run the StackShot scheme's tests with **⌘U**.
They run on every push via `.github/workflows/ios-tests.yml`.

Coverage is confined to logic that needs no camera, which is the only kind verifiable
before the first device session: bracket spacing and inclusive endpoints, settings
persistence and clamping, manifest coding (including manifests written before EV
compensation existed), the shutter-readiness rule and its caption, aspect-fit geometry for
the tap-to-loupe mapping, and the capture log's cross-instance append.

## Embedding the real engine (focus-stack + OpenCV)

The fallback stacker is deliberately simple and does no frame alignment. For production
quality — including alignment for focus breathing during a macro stack — run:

```bash
./scripts/fetch_engine.sh
```

That's the whole flow. The script vendors the MIT `focus-stack` sources plus OpenCV's iOS
`opencv2.framework`, then (if `xcodegen` is on `PATH`) generates `StackShotEngine.xcodeproj`
from `project-engine.yml`, which wires both into a build with `ENGINE_EMBEDDED` enabled.
Open `StackShotEngine.xcodeproj` to build and run on device with the real C++ engine. CI's
`build-engine` job builds this exact project on every push, so the ObjC++ bridge and the
C++ core are known to build for iOS.

`StackShot.xcodeproj` (generated from `project.yml`, per "Running tests" above) is the
separate, plain project used for the unit tests and the pure-Swift fallback engine — it is
untouched by `fetch_engine.sh` and has no C++ engine compiled in.

## Licenses shipped

- [PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack) — MIT
- [OpenCV](https://opencv.org) — Apache-2.0

## Known first-draft gaps

- The fallback stacker is CPU-bound (~seconds per stack at 2048 px) and does no alignment;
  the embedded C++ engine replaces it for production quality and speed.
- The C++ engine is not vendored or built by default — it requires running
  `scripts/fetch_engine.sh`, which produces a separate `StackShotEngine.xcodeproj`; see
  "Embedding the real engine" above.
- Loupe LiDAR distance readout is not implemented.
- Diopter (macro) spacing is deferred.
