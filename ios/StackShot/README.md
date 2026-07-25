# StackShot — first draft

Manual-control focus-stacking camera for iOS. Blueprint: `../../docs/focus-stack-ios/BLUEPRINT.md`.

**Status: first draft, written off-device.** This code has not yet been compiled in Xcode or
run on a phone — expect a shakedown pass. The structure follows the blueprint exactly.

## Building

Requires a Mac with Xcode 15+, and a physical iPhone (the Simulator has no camera).

```bash
brew install xcodegen
cd ios/StackShot
xcodegen generate
open StackShot.xcodeproj
```

Set your signing team, select your device, run.

## What works out of the box (once it compiles)

- Lens picker (0.5x / 1x / Tele), manual ISO + shutter with a **live luminance histogram**,
  **Kelvin white balance** with light-box presets + tint, one-button lock for the whole stack.
- Manual focus slider with **focus peaking** (green edge overlay) and the **3× loupe**
  (pinch 2×–6×, tap the viewfinder to move it) for confirming sharpness.
- **Set Near / Set Far** anchors → adjustable-count bracket (default 8, inclusive endpoints)
  with a 2 s start timer, per-step focus settle-wait, and RAW (DNG) capture with HEIF fallback.
- Frames + `manifest.json` persisted per StackSet; merged result saved beside them.
- **Library screen** to browse saved StackSets and re-stack without re-shooting, plus an
  **Acknowledgements screen** for the shipped licenses.
- A **native Swift fallback stacker** (per-pixel sharpest-source depth map — Method-B-style,
  no alignment) so the end-to-end flow works before the C++ engine is wired in.
- **Depth-map view toggle** in the review/library UI to inspect the per-pixel source map.
- **Persisted capture settings** (ISO, shutter, Kelvin, tint, step count, peaking on/off,
  output format, keep-frames) carried across app launches.
- **Settings sheet** (gear icon): stacked output as **JPEG quality 90 (default — eBay and
  other listing sites accept JPEG, not HEIC)** or HEIC for smaller files, and a toggle to
  **keep or auto-delete the RAW source frames** after a successful stack.
- **Peaking on/off button** alongside the existing focus peaking overlay.
- **One-tap gray-card white balance** lock using the device's gray-world estimate.
- **Corrupt-stack warning** in the library when a StackSet's manifest fails to decode.
- **Automatic cleanup** of failed or cancelled brackets so partial captures don't linger on disk.

## Running tests

```bash
xcodegen generate
```

then open `StackShot.xcodeproj` in Xcode and run the StackShot scheme's tests with **⌘U**.
Unit tests cover bracket spacing, settings persistence, and manifest coding. They are
desk-verified only so far — this is the first time they'll actually execute, on the Mac.

## Embedding the real engine (focus-stack + OpenCV)

The fallback stacker is deliberately simple. For production quality run:

```bash
./scripts/fetch_engine.sh
```

then follow the three steps printed at the end (add the OpenCV xcframework and the vendored
`focus-stack` sources to the target, enable `ENGINE_EMBEDDED` in `project.yml`, regenerate).
`Bridge/FocusStackBridge.mm` calls the vendored `FocusStack` C++ class — verify its API names
against the checkout, as noted in the file.

## Licenses shipped

- [PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack) — MIT
- [OpenCV](https://opencv.org) — Apache-2.0

## Known first-draft gaps

- The fallback stacker is CPU-bound (~seconds per stack at 2048 px) and does no alignment;
  the embedded C++ engine replaces it for production quality and speed.
- The C++ engine is not yet vendored by default — see "Embedding the real engine" above.
- Loupe LiDAR distance readout is not implemented.
- Diopter (macro) spacing is deferred.
