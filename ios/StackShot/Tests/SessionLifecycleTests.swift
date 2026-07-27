import SwiftUI
import XCTest
@testable import StackShot

/// App-lifecycle behaviour: `CameraViewModel.handleScenePhase(_:)` and the
/// `resumeSession()` it schedules. Backgrounding and resuming is where the state the UI
/// claims to own (torch, exposure lock, white balance, focus) can silently diverge from
/// the hardware, so these assertions are mostly about *order* and about what must NOT
/// happen.
///
/// Everything here runs against `FakeCamera`; the part of `CameraService`'s contract
/// that is reachable without a camera is pinned at the bottom of the file.
@MainActor
final class SessionLifecycleTests: XCTestCase {

    // MARK: - Fixtures

    private static let backLens = LensInfo(id: "back.1x", name: "1x")

    /// A view model whose camera is already "configured" as far as
    /// `handleScenePhase(.active)` is concerned — i.e. it has lenses. Set up by
    /// assignment rather than by `start()` so these tests never depend on `UIScreen`,
    /// which `start()` reads via `syncPreviewSettings()`.
    private func makeConfiguredViewModel() -> (CameraViewModel, FakeCamera) {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        fake.lenses = [Self.backLens]
        fake.currentLens = Self.backLens
        let vm = CameraViewModel(camera: fake)
        vm.lenses = fake.lenses
        vm.selectedLensID = Self.backLens.id
        return (vm, fake)
    }

    /// Waits for `condition`, failing the test if it never holds.
    ///
    /// The failure matters. An earlier version silently gave up after N yields, which is
    /// fine ahead of a positive assertion — the assertion fails instead — but turns every
    /// *negative* one ("no error was reported", "lockExposure was not called") into a
    /// free pass, because not-yet-happened and never-happens look identical. Some of the
    /// work also runs off the main actor, so cooperative yields alone do not guarantee it
    /// was even scheduled.
    private func settle(_ description: String = "the expected calls",
                        timeout: TimeInterval = 5,
                        file: StaticString = #filePath,
                        line: UInt = #line,
                        until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Yields the main actor a bounded number of times without asserting anything, for
    /// the cases that are checking something did NOT happen and so have no condition to
    /// wait on. Deliberately separate from `settle` so a missing condition can't quietly
    /// become a passing negative test.
    private func drain(turns: Int = 200) async {
        for _ in 0..<turns { await Task.yield() }
    }

    /// Pattern-matches rather than comparing, so this doesn't rely on `CameraError`
    /// picking up an `Equatable` conformance it never declares.
    private func assertNoCamera(_ error: Error,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        if let cameraError = error as? CameraError, case .noCamera = cameraError { return }
        XCTFail("expected CameraError.noCamera, got \(error)", file: file, line: line)
    }

    /// The full sequence `resumeSession()` performs when exposure is locked.
    private func lockedResumeCalls(_ vm: CameraViewModel) -> [FakeCamera.Call] {
        [
            .start,
            .setExposureBias(vm.evBias),
            .waitForExposureSettle(timeout: 1.5),
            .lockExposure,
            .setWhiteBalance(kelvin: vm.kelvin, tint: 0),
            .setFocus(lensPosition: vm.lensPosition)
        ]
    }

    // MARK: - Background

    /// Stopping the session extinguishes the torch in hardware, so the flag has to
    /// follow it down or the icon claims a light that is already out.
    func testBackgroundStopsTheSessionAndClearsTheTorchFlag() {
        let (vm, fake) = makeConfiguredViewModel()
        vm.setTorch(true)
        XCTAssertTrue(vm.torchEnabled)
        fake.reset()

        vm.handleScenePhase(.background)

        XCTAssertFalse(vm.torchEnabled)
        // Exactly `stop`, and nothing else: no `setTorch(false)` is pushed, because the
        // hardware has already dropped the torch as the session went down.
        XCTAssertEqual(fake.calls, [.stop])
        XCTAssertNil(vm.errorMessage)
    }

    /// Backgrounding with the torch already off must not invent a state change.
    func testBackgroundWithTorchOffOnlyStopsTheSession() {
        let (vm, fake) = makeConfiguredViewModel()
        XCTAssertFalse(vm.torchEnabled)

        vm.handleScenePhase(.background)

        XCTAssertEqual(fake.calls, [.stop])
        XCTAssertFalse(vm.torchEnabled)
    }

    /// Backgrounding must not disturb the metered setup — only resuming re-applies it.
    func testBackgroundLeavesExposureLockAndAnchorsAlone() {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true
        vm.nearAnchor = 0.2
        vm.farAnchor = 0.8
        fake.reset()

        vm.handleScenePhase(.background)

        XCTAssertTrue(vm.exposureLocked)
        XCTAssertEqual(vm.nearAnchor, 0.2)
        XCTAssertEqual(vm.farAnchor, 0.8)
        XCTAssertEqual(fake.calls, [.stop])
    }

    // MARK: - Launch race

    /// `.active` with nothing configured attempts a start rather than returning.
    ///
    /// That case is ambiguous: it is either the first `.active` at launch, which arrives
    /// before `configure()` returns, or a `configure()` that failed — most often denied
    /// camera permission. Treating it as "do nothing" made the second unrecoverable:
    /// granting access in iOS Settings and coming back left the viewfinder on a spinner
    /// forever, because `.task` never runs a second time. `start()` is reentrancy-guarded,
    /// so the launch case is safe — see the test below.
    func testActiveWithNothingConfiguredAttemptsStart() async {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        let vm = CameraViewModel(camera: fake)
        XCTAssertTrue(vm.lenses.isEmpty)
        XCTAssertFalse(vm.isPreviewMode)

        vm.handleScenePhase(.active)
        // Wait on the genuinely last call, not the first or the middle. `start()` pushes
        // EV, white balance and focus *after* `camera.start()`, and each of those can
        // report an error — so settling on `.start` and then asserting `errorMessage` is
        // nil would pass while those pushes were still pending.
        await settle("start() to finish") { fake.calls.contains(.setFocus(lensPosition: vm.lensPosition)) }

        XCTAssertTrue(fake.calls.contains(.configure))
        XCTAssertTrue(fake.calls.contains(.start))
        XCTAssertNil(vm.errorMessage)
    }

    /// The launch race the guard originally existed for: `.task` calls `start()` while
    /// the first `.active` also lands. Exactly one configuration must happen — a second
    /// concurrent `start()` is a no-op, not a parallel reconfiguration of a live session.
    func testConcurrentStartsConfigureOnlyOnce() async {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        let vm = CameraViewModel(camera: fake)

        // Two starts in flight at once: the first claims the guard synchronously before
        // suspending on configure(), so the second must find it taken and bail.
        vm.handleScenePhase(.active)
        vm.handleScenePhase(.active)
        await settle { fake.calls.contains(.start) }

        XCTAssertEqual(fake.calls.filter { $0 == .configure }.count, 1)
    }

    /// Preview mode (the Simulator) has no lenses by definition, so the "are we
    /// configured yet?" guard cannot be lens count alone — the synthetic frame timer
    /// still has to be restarted on every return to `.active`.
    ///
    /// `CameraViewModel.isPreviewMode` is `private(set)` and only assigned by
    /// `start()`, so this goes through the real `start()` path with a preview-mode
    /// camera rather than setting the flag directly.
    func testActiveInPreviewModeResumesEvenWithNoLenses() async {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        fake.isPreviewMode = true                 // and therefore no lenses
        let vm = CameraViewModel(camera: fake)

        await vm.start()
        XCTAssertTrue(vm.isPreviewMode)
        XCTAssertTrue(vm.lenses.isEmpty)
        fake.reset()

        vm.handleScenePhase(.active)
        // `.start` is the *first* thing `resumeSession()` does; waiting on it and then
        // asserting no error would leave the three device pushes that follow still in
        // flight.
        await settle("the resume to finish") { fake.calls.contains(.setFocus(lensPosition: vm.lensPosition)) }

        XCTAssertTrue(fake.calls.contains(.start), "preview mode must restart its frame timer")
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Resume

    /// iOS can hand the camera to another app while we are suspended and reset the
    /// device, so a locked setup has to be re-established from scratch. The order is
    /// the contract: EV first, then settle → lock → white balance, then focus. Locking
    /// before the meter has settled freezes whatever the algorithm was passing through,
    /// and re-applying colour before the lock lets the lock overwrite it.
    func testResumeWithExposureLockedReAppliesEVSettleLockWhiteBalanceThenFocus() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true
        vm.lensPosition = 0.37
        vm.handleScenePhase(.background)
        fake.reset()

        vm.handleScenePhase(.active)
        await settle { fake.calls.contains(.setFocus(lensPosition: 0.37)) }

        XCTAssertEqual(fake.calls, lockedResumeCalls(vm))
        XCTAssertTrue(vm.exposureLocked)
        XCTAssertTrue(fake.exposureLocked)
        XCTAssertEqual(fake.focusPosition, 0.37)
        XCTAssertEqual(fake.whiteBalance?.kelvin, vm.kelvin)
        XCTAssertNil(vm.errorMessage)
    }

    /// Colour is a manual setting whether or not exposure is locked — a background trip
    /// used to silently revert the light box's white balance to the device's own guess.
    /// Focus is manual too, so it has to come back as well.
    func testResumeWithExposureUnlockedStillReAppliesWhiteBalanceAndFocus() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.kelvin = 3200
        vm.lensPosition = 0.62
        XCTAssertFalse(vm.exposureLocked)
        vm.handleScenePhase(.background)
        fake.reset()

        vm.handleScenePhase(.active)
        await settle { fake.calls.contains(.setFocus(lensPosition: 0.62)) }

        XCTAssertEqual(fake.calls, [
            .start,
            .setExposureBias(vm.evBias),
            .setWhiteBalance(kelvin: 3200, tint: 0),
            .setFocus(lensPosition: 0.62)
        ])
        // Nothing may be frozen: the meter is supposed to stay live.
        XCTAssertFalse(fake.calls.contains(.lockExposure))
        XCTAssertFalse(fake.calls.contains(.waitForExposureSettle(timeout: 1.5)))
        XCTAssertFalse(vm.exposureLocked)
        XCTAssertEqual(fake.whiteBalance?.kelvin, 3200)
        XCTAssertEqual(fake.focusPosition, 0.62)
        XCTAssertNil(vm.errorMessage)
    }

    /// A failure part-way through the resume sequence surfaces to the user rather than
    /// leaving a half-restored device with no indication anything went wrong.
    func testResumeReportsAFailureFromTheDevice() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true
        fake.fail("lockExposure", with: CameraError.configurationFailed)
        vm.handleScenePhase(.background)
        fake.reset()

        vm.handleScenePhase(.active)
        await settle { vm.errorMessage != nil }

        XCTAssertNotNil(vm.errorMessage)
        // The sequence stops at the failure: focus is not re-applied over a device
        // whose exposure never came back.
        XCTAssertFalse(fake.calls.contains(.setFocus(lensPosition: vm.lensPosition)))
    }

    // MARK: - Repeated transitions

    /// Two `.active` transitions in a row with no `.background` between them — the
    /// Control Center / App Switcher trip, which goes `.active → .inactive → .active`,
    /// so nothing was ever stopped. Resuming twice must be idempotent in effect: the
    /// same sequence again, and identical state at the end.
    func testTwoActiveTransitionsInARowRepeatTheSequenceWithoutCorruptingState() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true
        vm.lensPosition = 0.44
        fake.reset()

        // Each transition is allowed to finish before the next: two *overlapping*
        // resume tasks are a separate concern (see the report), and asserting on an
        // interleaving would only pin whatever the scheduler happened to do.
        vm.handleScenePhase(.active)
        await settle { fake.calls.count == lockedResumeCalls(vm).count }
        vm.handleScenePhase(.active)
        await settle { fake.calls.count == lockedResumeCalls(vm).count * 2 }

        XCTAssertEqual(fake.calls, lockedResumeCalls(vm) + lockedResumeCalls(vm))
        XCTAssertTrue(vm.exposureLocked)
        XCTAssertTrue(fake.exposureLocked)
        XCTAssertEqual(vm.lensPosition, 0.44)
        XCTAssertEqual(vm.kelvin, 5000)
        XCTAssertEqual(vm.evBias, 0)
        XCTAssertFalse(vm.torchEnabled)
        XCTAssertEqual(fake.focusPosition, 0.44)
        XCTAssertNil(vm.errorMessage)
    }

    /// A full `background → active` round trip, twice: the ordinary app-switching case.
    /// The second trip must look exactly like the first.
    func testRepeatedBackgroundActiveRoundTripsAreStable() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true

        for _ in 0..<2 {
            vm.handleScenePhase(.background)
            XCTAssertEqual(fake.calls, [.stop])
            fake.reset()

            vm.handleScenePhase(.active)
            await settle { fake.calls == lockedResumeCalls(vm) }
            XCTAssertEqual(fake.calls, lockedResumeCalls(vm))
            fake.reset()
        }

        XCTAssertTrue(vm.exposureLocked)
        XCTAssertFalse(vm.torchEnabled)
        XCTAssertNil(vm.errorMessage)
    }

    /// `.inactive` is neither a stop nor a resume — it is the phase a notification
    /// shade or a Control Center pull passes through, and touching the session there
    /// would tear down a viewfinder that is still on screen.
    func testInactiveDoesNothing() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true

        vm.handleScenePhase(.inactive)
        await drain()

        XCTAssertEqual(fake.calls, [])
        XCTAssertTrue(vm.exposureLocked)
    }

    // MARK: - CameraService without a camera

    // `CameraService.isPreviewMode` is `private(set)` and only ever assigned inside
    // `configureOnQueue()`, which is only reachable through `configure()` — and that
    // calls `ensurePermission()` first. A unit-test bundle cannot answer a camera
    // permission prompt, so the preview-mode branches of the manual controls are not
    // directly reachable from here. What *is* reachable is the other side of every one
    // of those guards: a `CameraService` with no device attached, which must throw
    // rather than silently no-op.

    func testFreshServiceIsNotInPreviewModeAndHasNoDevice() {
        let service = CameraService()

        XCTAssertFalse(service.isPreviewMode)
        XCTAssertTrue(service.lenses.isEmpty)
        XCTAssertNil(service.currentLens)
        XCTAssertNil(service.currentLensPosition)
        XCTAssertNil(service.currentExposure)
    }

    /// Outside preview mode the manual controls must report the missing device instead
    /// of pretending to have applied something. This is the guard that the preview-mode
    /// early return sits directly in front of, in every one of these methods.
    func testManualControlsThrowNoCameraWhenNoDeviceIsAttached() {
        let service = CameraService()

        XCTAssertThrowsError(try service.setExposureBias(1)) { assertNoCamera($0) }
        XCTAssertThrowsError(try service.lockExposure()) { assertNoCamera($0) }
        XCTAssertThrowsError(try service.setWhiteBalance(kelvin: 5000, tint: 0)) { assertNoCamera($0) }
        XCTAssertThrowsError(try service.lockNeutralWhiteBalance()) { assertNoCamera($0) }
        XCTAssertThrowsError(try service.setTorch(enabled: true)) { assertNoCamera($0) }
        XCTAssertThrowsError(try service.setFocus(lensPosition: 0.5)) { assertNoCamera($0) }
    }

    /// Both waits return immediately with no device instead of burning their timeout,
    /// and a focus wait with nothing to wait for reports "did not settle" rather than
    /// claiming the lens arrived.
    func testWaitsReturnImmediatelyWithNoDevice() async {
        let service = CameraService()

        await service.waitForExposureSettle(timeout: 5)
        let settled = await service.waitForFocusSettle(target: 0.5, tolerance: 0.005, timeout: 5)

        XCTAssertFalse(settled)
    }

    /// `stop()` on a service that was never configured must not trap — this is the path
    /// a background transition takes if the app is backgrounded during launch, which is
    /// exactly the launch-race window above.
    func testStopOnAnUnconfiguredServiceIsHarmless() {
        let service = CameraService()
        service.stop()
        service.stop()
    }

    /// The caller-visible half of the `lockNeutralWhiteBalance` preview-mode fix: a
    /// neutral reading of (5000 K, 0) — the value `CameraService` returns in preview
    /// mode — has to land in the sliders and raise no alert. Before the fix the Gray
    /// card button was the one control that threw in the Simulator build, which reads
    /// as a fault in the very build meant for exercising the UI. Driven through
    /// `FakeCamera` because `CameraService`'s preview mode is not reachable from a test
    /// bundle (see the note above).
    func testGrayCardLockWithAPreviewModeNeutralReadingRaisesNoError() {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        fake.isPreviewMode = true
        fake.neutralWhiteBalanceResult = (5000, 0)   // CameraService's preview-mode value
        let vm = CameraViewModel(camera: fake)

        vm.lockGrayCardWB()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.kelvin, 5000)
        XCTAssertTrue(AppConfig.Exposure.kelvinRange.contains(vm.kelvin))
        // Reflecting the measurement back into the sliders must not push it out again.
        XCTAssertEqual(fake.calls, [.lockNeutralWhiteBalance])
    }

    /// A failed re-lock has to clear the flag, not just report.
    ///
    /// The lock chip reads straight off `exposureLocked`, and the shutter only asks for a
    /// lock when it is false. Leaving it true after a failed re-freeze showed green over a
    /// camera that was still metering, and let a bracket run that would band.
    func testFailedReLockOnResumeClearsTheExposureLock() async {
        let (vm, fake) = makeConfiguredViewModel()
        vm.exposureLocked = true
        fake.fail("lockExposure", with: CameraError.configurationFailed)
        vm.handleScenePhase(.background)
        fake.reset()

        vm.handleScenePhase(.active)
        await settle("the failed re-lock to be reported") { vm.errorMessage != nil }

        XCTAssertFalse(vm.exposureLocked, "the chip must not claim a lock the device lost")
        XCTAssertNotNil(vm.captureBlockedReason, "and the shutter must ask for it again")
    }

    // MARK: - A resume owed while busy

    /// Backgrounding while the review sheet is up, then returning, then dismissing.
    ///
    /// `resumeSession()` is the only thing that restarts the session after launch, so a
    /// resume skipped because the device was busy is never retried by anything else. An
    /// earlier version returned outright and left the viewfinder dead until the app was
    /// backgrounded and foregrounded a second time.
    func testResumeDeferredWhileBusyRunsOnReturnToIdle() async {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        fake.lenses = [Self.backLens]
        fake.currentLens = Self.backLens
        let vm = CameraViewModel(camera: fake)
        await vm.start()
        vm.phase = .done                       // review sheet up
        fake.reset()

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await drain()
        // Still busy: stopped, but nothing re-applied yet.
        XCTAssertEqual(fake.calls, [.stop])

        vm.dismissReview()                     // phase → .idle
        await settle { fake.calls.contains(.start) }

        XCTAssertTrue(fake.calls.contains(.start))
        XCTAssertTrue(fake.calls.contains(.setFocus(lensPosition: vm.lensPosition)))
    }

    /// The other half: a `.active` that never followed a `.background` must not resume,
    /// since nothing was stopped and the bracket owns the device. A Control Center pull
    /// mid-capture is the real case.
    func testActiveWithoutBackgroundDoesNotResumeWhileBusy() async {
        isolatePersistedCaptureDefaults()
        let fake = FakeCamera()
        fake.lenses = [Self.backLens]
        fake.currentLens = Self.backLens
        let vm = CameraViewModel(camera: fake)
        await vm.start()
        vm.phase = .capturing(frame: 3, of: 8)
        fake.reset()

        vm.handleScenePhase(.active)
        await drain()
        XCTAssertEqual(fake.calls, [])

        // And returning to idle must not then fire a resume that was never owed.
        vm.phase = .idle
        await drain()
        XCTAssertEqual(fake.calls, [])
    }
}
