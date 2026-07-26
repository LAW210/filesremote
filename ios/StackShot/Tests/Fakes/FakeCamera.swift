import CoreVideo
import Foundation
@testable import StackShot

/// In-memory `CameraControlling` for tests: records the order of every call, lets a test
/// script return values and failures per method, and tracks the state a real device would
/// have ended up in. Nothing here talks to AVFoundation, so the camera-control paths run
/// in CI instead of only on a phone.
final class FakeCamera: CameraControlling {

    /// One recorded call. Associated values carry the arguments worth asserting on, so a
    /// test can check both *what* happened and *in what order* against `calls`.
    enum Call: Equatable {
        case configure
        case start
        case stop
        case select(lensID: String)
        case setExposureBias(Float)
        case waitForExposureSettle(timeout: TimeInterval)
        case lockExposure
        case setWhiteBalance(kelvin: Float, tint: Float)
        case lockNeutralWhiteBalance
        case setTorch(enabled: Bool)
        case setFocus(lensPosition: Float)
        case waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval)
        case capturePhoto
    }

    /// Every call in order. Sequence-sensitive behaviour (settle → lock → white balance)
    /// is only assertable against this, not against the end state.
    private(set) var calls: [Call] = []

    // MARK: - Scripted results

    /// Errors to throw instead of performing the call, for every call to that method.
    /// A method with no entry succeeds.
    var errors: [String: Error] = [:]

    /// Errors consumed one call at a time, checked before `errors`. This is what a
    /// transient AVFoundation hiccup looks like, and the only way to reach the bracket's
    /// one-retry-per-frame path.
    var transientErrors: [String: [Error]] = [:]

    var lenses: [LensInfo] = []
    var currentLens: LensInfo?
    var isPreviewMode = false
    var currentExposure: (iso: Float, shutterSeconds: Double)?
    var lockExposureResult: (iso: Float, shutterSeconds: Double) = (100, 1.0 / 60.0)
    var neutralWhiteBalanceResult: (kelvin: Float, tint: Float) = (5000, 0)
    /// What `waitForFocusSettle` reports — a timeout is a normal outcome the bracket
    /// has to log rather than an error.
    var focusSettles = true
    var capturePhotoResult: (data: Data, isRAW: Bool) = (Data([0xFF]), true)

    var onPreviewFrame: ((CVPixelBuffer) -> Void)?

    // MARK: - Observed device state

    /// Where the lens was last driven to. Also what `currentLensPosition` reports, so a
    /// test can pin it independently to simulate a lens that didn't arrive.
    private(set) var focusPosition: Float?
    var currentLensPosition: Float?
    private(set) var torchOn = false
    private(set) var exposureLocked = false
    private(set) var whiteBalance: (kelvin: Float, tint: Float)?
    private(set) var exposureBias: Float?

    // MARK: - Test driving

    /// Feeds a frame through the same closure the real capture delegate uses.
    func emitPreviewFrame(_ buffer: CVPixelBuffer) {
        onPreviewFrame?(buffer)
    }

    func reset() {
        calls = []
    }

    /// Sets up an error for the next (and every subsequent) call to `method`. Names match
    /// the base method name, e.g. `fail("setTorch", with: CameraError.torchUnavailable)`.
    func fail(_ method: String, with error: Error) {
        errors[method] = error
    }

    /// Fails the next call to `method` only; the one after it succeeds.
    func failOnce(_ method: String, with error: Error) {
        transientErrors[method, default: []].append(error)
    }

    private func record(_ call: Call, _ method: String) throws {
        calls.append(call)
        if var queued = transientErrors[method], !queued.isEmpty {
            let error = queued.removeFirst()
            transientErrors[method] = queued
            throw error
        }
        if let error = errors[method] { throw error }
    }

    // MARK: - CameraControlling

    func configure() async throws {
        try record(.configure, "configure")
    }

    func start() async {
        calls.append(.start)
    }

    func stop() {
        calls.append(.stop)
    }

    func select(lens: LensInfo) async throws {
        try record(.select(lensID: lens.id), "select")
        currentLens = lens
    }

    func setExposureBias(_ ev: Float) throws {
        try record(.setExposureBias(ev), "setExposureBias")
        exposureBias = ev
    }

    func waitForExposureSettle(timeout: TimeInterval) async {
        calls.append(.waitForExposureSettle(timeout: timeout))
    }

    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double) {
        try record(.lockExposure, "lockExposure")
        exposureLocked = true
        return lockExposureResult
    }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        try record(.setWhiteBalance(kelvin: kelvin, tint: tint), "setWhiteBalance")
        whiteBalance = (kelvin, tint)
    }

    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        try record(.lockNeutralWhiteBalance, "lockNeutralWhiteBalance")
        whiteBalance = neutralWhiteBalanceResult
        return neutralWhiteBalanceResult
    }

    func setTorch(enabled: Bool) throws {
        try record(.setTorch(enabled: enabled), "setTorch")
        torchOn = enabled
    }

    func setFocus(lensPosition: Float) throws {
        try record(.setFocus(lensPosition: lensPosition), "setFocus")
        focusPosition = lensPosition
        // A real lens ends up where it was told unless a test says otherwise, so the
        // capture log's "actual" column reads sensibly without extra setup.
        currentLensPosition = lensPosition
    }

    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool {
        calls.append(.waitForFocusSettle(target: target, tolerance: tolerance, timeout: timeout))
        return focusSettles
    }

    func capturePhoto() async throws -> (data: Data, isRAW: Bool) {
        try record(.capturePhoto, "capturePhoto")
        return capturePhotoResult
    }
}
