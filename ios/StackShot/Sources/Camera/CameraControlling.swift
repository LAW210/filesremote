import CoreVideo
import Foundation

/// One selectable back camera, as everything above `CameraService` sees it: an identity
/// and a label, no `AVCaptureDevice`. The device stays inside `CameraService` — a lens
/// value that carried one would drag AVFoundation (and therefore a physical phone) into
/// every caller, which is exactly what this seam exists to prevent. `select(lens:)` takes
/// the identity back and resolves it to the real device internally.
struct LensInfo: Identifiable, Equatable {
    let id: String
    let name: String            // "0.5x", "1x", "Tele"
}

/// Everything the view model and the bracket controller need from the camera. The only
/// production implementation is `CameraService`; tests supply an in-memory fake, which is
/// the only way any of this is reachable without a device.
protocol CameraControlling: AnyObject {

    var lenses: [LensInfo] { get }
    var currentLens: LensInfo? { get }
    var isPreviewMode: Bool { get }

    /// What the camera is currently metering at — shown live, and recorded once locked.
    var currentExposure: (iso: Float, shutterSeconds: Double)? { get }

    /// Where the lens actually is, as opposed to where it was last told to go. Nil when
    /// there is no device to ask; the capture log renders that as `-1`.
    var currentLensPosition: Float? { get }

    var onPreviewFrame: ((CVPixelBuffer) -> Void)? { get set }

    func configure() async throws
    func start() async
    func stop()
    func select(lens: LensInfo) async throws

    func setExposureBias(_ ev: Float) throws
    func waitForExposureSettle(timeout: TimeInterval) async
    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double)
    func setWhiteBalance(kelvin: Float, tint: Float) throws
    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float)
    func setTorch(enabled: Bool) throws

    func setFocus(lensPosition: Float) throws
    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool

    func capturePhoto() async throws -> (data: Data, isRAW: Bool)
}

// Protocol requirements can't carry default arguments, so the settle timings live here
// instead — one copy, shared by every implementation, at the values `CameraService`
// used before the protocol existed.
extension CameraControlling {

    func waitForExposureSettle() async {
        await waitForExposureSettle(timeout: 1.5)
    }

    // Deliberately `waitForFocusSettle(target:)` rather than the full signature with
    // defaults: a protocol-extension member matching a requirement exactly becomes its
    // default implementation, and this one would then recurse into itself.
    @discardableResult
    func waitForFocusSettle(target: Float) async -> Bool {
        await waitForFocusSettle(target: target, tolerance: 0.005, timeout: 1.5)
    }
}
