import XCTest
@testable import StackShot

final class CaptureReadinessTests: XCTestCase {

    // MARK: - canCapture

    func testAllPreconditionsMetAllowsCapture() {
        XCTAssertTrue(CaptureReadiness.canCapture(exposureLocked: true, near: 0.2, far: 0.8))
    }

    func testUnlockedExposureBlocksCaptureEvenWithGoodAnchors() {
        XCTAssertFalse(CaptureReadiness.canCapture(exposureLocked: false, near: 0.2, far: 0.8))
    }

    func testMissingAnchorBlocksCapture() {
        XCTAssertFalse(CaptureReadiness.canCapture(exposureLocked: true, near: nil, far: 0.8))
        XCTAssertFalse(CaptureReadiness.canCapture(exposureLocked: true, near: 0.2, far: nil))
        XCTAssertFalse(CaptureReadiness.canCapture(exposureLocked: true, near: nil, far: nil))
    }

    /// A zero-width sweep would shoot N identical frames — the stack would have
    /// nothing to choose between, so it is treated as not-ready rather than allowed.
    func testIdenticalAnchorsBlockCapture() {
        XCTAssertFalse(CaptureReadiness.canCapture(exposureLocked: true, near: 0.5, far: 0.5))
    }

    /// Far nearer than near is still a real sweep, just descending; the bracket
    /// interpolates in either direction, so this must not be rejected.
    func testReversedAnchorsStillAllowCapture() {
        XCTAssertTrue(CaptureReadiness.canCapture(exposureLocked: true, near: 0.9, far: 0.1))
    }

    // MARK: - blockedReason

    func testNoReasonWhenReady() {
        XCTAssertNil(CaptureReadiness.blockedReason(exposureLocked: true, near: 0.2, far: 0.8))
    }

    func testReasonNamesTheMissingAnchor() {
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: true, near: nil, far: 0.8),
                       "Set Near")
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: true, near: 0.2, far: nil),
                       "Set Far")
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: true, near: nil, far: nil),
                       "Set Near and Far")
    }

    func testReasonNamesTheExposureLockAlone() {
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: false, near: 0.2, far: 0.8),
                       "Lock exposure")
    }

    /// Both problems at once must both be named — reporting only the first would
    /// send the owner round a second time after fixing it.
    func testReasonCombinesEveryUnmetPrecondition() {
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: false, near: nil, far: nil),
                       "Lock exposure · Set Near and Far")
    }

    func testReasonExplainsIdenticalAnchors() {
        XCTAssertEqual(CaptureReadiness.blockedReason(exposureLocked: true, near: 0.5, far: 0.5),
                       "Near and Far must differ")
    }

    /// The invariant the type exists to guarantee: the shutter's enabled state and
    /// the caption under it are one decision, so they can never contradict.
    func testReasonIsNilExactlyWhenCaptureIsAllowed() {
        let anchors: [Float?] = [nil, 0.0, 0.5, 1.0]
        for locked in [true, false] {
            for near in anchors {
                for far in anchors {
                    let can = CaptureReadiness.canCapture(exposureLocked: locked, near: near, far: far)
                    let reason = CaptureReadiness.blockedReason(exposureLocked: locked, near: near, far: far)
                    XCTAssertEqual(can, reason == nil,
                                   "locked=\(locked) near=\(String(describing: near)) far=\(String(describing: far))")
                    if let reason { XCTAssertFalse(reason.isEmpty) }
                }
            }
        }
    }
}
