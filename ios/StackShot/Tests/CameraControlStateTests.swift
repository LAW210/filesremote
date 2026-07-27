import XCTest
@testable import StackShot

/// Covers every path where `CameraViewModel` state has to reach the device. All of it runs
/// against `FakeCamera`, so these are the paths that used to be reachable only by holding a
/// phone and looking at the viewfinder — which is how several of the bugs pinned here
/// shipped in the first place.
@MainActor
final class CameraControlStateTests: XCTestCase {

    // MARK: - Helpers

    /// Each call gets a defaults store of its own, so nothing here touches the settings of
    /// whatever app hosts the test bundle.
    private func makeViewModel(_ camera: FakeCamera) -> CameraViewModel {
        CameraViewModel(camera: camera, defaults: makeIsolatedDefaults())
    }

    /// Waits for `condition`, which is how the results of `selectLens()` and
    /// `lockExposure()` are observed: both do their device work inside a `Task` with no
    /// handle to await. Awaiting inside the loop releases the main actor so that task can
    /// run, and the poll returns the instant its work lands rather than after a fixed
    /// delay — the 1 ms sleep is the polling granularity, not a guess at how long the work
    /// takes. `FakeCamera` records calls synchronously inside that task, so once the
    /// condition holds, `calls` is already complete.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// The lens IDs from a call log, in order — lens switches are surrounded by the EV /
    /// white balance / focus pushes that follow them, so the switches themselves are only
    /// legible in isolation.
    private func selectedLensIDs(_ calls: [FakeCamera.Call]) -> [String] {
        calls.compactMap { (call: FakeCamera.Call) -> String? in
            guard case .select(let lensID) = call else { return nil }
            return lensID
        }
    }

    private func threeLenses() -> [LensInfo] {
        [LensInfo(id: "wide", name: "1x"),
         LensInfo(id: "ultra", name: "0.5x"),
         LensInfo(id: "tele", name: "Tele")]
    }

    // MARK: - White balance

    /// Regression guard: the Kelvin slider used to change nothing on the device until a
    /// later `lockExposure()` happened to apply it, so you could not see the colour you
    /// were choosing.
    func testChangingKelvinPushesItToTheDevice() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.reset()

        vm.kelvin = 4300

        // Tint is always neutral now: AVFoundation's pair needs a value, but green/magenta
        // correction is not a control any more.
        XCTAssertEqual(fake.calls, [.setWhiteBalance(kelvin: 4300, tint: 0)])
        XCTAssertEqual(fake.whiteBalance?.kelvin, 4300)
        XCTAssertEqual(fake.whiteBalance?.tint, 0)
    }

    // MARK: - Gray card

    /// The measured gains are what the device keeps. Reflecting the equivalent Kelvin
    /// into the slider must not push it back out — that would re-derive gains from
    /// round-tripped numbers and throw away the measurement the card was held up for.
    func testGrayCardLockDoesNotPushTheSliderValueBackOverTheMeasurement() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.neutralWhiteBalanceResult = (kelvin: 4870, tint: 7)

        vm.lockGrayCardWB()

        XCTAssertEqual(fake.calls, [.lockNeutralWhiteBalance])
        XCTAssertEqual(vm.kelvin, 4870)
        // The device keeps the measured gains, tint component included — that is the point
        // of measuring. Only the slider-visible Kelvin comes back.
        XCTAssertEqual(fake.whiteBalance?.kelvin, 4870)
        XCTAssertEqual(fake.whiteBalance?.tint, 7)
    }

    /// A card reading outside the slider's range shows the nearest representable value
    /// while the device holds the real one — so the clamp must land in the UI only, and
    /// must still not be pushed back.
    func testGrayCardLockClampsTheSliderButLeavesTheDeviceOnTheMeasuredValues() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.neutralWhiteBalanceResult = (kelvin: 9200, tint: -80)

        vm.lockGrayCardWB()

        XCTAssertEqual(vm.kelvin, AppConfig.Exposure.kelvinRange.upperBound)
        XCTAssertEqual(fake.whiteBalance?.kelvin, 9200)
        XCTAssertEqual(fake.whiteBalance?.tint, -80)
        XCTAssertEqual(fake.calls, [.lockNeutralWhiteBalance])
    }

    /// The panel reports whether neutral has been measured, so the owner can tell by
    /// looking rather than remembering — the order (measure before raising EV) matters and
    /// getting it wrong fails silently.
    func testNeutralMeasuredFlagTracksTheMeasurement() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        XCTAssertFalse(vm.neutralMeasured)

        vm.lockGrayCardWB()

        XCTAssertTrue(vm.neutralMeasured)
    }

    /// A failed measurement must not claim to have happened.
    func testFailedMeasurementLeavesNeutralUnmeasured() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("lockNeutralWhiteBalance", with: CameraError.configurationFailed)

        vm.lockGrayCardWB()

        XCTAssertFalse(vm.neutralMeasured)
    }

    /// Switching lenses drops it alongside the measured tint: the measurement belongs to
    /// the module it was taken on.
    func testSwitchingLensClearsTheNeutralMeasuredFlag() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "wide"
        vm.lockGrayCardWB()
        XCTAssertTrue(vm.neutralMeasured)

        vm.cycleLens()
        await waitUntil("the lens switch to reach the device") {
            fake.calls.contains { if case .select = $0 { return true } else { return false } }
        }

        XCTAssertFalse(vm.neutralMeasured)
    }

    /// The measured green/magenta component is carried forward, not discarded.
    ///
    /// Tint is not a control, but the card measurement finds a real one — a cheap LED
    /// panel commonly has a green spike that Kelvin cannot correct at any setting. If the
    /// measurement were dropped, nudging Kelvin after measuring would silently reset that
    /// axis to neutral and put the cast back.
    func testKelvinChangeAfterAGrayCardLockKeepsTheMeasuredTint() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.neutralWhiteBalanceResult = (kelvin: 4800, tint: 9)
        vm.lockGrayCardWB()
        fake.reset()

        vm.kelvin = 5200

        XCTAssertEqual(fake.calls, [.setWhiteBalance(kelvin: 5200, tint: 9)])
    }

    /// A measurement belongs to the module it was taken on, so switching lenses drops it
    /// rather than applying one camera's cast to another's.
    func testSwitchingLensClearsTheMeasuredTint() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "wide"
        fake.neutralWhiteBalanceResult = (kelvin: 4800, tint: 9)
        vm.lockGrayCardWB()

        vm.cycleLens()
        await waitUntil("the lens switch to reach the device") {
            fake.calls.contains { if case .select = $0 { return true } else { return false } }
        }
        fake.reset()
        vm.kelvin = 5000

        XCTAssertEqual(fake.calls, [.setWhiteBalance(kelvin: 5000, tint: 0)])
    }

    /// The suppression must be released, not just applied.
    ///
    /// `withWhiteBalancePushSuppressed` relies on a `defer` to clear the flag. Delete that
    /// `defer` and every other test still passes, because the gray-card tests are the last
    /// thing their tests do — while in the app the Kelvin slider would silently stop
    /// reaching the device for the rest of the session, which is the exact bug the push
    /// was added to fix.
    func testWhiteBalancePushResumesAfterAGrayCardLock() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.neutralWhiteBalanceResult = (kelvin: 4600, tint: 3)
        vm.lockGrayCardWB()
        fake.reset()

        vm.kelvin = 4200

        XCTAssertEqual(fake.calls, [.setWhiteBalance(kelvin: 4200, tint: 3)])
    }

    /// And released even when the measurement fails, since the flag is set around the
    /// assignment either way.
    func testWhiteBalancePushResumesAfterAFailedGrayCardLock() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("lockNeutralWhiteBalance", with: CameraError.configurationFailed)
        vm.lockGrayCardWB()
        fake.reset()

        vm.kelvin = 3900

        XCTAssertEqual(fake.calls, [.setWhiteBalance(kelvin: 3900, tint: 0)])
    }

    func testGrayCardLockFailureIsReportedAndLeavesTheSliderAlone() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        let before = vm.kelvin
        fake.fail("lockNeutralWhiteBalance", with: CameraError.configurationFailed)

        vm.lockGrayCardWB()

        XCTAssertEqual(vm.kelvin, before)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Exposure bias

    func testChangingEVBiasPushesItToTheDevice() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.reset()

        vm.evBias = 1.5

        XCTAssertEqual(fake.calls, [.setExposureBias(1.5)])
        XCTAssertEqual(fake.exposureBias, 1.5)
    }

    /// While exposure is locked the EV slider must not reach the device: the whole point of
    /// the lock is that every frame in the bracket meters identically.
    func testChangingEVBiasWhileExposureIsLockedPushesNothing() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.exposureLocked = true
        fake.reset()

        vm.evBias = 2

        XCTAssertEqual(fake.calls, [])
        XCTAssertNil(fake.exposureBias)
    }

    /// Unlocking has to re-assert the slider's value, since the device is still holding
    /// whatever it was locked at.
    func testUnlockingExposureReappliesTheCurrentEVBias() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.evBias = 1
        vm.exposureLocked = true
        fake.reset()

        vm.unlockExposure()

        XCTAssertFalse(vm.exposureLocked)
        XCTAssertEqual(fake.calls, [.setExposureBias(1)])
    }

    // MARK: - Focus

    func testChangingLensPositionPushesFocusToTheDevice() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.reset()

        vm.lensPosition = 0.3

        XCTAssertEqual(fake.calls, [.setFocus(lensPosition: 0.3)])
        XCTAssertEqual(fake.focusPosition, 0.3)
    }

    // MARK: - Lock sequence

    /// Order is the whole contract here: settling before the lock is what makes the locked
    /// values correct, and re-applying colour *after* the lock is what stops the device's
    /// own white balance decision from surviving it. The end state cannot tell these apart,
    /// so this asserts against the call log.
    func testLockExposureSettlesThenLocksThenReappliesWhiteBalance() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.kelvin = 3200
        fake.reset()

        vm.lockExposure()
        await waitUntil("the exposure lock to finish") { vm.exposureLocked }

        XCTAssertEqual(fake.calls, [
            .waitForExposureSettle(timeout: 1.5),
            .lockExposure,
            .setWhiteBalance(kelvin: 3200, tint: 0),
        ])
    }

    /// A throw partway through must not leave the UI claiming a lock that the device does
    /// not have — the shutter is gated on this flag.
    func testLockExposureFailingPartwayLeavesExposureUnlocked() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("lockExposure", with: CameraError.configurationFailed)
        fake.reset()

        vm.lockExposure()
        await waitUntil("the lock failure to be reported") { vm.errorMessage != nil }

        XCTAssertFalse(vm.exposureLocked)
        XCTAssertEqual(fake.calls, [.waitForExposureSettle(timeout: 1.5), .lockExposure])
    }

    /// The same applies when the failure lands on the trailing white balance push: the
    /// frames would then be shot under a colour nobody chose, so the lock does not stand.
    func testLockExposureFailingOnWhiteBalanceLeavesExposureUnlocked() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("setWhiteBalance", with: CameraError.configurationFailed)
        fake.reset()

        vm.lockExposure()
        await waitUntil("the lock failure to be reported") { vm.errorMessage != nil }

        XCTAssertFalse(vm.exposureLocked)
    }

    // MARK: - Lens cycling

    /// Two quick taps must advance two lenses. They used to advance one: the next lens was
    /// derived from `selectedLensID`, which stayed stale until the hardware switch returned,
    /// so both taps computed the same target. The fix claims the lens synchronously.
    ///
    /// The lens list is assigned directly rather than via `start()`, so this test exercises
    /// only the cycling path and needs no preview/screen setup.
    func testCyclingTwiceAdvancesTwoLenses() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "wide"
        fake.reset()

        vm.cycleLens()
        vm.cycleLens()

        // Claimed immediately — this is the property the second tap reads.
        XCTAssertEqual(vm.selectedLensID, "tele")
        await waitUntil("both lens switches to reach the device") {
            selectedLensIDs(fake.calls).count == 2
        }
        XCTAssertEqual(selectedLensIDs(fake.calls), ["ultra", "tele"])
    }

    /// Cycling past the end wraps, so the button never dead-ends.
    func testCyclingWrapsAroundToTheFirstLens() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "tele"
        fake.reset()

        vm.cycleLens()
        await waitUntil("the lens switch to reach the device") {
            !selectedLensIDs(fake.calls).isEmpty
        }

        XCTAssertEqual(vm.selectedLensID, "wide")
        XCTAssertEqual(selectedLensIDs(fake.calls), ["wide"])
    }

    /// The optimistic claim has to be undone when the switch fails, or the button label and
    /// the next tap's arithmetic both describe a lens that was never attached.
    func testFailedLensSwitchRestoresThePreviousSelection() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "wide"
        fake.fail("select", with: CameraError.configurationFailed)
        fake.reset()

        vm.cycleLens()
        XCTAssertEqual(vm.selectedLensID, "ultra")      // claimed before the await
        await waitUntil("the failed switch to be reported") { vm.errorMessage != nil }

        XCTAssertEqual(vm.selectedLensID, "wide")
    }

    /// A new module means new metering, new colour, and a lens sitting on continuous AF, so
    /// everything manual has to be re-pushed and everything device-bound has to be dropped.
    /// `lensPosition` doesn't change across the switch, so its `didSet` won't fire — the
    /// explicit `setFocus` is the only thing that keeps the slider honest.
    func testSuccessfulLensSwitchResetsDeviceStateAndRepushesTheManualControls() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = threeLenses()
        vm.selectedLensID = "wide"
        vm.evBias = 1
        vm.kelvin = 4000
        vm.lensPosition = 0.8
        vm.nearAnchor = 0.2
        vm.farAnchor = 0.9
        vm.setTorch(true)
        vm.exposureLocked = true
        fake.reset()

        vm.cycleLens()
        await waitUntil("the lens switch to finish") {
            fake.calls.contains(.setFocus(lensPosition: 0.8))
        }

        XCTAssertFalse(vm.exposureLocked)
        XCTAssertNil(vm.nearAnchor)
        XCTAssertNil(vm.farAnchor)
        XCTAssertFalse(vm.torchEnabled)
        XCTAssertEqual(fake.calls, [
            .select(lensID: "ultra"),
            .setExposureBias(1),
            .setWhiteBalance(kelvin: 4000, tint: 0),
            .setFocus(lensPosition: 0.8),
        ])
        XCTAssertEqual(fake.exposureBias, 1)
        XCTAssertEqual(fake.whiteBalance?.kelvin, 4000)
        XCTAssertEqual(fake.focusPosition, 0.8)
    }

    /// One lens is not a choice; the button must not thrash the device.
    func testCyclingWithASingleLensDoesNothing() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.lenses = [LensInfo(id: "wide", name: "1x")]
        vm.selectedLensID = "wide"
        fake.reset()

        vm.cycleLens()

        XCTAssertEqual(fake.calls, [])
        XCTAssertEqual(vm.selectedLensID, "wide")
    }

    // MARK: - Torch

    func testTorchOnReachesTheDeviceAndSetsTheFlag() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.reset()

        vm.setTorch(true)

        XCTAssertTrue(vm.torchEnabled)
        XCTAssertTrue(fake.torchOn)
        XCTAssertEqual(fake.calls, [.setTorch(enabled: true)])
    }

    /// A failed switch-*off* must leave the flag true, because the torch is still lit.
    /// Forcing it to false was right for a failed switch-on and wrong here: the icon
    /// claimed the torch was out while it was burning into the frame.
    func testFailedTorchSwitchOffLeavesTheFlagTrueBecauseTheTorchIsStillLit() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        vm.setTorch(true)
        fake.fail("setTorch", with: CameraError.torchUnavailable)

        vm.setTorch(false)

        XCTAssertTrue(vm.torchEnabled)
        XCTAssertTrue(fake.torchOn)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testFailedTorchSwitchOnLeavesTheFlagFalse() {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("setTorch", with: CameraError.torchUnavailable)

        vm.setTorch(true)

        XCTAssertFalse(vm.torchEnabled)
        XCTAssertFalse(fake.torchOn)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Carried-over anchors

    /// Anchors survive a capture so the same reel can be re-shot, but they are the
    /// previous subject's positions until re-set — and a swapped reel shot on stale
    /// anchors would look like the focus sweep misbehaving.
    func testMarkingAnAnchorClearsTheCarriedOverFlag() {
        let vm = makeViewModel(FakeCamera())
        vm.nearAnchor = 0.2
        vm.farAnchor = 0.8

        vm.markNear()

        XCTAssertFalse(vm.anchorsFromPreviousCapture)
    }

    func testMarkingFarAlsoClearsTheCarriedOverFlag() {
        let vm = makeViewModel(FakeCamera())

        vm.markFar()

        XCTAssertFalse(vm.anchorsFromPreviousCapture)
        XCTAssertEqual(vm.farAnchor, vm.lensPosition)
    }

    // MARK: - Loupe magnification

    /// Magnification is one stored value, mirrored into the frame processor. It used to be
    /// duplicated as `@State` in the loupe view, which reset to 3x whenever the loupe was
    /// hidden and shown while the processor kept the pinched value — so the label read
    /// "3.0x" over a crop rendered at 6x.
    func testSteppingLoupeMagnificationMovesByTheStep() {
        let vm = makeViewModel(FakeCamera())
        let start = vm.loupeMagnification

        vm.stepLoupeMagnification(by: 0.5)

        XCTAssertEqual(vm.loupeMagnification, start + 0.5)
    }

    func testLoupeMagnificationClampsToItsRange() {
        let vm = makeViewModel(FakeCamera())
        let range = AppConfig.Loupe.magnificationRange

        for _ in 0..<40 { vm.stepLoupeMagnification(by: 0.5) }
        XCTAssertEqual(vm.loupeMagnification, range.upperBound)

        for _ in 0..<40 { vm.stepLoupeMagnification(by: -0.5) }
        XCTAssertEqual(vm.loupeMagnification, range.lowerBound)
    }

    /// Stepping has to move the pinch base too, or a later pinch would multiply from a
    /// magnification the loupe is no longer showing.
    func testSteppingRebasesTheGestureSoAPinchCompoundsFromWhereItIs() {
        let vm = makeViewModel(FakeCamera())
        vm.stepLoupeMagnification(by: 1)          // 3 -> 4
        let stepped = vm.loupeMagnification

        vm.scaleLoupe(by: 1)                      // a pinch that changes nothing

        XCTAssertEqual(vm.loupeMagnification, stepped)
    }

    /// Hiding and re-showing the loupe must not reset the zoom, which is the bug the
    /// single stored value exists to prevent.
    func testLoupeMagnificationSurvivesHidingAndShowing() {
        let vm = makeViewModel(FakeCamera())
        vm.setLoupe(visible: true)
        vm.stepLoupeMagnification(by: 1.5)
        let chosen = vm.loupeMagnification

        vm.setLoupe(visible: false)
        vm.setLoupe(visible: true)

        XCTAssertEqual(vm.loupeMagnification, chosen)
    }

    // MARK: - Startup

    /// Both persisted manual settings have to reach the device on launch, or the viewfinder
    /// opens on the camera's own guess while the panel shows last session's numbers.
    func testStartPushesThePersistedExposureBiasAndWhiteBalance() async {
        // Seeded in this test's own store, which is discarded at teardown. Written through
        // the `Key` constants `CaptureDefaults.load` reads, so a renamed key cannot leave
        // this test silently seeding nothing.
        let defaults = makeIsolatedDefaults()
        defaults.set(Float(1.5), forKey: CaptureDefaults.Key.evBias)
        defaults.set(Float(3200), forKey: CaptureDefaults.Key.kelvin)

        let fake = FakeCamera()
        fake.lenses = threeLenses()
        fake.currentLens = fake.lenses.first
        let vm = CameraViewModel(camera: fake, defaults: defaults)

        await vm.start()

        XCTAssertEqual(vm.evBias, 1.5)
        XCTAssertEqual(vm.kelvin, 3200)
        XCTAssertEqual(vm.selectedLensID, "wide")
        // Focus is pushed here too: a freshly attached device defaults to continuous AF,
        // so without it the slider would read its default while the lens did something
        // else. `resumeSession()` always did this; `start()` used to not, and the two
        // startup paths disagreeing is what made the gap easy to miss.
        XCTAssertEqual(fake.calls, [
            .configure,
            .start,
            .setExposureBias(1.5),
            .setWhiteBalance(kelvin: 3200, tint: 0),
            .setFocus(lensPosition: vm.lensPosition),
        ])
        XCTAssertEqual(fake.exposureBias, 1.5)
        XCTAssertEqual(fake.whiteBalance?.kelvin, 3200)
    }

    /// A failed `configure()` must not go on to push controls at a camera that isn't there.
    func testStartReportsConfigureFailureAndPushesNothing() async {
        let fake = FakeCamera()
        let vm = makeViewModel(fake)
        fake.fail("configure", with: CameraError.noCamera)

        await vm.start()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(fake.calls, [.configure])
    }
}
