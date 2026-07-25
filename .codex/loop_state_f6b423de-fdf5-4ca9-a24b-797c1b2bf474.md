# StackShot improvement loop — state

- Session UUID: f6b423de-fdf5-4ca9-a24b-797c1b2bf474
- Target codebase: `ios/StackShot/`
- Iterations: 6 total · Current: 2
- Environment notes: no Swift toolchain in container — the verification agent performs
  static analysis / desk verification, not executed tests. Planning skill
  `$plan-unblocked-improvements` is unreachable (macOS-local path); replaced by an
  equivalent inline planning pass per iteration.
- Loop rules: implementers build only what the plan lists (no scope expansion, no
  out-of-plan refactors); max 3 retry rounds on verification failures; pause for user
  guidance on retry exhaustion, ambiguity, or high-risk changes; maintenance sweep on
  iterations 3 and 6; prune prior-iteration entries to one line each.

## Technical Debt

Logged by the iteration-3 maintenance sweep (complex; not fixed passively):
1. NativeDepthMapStacker.swift:9 — no frame alignment before compositing; handheld
   captures will ghost (embedded C++ engine adds ECC; fallback documents the limit).
2. FocusBracketController.swift:69 — a mid-bracket capture failure leaves orphaned
   frame files/directory with no cleanup.
3. StackSet.swift:81 (StackStore.loadAll) — corrupt manifests silently vanish (try?).
4. CameraService.swift:210 — .restricted vs .denied camera permission collapsed into
   one generic error message.
5. StackEngine.swift:70 — C++ engine depth map uses a fixed tmp path; concurrent
   stacking runs would race on it.
6. PreviewFrameProcessor.swift:104 — per-frame CPU histogram on the video queue is a
   potential throughput bottleneck at sustained frame rates.

## Skipped

(none yet)

---

## Iteration 1 — Depth-map export ✅
Shipped: StackOutput{merged, depthMap?} protocol change; grayscale depth map from the
fallback stacker's bestIndex; C++ engine tmp-PNG pickup (stale file deleted pre-run);
depthmap.heic persisted + Result.depthMapFileName (Codable-optional); Depth toggle in
ReviewSheet + StackSetDetail (nil-safe fallback). Verification: 2 WARNs found, fixed in
retry 1/3, re-verified clean.

## Iteration 2 — Settings persistence ✅
Shipped: CaptureDefaults (UserDefaults-backed, unset-aware, AppConfig-clamped, shutter
whitelisted) + CameraViewModel init/load + persistence on lock, stepCount, and new
peakingEnabled (synced to preview processor). Verification: clean on first pass, 0 retries.
Note: peakingEnabled has no UI control yet — picked up in iteration 4.

## Iteration 3 — Unit test target + maintenance sweep ✅
Shipped: StackShotTests target + scheme in project.yml; 3 XCTest suites (bracket plan
spacing/endpoints, CaptureDefaults roundtrip/clamping with injectable UserDefaults,
StackSet Codable incl. legacy-manifest fixture). Sweep: 2 unused imports removed, 1 doc
drift fixed, 6 items logged as Technical Debt. Verification: clean, 0 retries. Tests are
desk-verified only — first `xcodebuild test` run happens on the user's Mac.

## Iteration 4 — Peaking control + gray-card white balance

**Plan (finalized):**
1. FocusPanel: add a "Peaking" toggle button (same `.toggleStyle(.button)` pattern as
   the loupe toggle) bound to the persisted vm.peakingEnabled added in iteration 2.
2. Gray-card WB: CameraService gains `func lockNeutralWhiteBalance() throws ->
   (kelvin: Float, tint: Float)`: reads `device.grayWorldDeviceWhiteBalanceGains`,
   clamps to maxWhiteBalanceGain, locks via setWhiteBalanceModeLocked, converts back
   with `device.temperatureAndTintValues(for:)` and returns them.
3. CameraViewModel: `func lockGrayCardWB()` calling the above, updating kelvin/tint
   published values (so sliders reflect reality) and persisting.
4. ExposurePanel: "Gray card" button beside the WB presets invoking it (with a short
   footnote-style caption "Fill frame with a neutral card, then tap").
5. Touch only FocusPanel.swift, ExposurePanel.swift, CameraService.swift,
   CameraViewModel.swift.

**Status:** planned → implementing
