import CoreVideo
import Foundation
@testable import StackShot

/// In-memory `CameraControlling` for tests: records the order of every call, lets a test
/// script return values and failures per method, and tracks the state a real device would
/// have ended up in. Nothing here talks to AVFoundation, so the camera-control paths run
/// in CI instead of only on a phone.
///
/// Every property is behind a lock. That is not defensive habit — `CameraControlling`'s
/// async members are nonisolated, so a `@MainActor` caller that spawns two overlapping
/// tasks (two taps of the lens button, two scene-phase resumes) genuinely calls in from
/// two threads at once. An unlocked `calls` array silently *lost* an append in exactly
/// that case, which read as a missing device call and sent us looking for a bug in the
/// view model. A fake that drops evidence is worse than no fake.
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

    /// Recursive because a test's `onPreviewFrame` closure may call back into the fake
    /// while `emitPreviewFrame` still holds the lock.
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Recorded calls

    private var _calls: [Call] = []

    /// Every call in order. Sequence-sensitive behaviour (settle → lock → white balance)
    /// is only assertable against this, not against the end state.
    var calls: [Call] { withLock { _calls } }

    // MARK: - Scripted results

    private var _errors: [String: Error] = [:]
    private var _transientErrors: [String: [Error]] = [:]

    /// Errors to throw instead of performing the call, for every call to that method.
    /// A method with no entry succeeds.
    var errors: [String: Error] {
        get { withLock { _errors } }
        set { withLock { _errors = newValue } }
    }

    /// Errors consumed one call at a time, checked before `errors`. This is what a
    /// transient AVFoundation hiccup looks like, and the only way to reach the bracket's
    /// one-retry-per-frame path.
    var transientErrors: [String: [Error]] {
        get { withLock { _transientErrors } }
        set { withLock { _transientErrors = newValue } }
    }

    private var _lenses: [LensInfo] = []
    private var _currentLens: LensInfo?
    private var _isPreviewMode = false
    private var _currentExposure: (iso: Float, shutterSeconds: Double)?
    private var _lockExposureResult: (iso: Float, shutterSeconds: Double) = (100, 1.0 / 60.0)
    private var _neutralWhiteBalanceResult: (kelvin: Float, tint: Float) = (5000, 0)
    private var _focusSettles = true
    private var _capturePhotoResult: (data: Data, isRAW: Bool) = (Data([0xFF]), true)
    private var _onPreviewFrame: ((CVPixelBuffer) -> Void)?

    var lenses: [LensInfo] {
        get { withLock { _lenses } }
        set { withLock { _lenses = newValue } }
    }

    var currentLens: LensInfo? {
        get { withLock { _currentLens } }
        set { withLock { _currentLens = newValue } }
    }

    var isPreviewMode: Bool {
        get { withLock { _isPreviewMode } }
        set { withLock { _isPreviewMode = newValue } }
    }

    var currentExposure: (iso: Float, shutterSeconds: Double)? {
        get { withLock { _currentExposure } }
        set { withLock { _currentExposure = newValue } }
    }

    var lockExposureResult: (iso: Float, shutterSeconds: Double) {
        get { withLock { _lockExposureResult } }
        set { withLock { _lockExposureResult = newValue } }
    }

    var neutralWhiteBalanceResult: (kelvin: Float, tint: Float) {
        get { withLock { _neutralWhiteBalanceResult } }
        set { withLock { _neutralWhiteBalanceResult = newValue } }
    }

    /// What `waitForFocusSettle` reports — a timeout is a normal outcome the bracket
    /// has to log rather than an error.
    var focusSettles: Bool {
        get { withLock { _focusSettles } }
        set { withLock { _focusSettles = newValue } }
    }

    var capturePhotoResult: (data: Data, isRAW: Bool) {
        get { withLock { _capturePhotoResult } }
        set { withLock { _capturePhotoResult = newValue } }
    }

    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get { withLock { _onPreviewFrame } }
        set { withLock { _onPreviewFrame = newValue } }
    }

    // MARK: - Observed device state

    private var _focusPosition: Float?
    private var _currentLensPosition: Float?
    private var _torchOn = false
    private var _exposureLocked = false
    private var _whiteBalance: (kelvin: Float, tint: Float)?
    private var _exposureBias: Float?

    /// Where the lens was last driven to.
    var focusPosition: Float? { withLock { _focusPosition } }

    /// What the lens reports. `setFocus` pins this to the target, so a test that needs a
    /// lens which didn't arrive where it was sent assigns it afterwards.
    var currentLensPosition: Float? {
        get { withLock { _currentLensPosition } }
        set { withLock { _currentLensPosition = newValue } }
    }

    var torchOn: Bool { withLock { _torchOn } }
    var exposureLocked: Bool { withLock { _exposureLocked } }
    var whiteBalance: (kelvin: Float, tint: Float)? { withLock { _whiteBalance } }
    var exposureBias: Float? { withLock { _exposureBias } }

    // MARK: - Test driving

    /// Feeds a frame through the same closure the real capture delegate uses.
    func emitPreviewFrame(_ buffer: CVPixelBuffer) {
        onPreviewFrame?(buffer)
    }

    func reset() {
        withLock { _calls = [] }
    }

    /// Sets up an error for the next (and every subsequent) call to `method`. Names match
    /// the base method name, e.g. `fail("setTorch", with: CameraError.torchUnavailable)`.
    func fail(_ method: String, with error: Error) {
        withLock { _errors[method] = error }
    }

    /// Fails the next call to `method` only; the one after it succeeds.
    func failOnce(_ method: String, with error: Error) {
        withLock { _transientErrors[method, default: []].append(error) }
    }

    /// Records the call and returns the error to throw, if the test scripted one. The
    /// throw happens in the caller so nothing is thrown while the lock is held.
    private func record(_ call: Call, _ method: String) -> Error? {
        withLock { () -> Error? in
            _calls.append(call)
            if var queued = _transientErrors[method], !queued.isEmpty {
                let error = queued.removeFirst()
                _transientErrors[method] = queued
                return error
            }
            return _errors[method]
        }
    }

    private func perform(_ call: Call, _ method: String) throws {
        if let error = record(call, method) { throw error }
    }

    // MARK: - CameraControlling

    func configure() async throws {
        try perform(.configure, "configure")
    }

    func start() async {
        withLock { _calls.append(.start) }
    }

    func stop() {
        withLock { _calls.append(.stop) }
    }

    func select(lens: LensInfo) async throws {
        try perform(.select(lensID: lens.id), "select")
        withLock { _currentLens = lens }
    }

    func setExposureBias(_ ev: Float) throws {
        try perform(.setExposureBias(ev), "setExposureBias")
        withLock { _exposureBias = ev }
    }

    func waitForExposureSettle(timeout: TimeInterval) async {
        withLock { _calls.append(.waitForExposureSettle(timeout: timeout)) }
    }

    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double) {
        try perform(.lockExposure, "lockExposure")
        return withLock { () -> (iso: Float, shutterSeconds: Double) in
            _exposureLocked = true
            return _lockExposureResult
        }
    }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        try perform(.setWhiteBalance(kelvin: kelvin, tint: tint), "setWhiteBalance")
        withLock { _whiteBalance = (kelvin, tint) }
    }

    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        try perform(.lockNeutralWhiteBalance, "lockNeutralWhiteBalance")
        return withLock { () -> (kelvin: Float, tint: Float) in
            _whiteBalance = _neutralWhiteBalanceResult
            return _neutralWhiteBalanceResult
        }
    }

    func setTorch(enabled: Bool) throws {
        try perform(.setTorch(enabled: enabled), "setTorch")
        withLock { _torchOn = enabled }
    }

    func setFocus(lensPosition: Float) throws {
        try perform(.setFocus(lensPosition: lensPosition), "setFocus")
        withLock {
            _focusPosition = lensPosition
            // A real lens ends up where it was told unless a test says otherwise, so the
            // capture log's "actual" column reads sensibly without extra setup.
            _currentLensPosition = lensPosition
        }
    }

    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool {
        withLock { () -> Bool in
            _calls.append(.waitForFocusSettle(target: target, tolerance: tolerance, timeout: timeout))
            return _focusSettles
        }
    }

    func capturePhoto() async throws -> (data: Data, isRAW: Bool) {
        try perform(.capturePhoto, "capturePhoto")
        return withLock { _capturePhotoResult }
    }
}
