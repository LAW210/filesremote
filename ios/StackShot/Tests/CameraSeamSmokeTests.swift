import XCTest
@testable import StackShot

/// Proves the camera seam itself works: a `CameraViewModel` can be built with no
/// AVFoundation behind it, and a control change reaches the injected camera. The
/// behaviour suites that depend on this live alongside it.
@MainActor
final class CameraSeamSmokeTests: XCTestCase {

    func testChangingKelvinPushesWhiteBalanceToTheInjectedCamera() {
        let fake = FakeCamera()
        let vm = CameraViewModel(camera: fake)

        vm.kelvin = 4300

        XCTAssertEqual(fake.whiteBalance?.kelvin, 4300)
        XCTAssertTrue(fake.calls.contains(.setWhiteBalance(kelvin: 4300, tint: vm.tint)))
    }

    /// The bracket controller takes the same seam, and gets the lens position it logs
    /// from the fake rather than from an `AVCaptureDevice`.
    func testBracketControllerAcceptsTheFakeAndSeesItsLensPosition() throws {
        let fake = FakeCamera()
        let controller = FocusBracketController(camera: fake)
        XCTAssertFalse(controller.isCancelled)

        try fake.setFocus(lensPosition: 0.25)
        XCTAssertEqual(fake.currentLensPosition, 0.25)
        XCTAssertEqual(fake.calls, [.setFocus(lensPosition: 0.25)])
    }
}
