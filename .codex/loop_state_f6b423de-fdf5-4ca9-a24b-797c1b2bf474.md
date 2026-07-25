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

## Iteration 4 — Peaking control + gray-card white balance ✅
Shipped: Peaking toggle in FocusPanel (bound to persisted setting from iter 2, closing
that gap); CameraService.lockNeutralWhiteBalance() (gray-world gains → clamp → lock →
Kelvin/tint readback); Gray card button + hint in ExposurePanel with sliders synced to
the measured values. Verification: clean, 0 retries.

## Iteration 5 — Cancel-safe cleanup + surfaced manifest errors (debt items 2 & 3)

**Plan (finalized):**
1. FocusBracketController.run: wrap the capture loop so that on ANY throw (including
   cancellation) the partially written StackSet directory is deleted before rethrow
   (frames captured so far are useless without the full bracket). Use a success flag +
   defer, or do/catch → removeItem → rethrow. Manifest is only written on full success
   (already true — keep it that way).
2. StackStore.loadAll: return manifests that decode, but count failures; change the
   signature to `loadAll() -> (sets: [StackSet], corruptCount: Int)` OR keep the
   signature and add `corruptManifestCount()` — choose the tuple; update the single
   call site (LibraryScreen) to show a footnote row "N stack(s) could not be read"
   when corruptCount > 0.
3. Touch only FocusBracketController.swift, StackSet.swift (StackStore), and
   LibraryScreen.swift.

**Status:** planned → implementing
