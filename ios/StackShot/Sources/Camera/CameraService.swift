import AVFoundation
import UIKit

/// Wraps AVCaptureSession: lens selection, manual focus, EV bias, white balance, RAW capture,
/// and a video data output that feeds the viewfinder, focus peaking, and the loupe.
final class CameraService: NSObject, CameraControlling {

    /// A lens plus the device behind it. Stays inside this file: callers see `LensInfo`.
    private struct DeviceLens {
        let id: String
        let name: String            // magnification, e.g. "0.5\u{00D7}", "1\u{00D7}"
        let device: AVCaptureDevice

        var info: LensInfo { LensInfo(id: id, name: name) }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "stackshot.session")
    private let videoQueue = DispatchQueue(label: "stackshot.video")

    /// Guards the two fields below, and only those.
    ///
    /// They are written on `sessionQueue` (`configureOnQueue`, `attach`) but read from
    /// the main actor and from the bracket's own thread, and `DeviceLens?` is a
    /// multi-field struct, so that read is not atomic. Every `AVCaptureDevice` stays
    /// permanently retained by `_deviceLenses`, so the realistic worst case is a stale
    /// read rather than an over-release — but a torn struct read is undefined anyway,
    /// and this is far cheaper than the alternative that was considered: routing every
    /// device call through `sessionQueue`. That self-deadlocks through the `device`
    /// accessor (the single funnel all the control methods use), blocks cooperative-pool
    /// threads in the settle loops, and would have to turn five load-bearing `throws`
    /// into `async` — including the one that aborts a bracket when the lens won't move.
    ///
    /// `videoInput` is deliberately not guarded: it is only ever touched inside `attach`,
    /// on `sessionQueue`, and is never read from anywhere else.
    private let stateLock = NSLock()
    private var _deviceLenses: [DeviceLens] = []
    private var _currentDeviceLens: DeviceLens?

    private var deviceLenses: [DeviceLens] {
        get { stateLock.withLock { _deviceLenses } }
        set { stateLock.withLock { _deviceLenses = newValue } }
    }

    private var currentDeviceLens: DeviceLens? {
        get { stateLock.withLock { _currentDeviceLens } }
        set { stateLock.withLock { _currentDeviceLens = newValue } }
    }

    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    var lenses: [LensInfo] { deviceLenses.map(\.info) }
    var currentLens: LensInfo? { currentDeviceLens?.info }

    /// True when `configureOnQueue()` found no back camera at all — the iOS Simulator,
    /// which has no camera hardware. Rather than leave the whole UI stuck behind a
    /// spinner, the service falls back to synthetic preview frames and no-op manual
    /// controls so the app (and its layout, at true size) can be judged before the
    /// owner is ready to test on a physical phone. Never true on a device with a
    /// camera — `configureOnQueue()` only sets it when discovery finds zero devices.
    private(set) var isPreviewMode = false
    /// Simulator-only scaffolding: drives `onPreviewFrame` while in preview mode.
    /// Cancelled by `stop()`, same as the real session would be.
    private var previewTimer: DispatchSourceTimer?
    /// Simulator-only scaffolding: a single synthetic BGRA frame, drawn once and
    /// replayed. See `makeSyntheticPreviewBuffer()` for what it contains and why.
    private lazy var previewPixelBuffer: CVPixelBuffer? = Self.makeSyntheticPreviewBuffer()

    /// Latest preview frame, used by peaking and the loupe. Updated on videoQueue.
    var onPreviewFrame: ((CVPixelBuffer) -> Void)?

    private var inFlightCaptures: [Int64: CheckedContinuation<Data, Error>] = [:]

    // MARK: - Setup

    func configure() async throws {
        try await ensurePermission()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureOnQueue()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)

        // Simulator-only scaffolding: the Simulator reports zero back cameras (it has
        // none), whereas any real device this ships on has at least one. Drop into
        // preview mode instead of throwing `.noCamera`, so the UI is reachable without
        // a physical phone. No session/input/output configuration happens below.
        guard !discovery.devices.isEmpty else {
            isPreviewMode = true
            deviceLenses = []
            return
        }

        // Labels are magnifications relative to the wide camera, so the button reads as
        // one scale rather than mixing a zoom factor with a lens type.
        deviceLenses = discovery.devices.map { device in
            let name: String
            switch device.deviceType {
            case .builtInUltraWideCamera: name = "0.5\u{00D7}"
            case .builtInTelephotoCamera: name = "2\u{00D7}"
            default: name = "1\u{00D7}"
            }
            return DeviceLens(id: device.uniqueID, name: name, device: device)
        }
        // Default to whichever back camera focuses closest. StackShot is for macro
        // work on small objects, and the lens with the shortest minimum focus
        // distance — usually the ultra-wide on modern iPhones — is the one that can
        // actually get close, which is also what Apple's own macro mode switches to.
        // minimumFocusDistance is in millimetres and reports -1 when unknown, so
        // only positive values are usable; if none report one, fall back to the wide
        // camera. That fallback matches on device type, not on the label: the label is
        // display text and matching it here would mean renaming a button silently
        // changed which lens the app opens on.
        let closestFocusing = deviceLenses
            .filter { $0.device.minimumFocusDistance > 0 }
            .min { $0.device.minimumFocusDistance < $1.device.minimumFocusDistance }
        guard let initial = closestFocusing
            ?? deviceLenses.first(where: { $0.device.deviceType == .builtInWideAngleCamera })
            ?? deviceLenses.first else {
            throw CameraError.noCamera
        }
        try attach(lens: initial)

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        applyPortraitRotation()
    }

    /// Buffers arrive landscape by default; rotate both outputs for the portrait-only UI.
    private func applyPortraitRotation() {
        for output in [photoOutput as AVCaptureOutput, videoOutput] {
            if let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    private func attach(lens: DeviceLens) throws {
        // Construct the new input before detaching the old one, and put the old one
        // back if the new one turns out to be unusable — otherwise a failed lens
        // switch commits a session with no video input at all (black viewfinder,
        // no capture possible) while `videoInput` still points at a detached input.
        let input = try AVCaptureDeviceInput(device: lens.device)
        let previous = videoInput
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(input) else {
            if let previous, session.canAddInput(previous) {
                session.addInput(previous)
            } else {
                // Even the previously working input won't go back (device dropped, or
                // the session is in a bad state). Don't keep reporting a lens that
                // isn't attached — clear our state so callers see the truth and can
                // recover by selecting a lens again.
                videoInput = nil
                currentDeviceLens = nil
            }
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        videoInput = input
        currentDeviceLens = lens
    }

    /// Starts the session and returns once it is actually running, so callers can
    /// safely re-apply device configuration (locks, torch) immediately afterwards.
    func start() async {
        if isPreviewMode {
            startPreviewTimer()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    func stop() {
        if isPreviewMode {
            previewTimer?.cancel()
            previewTimer = nil
            return
        }
        sessionQueue.async {
            // Once the session stops, a pending capture's delegate callback never
            // arrives — its continuation would leak and hang the bracket forever
            // (backgrounding mid-capture). Fail them explicitly first.
            let pending = self.inFlightCaptures.values
            self.inFlightCaptures.removeAll()
            for cont in pending { cont.resume(throwing: CameraError.captureInterrupted) }

            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Simulator-only scaffolding: emits the synthetic frame on `videoQueue` at ~15 fps,
    /// through the same `onPreviewFrame` closure the real capture delegate uses, so the
    /// rest of the pipeline (peaking, zebra, histogram, loupe) can't tell the difference.
    private func startPreviewTimer() {
        // start() is called both at launch and on every return to .active, and a
        // .active → .inactive → .active trip (Control Center, App Switcher) never
        // passes through .background, so stop() — the only thing that cancels this —
        // may not have run. Without this guard each such trip would leave another
        // timer running, compounding the frame rate. The real-hardware path is
        // already idempotent via `if !session.isRunning`.
        guard previewTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 15.0)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.previewPixelBuffer else { return }
            self.onPreviewFrame?(buffer)
        }
        timer.resume()
        previewTimer = timer
    }

    func select(lens: LensInfo) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                // Callers hand back an identity from `lenses`, so this resolves on the
                // session queue that owns `deviceLenses` rather than trusting a device
                // reference that crossed a thread boundary.
                guard let target = self.deviceLenses.first(where: { $0.id == lens.id }) else {
                    cont.resume(throwing: CameraError.noCamera)
                    return
                }
                do {
                    self.session.beginConfiguration()
                    try self.attach(lens: target)
                    self.session.commitConfiguration()
                    self.applyPortraitRotation()
                    cont.resume()
                } catch {
                    self.session.commitConfiguration()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Manual controls

    private var device: AVCaptureDevice? { currentDeviceLens?.device }

    /// Where the lens actually is. Exposed instead of the device itself so the capture
    /// log can record the position reached without anything outside this file holding
    /// an `AVCaptureDevice`.
    var currentLensPosition: Float? { device?.lensPosition }

    /// What the camera is currently metering at — shown live, and recorded once locked.
    var currentExposure: (iso: Float, shutterSeconds: Double)? {
        // Simulator-only scaffolding: a plausible-looking reading (100 ISO, 1/60s) so
        // the exposure readout has something to show with no real device to meter.
        if isPreviewMode { return (100, 1.0 / 60.0) }
        guard let device else { return nil }
        return (device.iso, CMTimeGetSeconds(device.exposureDuration))
    }

    /// Applies exposure compensation to the camera's own metering and leaves it
    /// metering continuously, so the preview shows the result immediately. Nothing is
    /// frozen until `lockExposure()`.
    func setExposureBias(_ ev: Float) throws {
        // Simulator-only scaffolding: succeed silently, there is no metering to bias.
        if isPreviewMode { return }
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.setExposureTargetBias(
            ev.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias))
    }

    /// Waits for metering to stop hunting, so a lock captures a settled value rather
    /// than whatever the algorithm happened to be passing through.
    func waitForExposureSettle(timeout: TimeInterval) async {
        // Simulator-only scaffolding: nothing is metering, so there is nothing to wait
        // for — return immediately as if it had already settled.
        if isPreviewMode { return }
        guard let device else { return }
        let deadline = Date().addingTimeInterval(timeout)
        var stableTicks = 0
        while Date() < deadline {
            if !device.isAdjustingExposure {
                stableTicks += 1
                if stableTicks >= 3 { return }      // ~90 ms of stability
            } else {
                stableTicks = 0
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Freezes exposure at the metered value. Every frame in a bracket must share one
    /// exposure or the stack bands, so this is a precondition for capture. Returns the
    /// values the camera settled on, for the manifest and EXIF.
    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double) {
        // Simulator-only scaffolding: report a plausible fixed reading instead of
        // locking real hardware, so the exposure panel can be exercised end to end.
        if isPreviewMode { return (100, 1.0 / 60.0) }
        guard let device else { throw CameraError.noCamera }
        guard device.isExposureModeSupported(.locked) else {
            throw CameraError.configurationFailed
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.exposureMode = .locked
        return (device.iso, CMTimeGetSeconds(device.exposureDuration))
    }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        // Simulator-only scaffolding: succeed silently, there is no device to lock.
        if isPreviewMode { return }
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
        let gains = Self.clampedGains(device.deviceWhiteBalanceGains(for: tt), for: device)
        device.setWhiteBalanceModeLocked(with: gains)
    }

    /// Gains outside 1...maxWhiteBalanceGain make `setWhiteBalanceModeLocked` raise.
    private static func clampedGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                     for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let limit = 1...device.maxWhiteBalanceGain
        var clamped = gains
        clamped.redGain = gains.redGain.clamped(to: limit)
        clamped.greenGain = gains.greenGain.clamped(to: limit)
        clamped.blueGain = gains.blueGain.clamped(to: limit)
        return clamped
    }

    /// Locks white balance using the device's gray-world estimate. Point the camera at a
    /// neutral gray/white card filling the frame first.
    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        // Simulator-only scaffolding: report a plausible neutral reading, matching how
        // every other manual control behaves here. Without this the Gray card button is
        // the one control that raises an error alert in preview mode, which reads as a
        // fault in the very build meant for exercising the UI.
        if isPreviewMode { return (5000, 0) }
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let gains = Self.clampedGains(device.grayWorldDeviceWhiteBalanceGains, for: device)
        device.setWhiteBalanceModeLocked(with: gains)
        let tt = device.temperatureAndTintValues(for: gains)
        return (tt.temperature, tt.tint)
    }

    /// Turns the torch on (full brightness) or off for extra light-box illumination.
    /// The torch belongs to the active device and resets when the lens changes.
    func setTorch(enabled: Bool) throws {
        // Simulator-only scaffolding: succeed silently, there is no torch to drive.
        if isPreviewMode { return }
        guard let device else { throw CameraError.noCamera }
        guard device.hasTorch else { throw CameraError.torchUnavailable }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if enabled {
            try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
    }

    func setFocus(lensPosition: Float) throws {
        // Simulator-only scaffolding: succeed silently, there is no lens to move.
        if isPreviewMode { return }
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setFocusModeLocked(lensPosition: lensPosition.clamped(to: 0...1))
    }

    /// Waits until the lens has physically settled near the requested position.
    /// Returns whether it actually settled, so callers can distinguish a clean
    /// settle from a timeout for capture diagnostics.
    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool {
        // Simulator-only scaffolding: there is no lens hunting to wait out — report an
        // immediate clean settle so callers proceed as they would on a real device.
        if isPreviewMode { return true }
        guard let device else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var stableTicks = 0
        while Date() < deadline {
            if abs(device.lensPosition - target) <= tolerance {
                stableTicks += 1
                if stableTicks >= 3 { return true }   // ~90 ms of stability
            } else {
                stableTicks = 0
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    // MARK: - Capture

    /// Captures one photo at current settings. Returns DNG data when RAW is available,
    /// otherwise HEIF/JPEG data.
    func capturePhoto() async throws -> (data: Data, isRAW: Bool) {
        // There is no real sensor in preview mode, so there is nothing to capture —
        // unlike the other manual controls, this can't be faked into succeeding.
        guard !isPreviewMode else { throw CameraError.noCamera }
        let settings: AVCapturePhotoSettings
        var isRAW = false
        if let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            isRAW = true
        } else if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        settings.flashMode = .off

        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            sessionQueue.async {
                // capturePhoto raises on a stopped session, so fail fast instead —
                // this is the path a bracket retry takes after backgrounding.
                guard self.session.isRunning else {
                    cont.resume(throwing: CameraError.captureInterrupted)
                    return
                }
                self.inFlightCaptures[settings.uniqueID] = cont
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
        return (data, isRAW)
    }

    /// Simulator-only scaffolding: builds one static synthetic frame for preview mode.
    /// Drawn once in `kCVPixelFormatType_32BGRA` — the exact format the real video
    /// output is configured for above — because `PreviewFrameProcessor` reads BGRA
    /// bytes directly for its histogram; any other format would read as garbage.
    /// The content exercises the overlays the way a real light-boxed subject would:
    /// a bright near-white background pegs the histogram at the highlight end, a dark
    /// ringed subject with hard edges gives focus peaking real edges to find, and a
    /// small pure-white patch gives the zebra overlay a clipped highlight to paint.
    /// Never called on a device with a camera.
    private static func makeSyntheticPreviewBuffer() -> CVPixelBuffer? {
        let width = 1280
        let height = 960
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var unmanagedBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                         &unmanagedBuffer)
        guard status == kCVReturnSuccess, let buffer = unmanagedBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // premultipliedFirst + byteOrder32Little lays bytes out as B,G,R,A in memory,
        // matching kCVPixelFormatType_32BGRA, so CoreGraphics can draw straight into
        // the pixel buffer's own storage.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }

        // Bright, near-white light-box background.
        context.setFillColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Dark circular subject with concentric rings for peaking to find.
        let center = CGPoint(x: width / 2, y: height / 2)
        let radii: [Int] = [260, 220, 180, 140, 100, 60]
        for (i, r) in radii.enumerated() {
            let shade = (i % 2 == 0) ? 0.10 : 0.22
            context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1.0)
            context.fillEllipse(in: CGRect(x: center.x - CGFloat(r), y: center.y - CGFloat(r),
                                           width: CGFloat(r) * 2, height: CGFloat(r) * 2))
        }

        // Hard-edged spokes crossing the rings for extra high-contrast edges.
        context.setStrokeColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
        context.setLineWidth(6)
        for eighth in 0..<8 {
            let angle = Double(eighth) * .pi / 4
            let dx = CGFloat(cos(angle)) * 280
            let dy = CGFloat(sin(angle)) * 280
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
            context.strokePath()
        }

        // Small pure-white blown highlight for the zebra overlay to paint.
        context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        context.fillEllipse(in: CGRect(x: width - 220, y: 60, width: 120, height: 120))

        return buffer
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .video)) {
                throw CameraError.permissionDenied
            }
        case .restricted:
            throw CameraError.permissionRestricted
        case .denied:
            throw CameraError.permissionDenied
        @unknown default:
            throw CameraError.permissionDenied
        }
    }
}

// MARK: - Delegates

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        sessionQueue.async {
            guard let cont = self.inFlightCaptures.removeValue(forKey: photo.resolvedSettings.uniqueID) else { return }
            if let error {
                cont.resume(throwing: error)
            } else if let data = photo.fileDataRepresentation() {
                cont.resume(returning: data)
            } else {
                cont.resume(throwing: CameraError.captureFailed)
            }
        }
    }

    /// The safety net for a capture that is aborted before a photo is ever produced.
    ///
    /// AVFoundation guarantees this callback for every request, but NOT
    /// `didFinishProcessingPhoto` — that one is skipped when the request dies early, as
    /// it does if the session is reconfigured (a lens switch) while a frame is in flight.
    /// Without this, the continuation is never resumed and never removed: the bracket
    /// parks forever inside `await capturePhoto()`, never reaching its cancellation
    /// checks, so even the Cancel button does nothing and the only way out is force-quit.
    ///
    /// Both callbacks funnel through the same `removeValue` on `sessionQueue`, so
    /// whichever arrives second finds nothing and is a no-op — there is no double-resume.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        sessionQueue.async {
            guard let cont = self.inFlightCaptures.removeValue(forKey: resolvedSettings.uniqueID) else { return }
            cont.resume(throwing: error ?? CameraError.captureInterrupted)
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPreviewFrame?(buffer)
    }
}

enum CameraError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case noCamera
    case configurationFailed
    case captureFailed
    case captureInterrupted
    case torchUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission was denied."
        case .permissionRestricted: return "Camera access is restricted (parental controls or device management)."
        case .noCamera: return "No back camera found."
        case .configurationFailed: return "Could not configure the camera session."
        case .captureFailed: return "Photo capture failed."
        case .captureInterrupted: return "Capture was interrupted — the camera stopped mid-bracket."
        case .torchUnavailable: return "This lens has no torch."
        }
    }
}
