import AVFoundation
import UIKit

/// Wraps AVCaptureSession: lens selection, manual focus/exposure/white balance, RAW capture,
/// and a video data output that feeds the viewfinder, focus peaking, and the loupe.
final class CameraService: NSObject {

    struct Lens: Identifiable {
        let id: String
        let name: String            // "0.5x", "1x", "3x"
        let device: AVCaptureDevice
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "stackshot.session")
    private let videoQueue = DispatchQueue(label: "stackshot.video")

    private(set) var lenses: [Lens] = []
    private(set) var currentLens: Lens?
    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

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
        lenses = discovery.devices.map { device in
            let name: String
            switch device.deviceType {
            case .builtInUltraWideCamera: name = "0.5x"
            case .builtInTelephotoCamera: name = "Tele"
            default: name = "1x"
            }
            return Lens(id: device.uniqueID, name: name, device: device)
        }
        guard let initial = lenses.first(where: { $0.name == "1x" }) ?? lenses.first else {
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

    private func attach(lens: Lens) throws {
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
                currentLens = nil
            }
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        videoInput = input
        currentLens = lens
    }

    /// Starts the session and returns once it is actually running, so callers can
    /// safely re-apply device configuration (locks, torch) immediately afterwards.
    func start() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    func stop() {
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

    func select(lens: Lens) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    self.session.beginConfiguration()
                    try self.attach(lens: lens)
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

    var device: AVCaptureDevice? { currentLens?.device }

    /// What the camera is currently metering at — shown live, and recorded once locked.
    var currentExposure: (iso: Float, shutterSeconds: Double)? {
        guard let device else { return nil }
        return (device.iso, CMTimeGetSeconds(device.exposureDuration))
    }

    /// Applies exposure compensation to the camera's own metering and leaves it
    /// metering continuously, so the preview shows the result immediately. Nothing is
    /// frozen until `lockExposure()`.
    func setExposureBias(_ ev: Float) throws {
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
    func waitForExposureSettle(timeout: TimeInterval = 1.5) async {
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
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setFocusModeLocked(lensPosition: lensPosition.clamped(to: 0...1))
    }

    /// Waits until the lens has physically settled near the requested position.
    func waitForFocusSettle(target: Float, tolerance: Float = 0.005, timeout: TimeInterval = 1.5) async {
        guard let device else { return }
        let deadline = Date().addingTimeInterval(timeout)
        var stableTicks = 0
        while Date() < deadline {
            if abs(device.lensPosition - target) <= tolerance {
                stableTicks += 1
                if stableTicks >= 3 { return }   // ~90 ms of stability
            } else {
                stableTicks = 0
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: - Capture

    /// Captures one photo at current settings. Returns DNG data when RAW is available,
    /// otherwise HEIF/JPEG data.
    func capturePhoto() async throws -> (data: Data, isRAW: Bool) {
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
