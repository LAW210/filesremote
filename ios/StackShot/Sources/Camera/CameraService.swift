import AVFoundation
import UIKit

/// Wraps AVCaptureSession: lens selection, manual focus/exposure/white balance, RAW capture,
/// and a video data output that feeds the viewfinder, focus peaking, and the loupe.
final class CameraService: NSObject {

    struct Lens: Identifiable, Equatable {
        let id: String
        let name: String            // "0.5x", "1x", "3x"
        let device: AVCaptureDevice

        static func == (lhs: Lens, rhs: Lens) -> Bool { lhs.id == rhs.id }
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
        guard await requestPermission() else { throw CameraError.permissionDenied }
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
        if let existing = videoInput { session.removeInput(existing) }
        let input = try AVCaptureDeviceInput(device: lens.device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)
        videoInput = input
        currentLens = lens
    }

    func start() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
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

    func setExposure(iso: Float, shutterSeconds: Double) throws {
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let fmt = device.activeFormat
        let clampedISO = min(max(iso, fmt.minISO), fmt.maxISO)
        let duration = CMTime(seconds: shutterSeconds, preferredTimescale: 1_000_000)
        let clampedDuration = CMTimeClampToRange(
            duration,
            range: CMTimeRange(start: device.activeFormat.minExposureDuration,
                               end: device.activeFormat.maxExposureDuration))
        device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO)
    }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
        var gains = device.deviceWhiteBalanceGains(for: tt)
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        device.setWhiteBalanceModeLocked(with: gains)
    }

    /// Locks white balance using the device's gray-world estimate. Point the camera at a
    /// neutral gray/white card filling the frame first.
    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        var gains = device.grayWorldDeviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        device.setWhiteBalanceModeLocked(with: gains)
        let tt = device.temperatureAndTintValues(for: gains)
        return (tt.temperature, tt.tint)
    }

    func setFocus(lensPosition: Float) throws {
        guard let device else { throw CameraError.noCamera }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1))
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
                self.inFlightCaptures[settings.uniqueID] = cont
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
        return (data, isRAW)
    }

    private func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
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
    case noCamera
    case configurationFailed
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission was denied."
        case .noCamera: return "No back camera found."
        case .configurationFailed: return "Could not configure the camera session."
        case .captureFailed: return "Photo capture failed."
        }
    }
}
