# StackShot — first device session

A protocol for the first time the app runs on a phone. Everything in the codebase so far
was written without a device: CI proves it compiles and that the pure logic is correct,
but **no focus sweep, no peaking overlay, and no stacked image has ever been seen**. This
session is not about getting a good photo of a reel. It is about finding out which of the
untested assumptions are wrong, in an order that makes each failure attributable.

Budget about an hour. Shoot **one reel, repeatedly**, changing one thing at a time.

---

## 0. Before you touch the light box

### Build and install

```bash
brew install xcodegen
cd ios/StackShot
xcodegen generate
open StackShot.xcodeproj
```

Set your signing team, select your iPhone (not a Simulator), run.

If the viewfinder shows a red **`PREVIEW · no camera`** badge, you are on the Simulator and
the frames are synthetic. Nothing in this document applies — switch to the device.

### Two things to know before you judge the output

1. **The C++ engine is not switched on.** `ENGINE_EMBEDDED` is commented out in
   `project.yml`, so what runs is the Swift fallback stacker. It is genuinely Method-B in
   shape — per-pixel sharpest source, plus a depth map — but it **downscales every frame to
   2048 px on the long edge and performs no alignment between frames.** Expect a
   ~2048 px result, not a 48 MP one, and expect any frame-to-frame shift to show as
   doubling rather than being corrected. Neither is a bug in this session. Resolution and
   alignment both arrive with the C++ engine.
2. **Source frames are deleted** once the stacked image is safely written. A bad stack
   cannot be re-stacked from its frames — they're gone. If a run produces something you
   want to investigate rather than repeat, say so before shooting again; keeping frames is
   a one-line change to make deliberately, not something to discover you needed.

### Rig

Phone on the tripod, camera lens pointing down at the reel, reel on the light box floor.
Tighten everything. The bracket takes several seconds and every frame must share a
viewpoint — the fallback stacker cannot correct for drift, so a loose ball head shows up
as a soft, doubled stack that looks like an algorithm failure and isn't.

Turn the light box on and leave it. Room lights off if you can; mixed sources make the
white balance step meaningless.

---

## 1. Lens — does it even focus close enough?

The app auto-selects the **closest-focusing** back camera at launch, which on modern
iPhones is the ultra-wide (it's the macro lens). The lens button top-left cycles them.

**Do:** frame the reel to fill the frame. Turn on **1:1 crop guide** in Settings if you're
shooting for eBay thumbnails, and frame inside the bright square.

**Check:**
- Which lens name is showing? Note it.
- Drag the focus slider end to end. Does the image visibly rack from blurred to sharp and
  back? If it never comes to focus at your working distance, back the tripod off and retry.
- Cycle to the other lenses. One of them should focus noticeably closer than the others.
  **If the lens the app picked is not the one that focuses closest, that's the first real
  finding of the session** — the auto-selection logic is untested and this is the check
  that tests it.

**Stop here if:** the viewfinder is black, sideways, or stretched. Rotation was set blind
(`videoRotationAngle = 90` on both connections) and has never been seen. Note which of the
three it is and which lens was selected — those distinguish the causes.

---

## 2. Exposure — one number, then lock

Tap **Exposure** on the panel-swap button.

**Do:**
1. Watch the **histogram** at the top of the panel. In a light box the backdrop pegs the
   right end — that is expected and is exactly why the histogram alone can't tell you the
   *reel* is correctly exposed.
2. Raise **EV** until the reel itself looks right. It's positive-only by design: a light
   box is mostly white field, the meter reads that as overexposure, and the correction is
   always upward. Somewhere in the +0.7 to +2.0 range is the likely landing zone. Write
   down what you end on.
3. Turn on **zebra** (the ⚠ icon, top right). Red areas are blown and unrecoverable in an
   edit. Chrome and polished nickel clip readily. Back the EV down until the zebra is off
   the parts of the reel you care about — a blown backdrop is fine and expected.
4. Set white balance: try the **LED 5000K** preset, then the **Gray card** button with a
   neutral card filling the frame. Compare. Note which gave a neutral reel.
5. Tap **Lock exposure**. The chip at the top should switch from orange `Live` to green
   `Locked`.

**Check:**
- Does the preview visibly change as you move the EV slider? If not, `setExposureBias` is
  not reaching the device.
- After locking, does the preview stay put when you wave a hand near the box? It should be
  frozen. If brightness still wanders, the lock isn't taking, and **every stack this
  session will band** — that's the single most important thing to catch here.
- Does the Kelvin slider visibly warm and cool the image?

---

## 3. Focus anchors — the part that matters most

Tap **Focus**. This is where the session's real work happens.

**Do:**
1. Turn on the **3× loupe**. It magnifies the centre by default; **tap anywhere on the
   viewfinder to move the sample point** — a yellow reticle marks what it's showing, and
   the loupe hops to the opposite side so it never covers the thing it's magnifying.
   Pinch it for 2×–6×.
2. Tap the **nearest** part of the reel (the foot, or the closest rim edge). Drag the
   focus slider — or press-and-hold the ± buttons for ±0.005 nudges — until *that* point is
   critically sharp in the loupe, not merely acceptable in the full preview.
3. Tap **Set Near**. The button turns green and shows a lens value.
4. Tap the **furthest** part (the far rim, or the back of the spool). Refocus on it the
   same way. Tap **Set Far**.
5. Look at the strip beneath: a cyan tick is your current focus, green dots are the
   anchors, and the yellow dots are the planned focus planes.

**Check:**
- Do the ± nudge buttons produce a *visible* change in the loupe? If ±0.005 does nothing
  perceptible, the step is too coarse for macro work and needs shrinking — a real finding.
- Are the near and far lens values meaningfully different? If the whole reel racks between
  0.81 and 0.83, the usable range is tiny and the frame count matters much less than
  expected.
- Do the yellow planned dots span the gap evenly? They should, by construction.
- Turn **peaking** on and off. Does the green edge overlay track what's actually sharp? It
  is the fastest way to judge focus, but it has never been seen working.

**If the shutter is grey**, the caption underneath names exactly what's missing — lock
exposure, set an anchor, or make the two anchors differ.

---

## 4. First capture — 8 frames

Leave the frame count at **8**.

**Do:** press the shutter, then take your hands off the tripod. A 2-second timer runs
first specifically to let button-press shake die down. You'll hear a tick per frame and a
chime at the end. There is deliberately **no haptic feedback** — vibration would shake the
rig during the frames that need stillness.

**Check while it runs:**
- Does the frame counter advance steadily, or stall on one frame? Stalling means the focus
  settle-wait is timing out.
- Does the preview visibly rack focus between frames? It should step near→far.

**Check the result:**
- The review sheet appears when stacking finishes. Is the whole reel sharp front to back?
- Toggle the **depth map**. It shows which source frame won each pixel. A clean stack is a
  smooth gradient following the reel's depth. **Speckle and noise mean the sharpness
  metric is struggling** — usually too few frames or too little contrast. Blotchy uniform
  regions where two frames disagree at random are the signature of a shift between frames.
- Doubled or ghosted edges mean the rig moved. Retighten and repeat before concluding
  anything about the algorithm.

---

## 5. Then vary exactly one thing

In this order, so each result is attributable:

1. **Same anchors, 16 frames.** Does the depth map get cleaner and the soft band go away?
   If yes, 8 is simply too few for this reel and the default should rise. This is the most
   likely finding of the whole session.
2. **Same anchors, 4 frames.** Where does it visibly break? That establishes the floor.
3. **A different lens** at the count that worked. More reach vs. closer focus — which
   actually renders the reel better?
4. **PNG output** (Settings) on one keeper, if you intend to edit before listing. JPEG →
   edit → re-export is two lossy generations; PNG makes your editor's export the only one.

---

## 6. What to read when something looks wrong

**The capture log.** Every StackSet folder carries a `capture-log.txt` recording the whole
run from shutter to stacked file. Get it from **Library → tap the stack → the log's share
button**. It contains, per frame:

```
frame 3/8: target=0.6143 actual=0.6140 settle=ok attempts=1 file=frame_02.dng RAW elapsed=0.412s
```

Read it like this:

| What you see | What it means |
|---|---|
| `settle=timeout` | The lens never reached the target in time — that frame is focused somewhere other than planned, and will show as a gap in the depth map. |
| `target` and `actual` far apart | The device is clamping the requested lens position; the usable range is narrower than 0–1. |
| `attempts=2` | A capture failed once and was retried. Occasional is fine; every frame is not. |
| `HEIF` where you expected `RAW` | The device declined RAW for this configuration. |
| `elapsed` climbing per frame | Something is accumulating — worth reporting. |
| `outcome: cancelled` / `outcome: error:` | The bracket didn't complete. The message says why. |
| A `stack:` line at the end | Engine name, duration, output format and byte count. Confirms which engine actually ran. |

Note the log survives only for brackets that **completed** — a failed bracket deletes its
whole directory, log included. If a run fails, the on-screen error message is the only
record, so write it down verbatim.

---

## 7. What to send back

Small and specific beats comprehensive:

1. **The capture log** from your best run and your worst run.
2. **The stacked JPEG and its depth map** for both (the depth map is the diagnostic; the
   JPEG alone rarely says why).
3. **Answers to the four questions this session exists to settle:**
   - Which lens did the app pick, and was it the one that focuses closest?
   - Did the exposure lock actually hold?
   - Did 8 frames cover the reel, and did 16 fix what 8 missed?
   - Did the ±0.005 focus nudge produce a visible change in the loupe?
4. **Anything that looked wrong on screen** — a sideways preview, peaking that highlighted
   the wrong things, a loupe showing the wrong region, a control that did nothing. These
   are all first-sighting surfaces and any of them could be subtly wrong.
5. **The EV, Kelvin, and frame count you settled on.** That's the start of a repeatable
   recipe, which is what turns this from an experiment into a workflow.

Expect the first session to produce a list of fixes, not a listing photo. That's the
session working as intended.
