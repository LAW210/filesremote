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

## Iteration 2 — Settings persistence ✅
Shipped: CaptureDefaults (UserDefaults-backed, unset-aware, AppConfig-clamped, shutter
whitelisted) + CameraViewModel init/load + persistence on lock, stepCount, and new
peakingEnabled (synced to preview processor). Verification: clean on first pass, 0 retries.
Note: peakingEnabled has no UI control yet — picked up in iteration 4.

## Iteration 3 — Unit test target + maintenance sweep (iteration % 3 == 0)

**Plan (finalized):**
1. Add `StackShotTests` unit-test target to project.yml (XcodeGen `type: bundle.unit-test`,
   depends on the app target).
2. New `Tests/` sources (pure logic, no camera hardware needed):
   - FocusBracketPlanTests: inclusive endpoints, even spacing, N=1/2/8 edge cases,
     reversed near>far, count matches stepCount.
   - CaptureDefaultsTests: load defaults when unset, roundtrip save/load, clamping of
     out-of-range persisted values, shutter whitelist fallback (use a cleared
     UserDefaults suite name to isolate — requires CaptureDefaults to accept an
     injectable UserDefaults instance, defaulting to .standard; this small seam IS in
     scope).
   - StackSetCodableTests: manifest roundtrip incl. nil/non-nil depthMapFileName and
     decoding a legacy JSON fixture without the field.
3. Maintenance sweep (passive, no business-logic changes): scan ios/StackShot for
   unused imports, typos in comments/strings, dead code, stale doc comments
   (e.g. StackingService doc still says "returns the updated set + image" — now
   output). Log anything non-trivial as Technical Debt instead of fixing.

**Status:** planned → implementing
