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

(none yet)

## Skipped

(none yet)

---

## Iteration 1 — Depth-map export ✅
Shipped: StackOutput{merged, depthMap?} protocol change; grayscale depth map from the
fallback stacker's bestIndex; C++ engine tmp-PNG pickup (stale file deleted pre-run);
depthmap.heic persisted + Result.depthMapFileName (Codable-optional); Depth toggle in
ReviewSheet + StackSetDetail (nil-safe fallback). Verification: 2 WARNs found, fixed in
retry 1/3, re-verified clean.

## Iteration 2 — Settings persistence

**Plan (finalized):**
1. New `Sources/Support/CaptureDefaults.swift`: a small struct backed by UserDefaults
   (suite default) persisting: iso, shutterDenominator, kelvin, tint, stepCount,
   peaking on/off. Static load()/save() with AppConfig-clamped values on load
   (guard against out-of-range persisted values after config changes).
2. `CameraViewModel`: load persisted values in init (replacing the hardcoded 100 /
   60 / 5000 / 0 / default step count); save on applyAndLockExposure() and on
   stepCount change (didSet). Do NOT persist focus anchors or lens (hardware-session
   specific).
3. No other files touched; no refactors.

**Status:** planned → implementing
