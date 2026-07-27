import CoreVideo
import Foundation
import XCTest
@testable import StackShot

/// Two overlapping lens switches, with a device call that actually takes time.
///
/// `CameraViewModel.selectLens(id:)` claims `selectedLensID` synchronously and then chains
/// the hardware work through `lensSwitchTask`, awaiting the previous switch before touching
/// the device. `camera.select` is `nonisolated async`, so without that chain two taps hop
/// off the main actor independently and can reach the device in either order — which left
/// the hardware attached to one lens while `selectedLensID` named another, permanently,
/// until the next tap.
///
/// `CameraControlStateTests` cannot see this: `FakeCamera.select` never suspends, so the
/// two calls serialise by accident whether or not the view model chains them. The gate
/// below is the missing piece — it parks the *first* `select` until the test releases it, so
/// an unchained second switch has an open window to overtake it. Same decorator shape as
/// `DriftingLensCamera` in `FocusBracketControllerTests`.
@MainActor
final class LensSwitchSerialisationTests: XCTestCase {

    private static func threeLenses() -> [LensInfo] {
        [LensInfo(id: "wide", name: "1x"),
         LensInfo(id: "ultra", name: "0.5x"),
         LensInfo(id: "tele", name: "Tele")]
    }

    /// Waits for `condition`, failing rather than silently giving up — see the same helper
    /// in `CameraControlStateTests`. The switch work runs inside a `Task` with no handle to
    /// await, and part of it runs off the main actor, so polling is the only observation
    /// point; the 1 ms sleep is the polling granularity, not a guess at the duration.
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

    private func selectedLensIDs(_ calls: [FakeCamera.Call]) -> [String] {
        calls.compactMap { (call: FakeCamera.Call) -> String? in
            guard case .select(let lensID) = call else { return nil }
            return lensID
        }
    }

    /// Two taps while the first switch is still inside the device call.
    ///
    /// With the chaining in place the second switch cannot begin until the first has
    /// finished, so the device sees `ultra` then `tele` — request order — and ends up
    /// attached to the lens the view model claims. Remove `await previousSwitch?.value` and
    /// the second switch runs straight through the ungated path while the first is parked:
    /// `tele` reaches the device first, `ultra` lands on top of it when the gate opens, and
    /// the camera finishes on `ultra` while `selectedLensID` says `tele`.
    func testASecondLensSwitchWaitsForTheFirstToReachTheDevice() async {
        let fake = FakeCamera()
        let gate = GatedLensCamera(inner: fake)
        let vm = CameraViewModel(camera: gate, defaults: makeIsolatedDefaults())
        vm.lenses = Self.threeLenses()
        vm.selectedLensID = "wide"
        fake.reset()

        vm.cycleLens()      // wide -> ultra
        vm.cycleLens()      // ultra -> tele
        // Claimed synchronously, which is what makes the second tap compute `tele`.
        XCTAssertEqual(vm.selectedLensID, "tele")

        await waitUntil("the first switch to reach the camera") { gate.isParked }
        // Give an unchained second switch every chance to overtake: main-actor turns for
        // the task to be scheduled, then real time for the off-actor `select` to land.
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Nothing may pass the first switch while it is in flight — asserted at the camera
        // seam (which the second call would enter first) and at the device (where it would
        // be recorded).
        XCTAssertEqual(gate.selectArrivals, ["ultra"],
                       "the second switch must not reach the camera while the first is in flight")
        XCTAssertEqual(selectedLensIDs(fake.calls), [],
                       "no lens may be attached out of turn")

        gate.openGate()
        await waitUntil("both switches to reach the device") {
            self.selectedLensIDs(fake.calls).count == 2
        }

        // The ordered log is the whole point: the device saw the lenses in request order.
        XCTAssertEqual(selectedLensIDs(fake.calls), ["ultra", "tele"])
        XCTAssertEqual(gate.selectArrivals, ["ultra", "tele"])
        // And the last tap is the one that won, on both sides of the seam.
        XCTAssertEqual(vm.selectedLensID, "tele")
        XCTAssertEqual(fake.currentLens?.id, vm.selectedLensID,
                       "the attached lens and the one the UI names must agree")
        XCTAssertNil(vm.errorMessage)
    }

    /// Three taps, to pin that the chain is a chain and not a one-deep special case: the
    /// device must see every lens in request order and finish on the last one asked for.
    func testThreeRapidSwitchesReachTheDeviceInRequestOrder() async {
        let fake = FakeCamera()
        let gate = GatedLensCamera(inner: fake)
        let vm = CameraViewModel(camera: gate, defaults: makeIsolatedDefaults())
        vm.lenses = Self.threeLenses()
        vm.selectedLensID = "wide"
        fake.reset()

        vm.cycleLens()      // wide  -> ultra
        vm.cycleLens()      // ultra -> tele
        vm.cycleLens()      // tele  -> wide (wraps)
        XCTAssertEqual(vm.selectedLensID, "wide")

        await waitUntil("the first switch to reach the camera") { gate.isParked }
        gate.openGate()
        await waitUntil("all three switches to reach the device") {
            self.selectedLensIDs(fake.calls).count == 3
        }

        XCTAssertEqual(selectedLensIDs(fake.calls), ["ultra", "tele", "wide"])
        XCTAssertEqual(fake.currentLens?.id, vm.selectedLensID)
        XCTAssertNil(vm.errorMessage)
    }
}

// MARK: - Fakes local to this suite

/// Forwards everything to a `FakeCamera`, but parks the first `select` call until the test
/// opens the gate — a stand-in for the real session reconfiguration, which takes long
/// enough on a phone for a second tap to land inside it. `FakeCamera.select` returns
/// without ever suspending, which is why nothing in the suite could reach the interleaving
/// before this.
///
/// Deterministic by construction: the release is a continuation the test resumes, not a
/// sleep. State is behind a lock for the same reason `FakeCamera`'s is — `select` is
/// nonisolated, so the calls genuinely arrive from two threads.
private final class GatedLensCamera: CameraControlling {

    let inner: FakeCamera

    private let lock = NSRecursiveLock()
    private var _selectArrivals: [String] = []
    private var _parked: CheckedContinuation<Void, Never>?
    private var _isParked = false
    private var _gateOpen = false

    init(inner: FakeCamera) {
        self.inner = inner
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Every `select` that reached this decorator, in arrival order — one seam earlier than
    /// `FakeCamera.calls`, so a call parked in the gate is already visible here.
    var selectArrivals: [String] { withLock { _selectArrivals } }

    /// True once the first `select` is suspended inside the gate.
    var isParked: Bool { withLock { _isParked } }

    /// Lets the parked call (and every later one) through.
    func openGate() {
        let waiting: CheckedContinuation<Void, Never>? = withLock {
            _gateOpen = true
            _isParked = false
            let continuation = _parked
            _parked = nil
            return continuation
        }
        waiting?.resume()       // resumed outside the lock
    }

    func select(lens: LensInfo) async throws {
        let mustPark: Bool = withLock {
            _selectArrivals.append(lens.id)
            return _selectArrivals.count == 1 && !_gateOpen
        }
        if mustPark {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let openAlready: Bool = withLock {
                    guard !_gateOpen else { return true }
                    _parked = continuation
                    _isParked = true
                    return false
                }
                if openAlready { continuation.resume() }
            }
        }
        try await inner.select(lens: lens)
    }

    // MARK: - Straight pass-through

    var lenses: [LensInfo] { inner.lenses }
    var currentLens: LensInfo? { inner.currentLens }
    var isPreviewMode: Bool { inner.isPreviewMode }
    var currentExposure: (iso: Float, shutterSeconds: Double)? { inner.currentExposure }
    var currentLensPosition: Float? { inner.currentLensPosition }

    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get { inner.onPreviewFrame }
        set { inner.onPreviewFrame = newValue }
    }

    func configure() async throws { try await inner.configure() }
    func start() async { await inner.start() }
    func stop() { inner.stop() }

    func setExposureBias(_ ev: Float) throws { try inner.setExposureBias(ev) }

    func waitForExposureSettle(timeout: TimeInterval) async {
        await inner.waitForExposureSettle(timeout: timeout)
    }

    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double) { try inner.lockExposure() }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        try inner.setWhiteBalance(kelvin: kelvin, tint: tint)
    }

    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        try inner.lockNeutralWhiteBalance()
    }

    func setTorch(enabled: Bool) throws { try inner.setTorch(enabled: enabled) }
    func setFocus(lensPosition: Float) throws { try inner.setFocus(lensPosition: lensPosition) }

    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool {
        await inner.waitForFocusSettle(target: target, tolerance: tolerance, timeout: timeout)
    }

    func capturePhoto() async throws -> (data: Data, isRAW: Bool) { try await inner.capturePhoto() }
}
