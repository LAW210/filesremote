# StackShot improvement loop — state

- Session UUID: f6b423de-fdf5-4ca9-a24b-797c1b2bf474
- Target codebase: `ios/StackShot/`
- Iterations: 6 total · Current: 6 — TERMINATED (all iterations complete)
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
2. ~~FocusBracketController orphaned frames on failure~~ — RESOLVED in iteration 5.
3. ~~StackStore.loadAll silent corrupt manifests~~ — RESOLVED in iteration 5.
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

## Iteration 4 — Peaking control + gray-card white balance ✅
Shipped: Peaking toggle in FocusPanel (bound to persisted setting from iter 2, closing
that gap); CameraService.lockNeutralWhiteBalance() (gray-world gains → clamp → lock →
Kelvin/tint readback); Gray card button + hint in ExposurePanel with sliders synced to
the measured values. Verification: clean, 0 retries.

## Iteration 5 — Cancel-safe cleanup + surfaced manifest errors ✅
Shipped: partial StackSet directories deleted on any bracket failure/cancel
(completed-flag + defer); loadAll now reports corrupt-manifest count; Library shows an
orange warning row when stacks can't be read. Debt items 2 & 3 resolved.
Verification: clean, 0 retries.

## Iteration 6 (final) — Permission errors, docs sync + maintenance sweep ✅
Shipped: CameraError.permissionRestricted with distinct .restricted/.denied handling
(debt item 4 resolved); README synced to all loop-shipped features + "Running tests"
section. Sweep #2: zero findings. Verification: 1 WARN (README wording overpromised the
corrupt-stack check), fixed in retry 1/3.

---

# FINAL SUMMARY (loop terminated after 6/6 iterations)

**Shipped:** depth-map export + view toggle (both engines); persisted capture settings
(CaptureDefaults, clamped); StackShotTests target + 3 XCTest suites; peaking on/off
control; one-tap gray-card white balance; cancel-safe bracket cleanup; corrupt-manifest
warning in Library; restricted-vs-denied camera permission errors; 2 maintenance sweeps
(unused imports, doc drift); README synced.

**Technical debt (open):** fallback stacker has no frame alignment (by design — C++
engine supplies ECC); C++ engine depth-map tmp path races under concurrent stacking;
per-frame CPU histogram on the video queue is a potential throughput bottleneck.
Resolved during loop: orphaned-frames cleanup (iter 5), silent corrupt manifests
(iter 5), permission-state collapse (iter 6).

**Skipped:** none — no iteration hit retry exhaustion, ambiguity, or high-risk changes,
so the pause conditions were never triggered. Substitutions (declared up front): the
macOS-local planning skill was replaced by inline planning; "5.6 Sol/Terra" agents ran
as Sonnet at medium effort; verification was static analysis, since no Swift toolchain
exists in this container — tests execute for the first time on the user's Mac.
