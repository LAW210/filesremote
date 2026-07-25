import AudioToolbox
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case capturing(frame: Int, of: Int)
        case stacking(Double)
        case done
    }

    let camera = CameraService()
    private let preview = PreviewFrameProcessor()
    private let stacking = StackingService.shared
    private var bracket: FocusBracketController?

    // Live view
    @Published var viewfinderImage: UIImage?
    @Published var loupeImage: UIImage?
    @Published var loupeVisible = false
    @Published var histogram: [Float] = []
    @Published var errorMessage: String?

    // Lens
    @Published var lenses: [CameraService.Lens] = []
    @Published var selectedLensID: String?

    // Exposure (EV = ISO + shutter) and color (Kelvin WB) — independent controls.
    @Published var iso: Float
    @Published var shutterDenominator: Double      // e.g. 60 == 1/60 s
    @Published var kelvin: Float
    @Published var tint: Float
    @Published var exposureLocked = false

    // Focus
    @Published var lensPosition: Float = 0.5 { didSet { pushFocus() } }
    @Published var nearAnchor: Float?
    @Published var farAnchor: Float?

    // Bracket
    @Published var stepCount: Int { didSet { persistDefaultsIfLoaded() } }
    @Published var phase: Phase = .idle
    @Published var resultImage: UIImage?
    @Published var depthMapImage: UIImage?
    @Published var lastSet: StackSet?

    // Focus peaking overlay in the live viewfinder.
    @Published var peakingEnabled: Bool {
        didSet {
            preview.update { $0.peakingEnabled = peakingEnabled }
            persistDefaultsIfLoaded()
        }
    }
    /// Zebra overlay — tints clipped (blown highlight) pixels red in the live viewfinder.
    @Published var zebraEnabled: Bool {
        didSet {
            preview.update { $0.zebraEnabled = zebraEnabled }
            persistDefaultsIfLoaded()
        }
    }

    // Output settings (Settings sheet): stacked-image format. Source RAW frames are
    // always deleted once the stacked image is safely on disk — by design, only the
    // final image is kept.
    @Published var outputFormat: AppConfig.Stacking.OutputFormat {
        didSet { persistDefaultsIfLoaded() }
    }
    @Published var autoSaveToPhotos: Bool {
        didSet { persistDefaultsIfLoaded() }
    }
    /// 1:1 crop guide overlay — eBay renders square thumbnails, so framing inside the
    /// square before burning a multi-minute stack avoids wasted captures.
    @Published var squareGuideEnabled: Bool {
        didSet { persistDefaultsIfLoaded() }
    }
    /// True once the current result's file has been added to Photos (auto or manual).
    @Published var resultSavedToPhotos = false

    /// Torch state — session-specific (not persisted); resets on lens switch.
    @Published var torchEnabled = false

    /// Guards against `didSet` observers persisting the just-loaded values back to
    /// `UserDefaults` during `init`.
    private var isLoaded = false

    var shutterSeconds: Double { 1.0 / shutterDenominator }
    var canCapture: Bool {
        exposureLocked && nearAnchor != nil && farAnchor != nil && nearAnchor != farAnchor
    }

    /// Current lens aperture (fixed per lens), for the live EV readout.
    var currentAperture: Float? { camera.device?.lensAperture }

    /// EV at ISO 100, computed from the live aperture and the current shutter/ISO settings.
    var evReadout: Double? {
        guard let aperture = camera.device?.lensAperture, aperture > 0 else { return nil }
        let n = Double(aperture)
        let t = shutterSeconds
        let ev100 = log2((n * n) / t) - log2(Double(iso) / 100.0)
        return ev100
    }

    // MARK: - Lifecycle

    init() {
        let defaults = CaptureDefaults.load()
        _iso = Published(initialValue: defaults.iso)
        _shutterDenominator = Published(initialValue: defaults.shutterDenominator)
        _kelvin = Published(initialValue: defaults.kelvin)
        _tint = Published(initialValue: defaults.tint)
        _stepCount = Published(initialValue: defaults.stepCount)
        _peakingEnabled = Published(initialValue: defaults.peakingEnabled)
        _zebraEnabled = Published(initialValue: defaults.zebraEnabled)
        _outputFormat = Published(initialValue: defaults.outputFormat)
        _autoSaveToPhotos = Published(initialValue: defaults.autoSaveToPhotos)
        _squareGuideEnabled = Published(initialValue: defaults.squareGuideEnabled)
        isLoaded = true
    }

    func start() async {
        do {
            try await camera.configure()
            lenses = camera.lenses
            selectedLensID = camera.currentLens?.id
            camera.onPreviewFrame = { [weak self] buffer in
                guard let self, let output = self.preview.process(buffer) else { return }
                Task { @MainActor in
                    self.viewfinderImage = output.viewfinder
                    self.loupeImage = output.loupe
                    self.histogram = output.histogram
                }
            }
            syncPreviewSettings()
            await camera.start()
        } catch {
            report(error)
        }
    }

    /// Pushes main-actor-only state into the frame processor: the persisted overlay
    /// toggles, plus screen geometry (`UIScreen` must not be read from the video queue).
    private func syncPreviewSettings() {
        let screen = UIScreen.main
        let pointWidth = screen.bounds.width
        let pixelWidth = pointWidth * screen.scale
        preview.update {
            $0.peakingEnabled = peakingEnabled
            $0.zebraEnabled = zebraEnabled
            $0.screenPointWidth = pointWidth
            $0.screenPixelWidth = pixelWidth
        }
    }

    func selectLens(id: String) {
        guard let lens = lenses.first(where: { $0.id == id }) else { return }
        Task {
            do {
                try await camera.select(lens: lens)
                selectedLensID = id
                exposureLocked = false      // new module → re-set and re-lock exposure
                nearAnchor = nil
                farAnchor = nil
                torchEnabled = false        // torch belongs to the previous device
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Exposure / WB

    func applyAndLockExposure() {
        do {
            try camera.setExposure(iso: iso, shutterSeconds: shutterSeconds)
            try camera.setWhiteBalance(kelvin: kelvin, tint: tint)
            exposureLocked = true
            persistDefaults()
        } catch {
            report(error)
        }
    }

    func unlockExposure() { exposureLocked = false }

    /// Locks white balance from a neutral gray/white card filling the frame.
    func lockGrayCardWB() {
        do {
            let result = try camera.lockNeutralWhiteBalance()
            kelvin = min(max(result.kelvin, AppConfig.Exposure.kelvinRange.lowerBound), AppConfig.Exposure.kelvinRange.upperBound)
            tint = min(max(result.tint, AppConfig.Exposure.tintRange.lowerBound), AppConfig.Exposure.tintRange.upperBound)
            persistDefaults()
        } catch {
            report(error)
        }
    }

    // MARK: - Persistence

    private func persistDefaults() {
        CaptureDefaults(
            iso: iso,
            shutterDenominator: shutterDenominator,
            kelvin: kelvin,
            tint: tint,
            stepCount: stepCount,
            peakingEnabled: peakingEnabled,
            zebraEnabled: zebraEnabled,
            outputFormat: outputFormat,
            autoSaveToPhotos: autoSaveToPhotos,
            squareGuideEnabled: squareGuideEnabled
        ).save()
    }

    private func persistDefaultsIfLoaded() {
        guard isLoaded else { return }
        persistDefaults()
    }

    // MARK: - Focus + loupe

    private func pushFocus() {
        try? camera.setFocus(lensPosition: lensPosition)
    }

    func setLoupe(visible: Bool) {
        loupeVisible = visible
        preview.update { $0.loupeCenter = visible ? CGPoint(x: 0.5, y: 0.5) : nil }
    }

    func moveLoupe(to normalizedPoint: CGPoint) {
        preview.update { $0.loupeCenter = normalizedPoint }
    }

    func setLoupeMagnification(_ m: CGFloat) {
        let range = AppConfig.Loupe.magnificationRange
        preview.update { $0.loupeMagnification = min(max(m, range.lowerBound), range.upperBound) }
    }

    func markNear() { nearAnchor = lensPosition }
    func markFar() { farAnchor = lensPosition }

    // MARK: - Torch

    func setTorch(_ on: Bool) {
        do {
            try camera.setTorch(enabled: on)
            torchEnabled = on
        } catch {
            report(error)
            if torchEnabled { torchEnabled = false }
        }
    }

    // MARK: - Capture + stack

    func captureStack() {
        guard let near = nearAnchor, let far = farAnchor, canCapture else { return }
        let controller = FocusBracketController(camera: camera)
        bracket = controller
        let plan = FocusBracketController.Plan(near: near, far: far, stepCount: stepCount)
        let exposure = StackSet.Exposure(iso: iso, shutterSeconds: shutterSeconds)
        let wb = StackSet.WhiteBalance(kelvin: kelvin, tint: tint)

        Task {
            do {
                let set = try await controller.run(plan: plan, exposure: exposure, whiteBalance: wb) { p in
                    Task { @MainActor in
                        switch p {
                        case .startingTimer(let s): self.phase = .countdown(s)
                        case .capturing(let f, let n):
                            self.phase = .capturing(frame: f, of: n)
                            self.playFrameTick()
                        case .done: break
                        }
                    }
                }
                try await stack(set: set)
            } catch is CancellationError {
                phase = .idle
            } catch {
                report(error)
                phase = .idle
            }
        }
    }

    func cancelCapture() {
        bracket?.cancel()
    }

    func stack(set: StackSet) async throws {
        phase = .stacking(0)
        let (updated, output) = try await stacking.stackAndPersist(
            set,
            outputFormat: outputFormat,
            deleteFramesAfter: true) { p in
            Task { @MainActor in self.phase = .stacking(p) }
        }
        resultImage = output.merged
        depthMapImage = output.depthMap
        lastSet = updated

        // Fully automatic flow: the exact JPEG file lands in Photos with no tap.
        if autoSaveToPhotos, let url = stacking.mergedFileURL(for: updated) {
            do {
                try await stacking.saveFileToPhotos(url)
                resultSavedToPhotos = true
            } catch {
                report(error)    // stacking still succeeded; only the Photos add failed
            }
        }
        phase = .done
        playCompletionSound()
    }

    /// URL of the last stack's merged file — the exact encoded bytes on disk.
    var mergedFileURL: URL? {
        lastSet.flatMap { stacking.mergedFileURL(for: $0) }
    }

    func resetForNextStack() {
        phase = .idle
        resultImage = nil
        depthMapImage = nil
        resultSavedToPhotos = false
    }

    /// Stops the capture session in the background and resumes it on return —
    /// battery/thermal hygiene, and avoids a dead viewfinder after app switching.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            camera.stop()
            // Stopping the session extinguishes the torch in hardware; keep the UI
            // from claiming it is still on.
            if torchEnabled { torchEnabled = false }
        case .active:
            // Only once the session is configured (lenses discovered) — the initial
            // .active at launch fires before configure() completes, and start()
            // handles that case itself.
            guard !lenses.isEmpty else { return }
            Task { await resumeSession() }
        default:
            break
        }
    }

    /// Re-applies the manual locks after a background trip. iOS can hand the camera
    /// to another app while we are suspended and reset the device's exposure, white
    /// balance, and focus, which would silently un-lock a carefully metered setup.
    private func resumeSession() async {
        await camera.start()
        do {
            if exposureLocked {
                try camera.setExposure(iso: iso, shutterSeconds: shutterSeconds)
                try camera.setWhiteBalance(kelvin: kelvin, tint: tint)
            }
            try camera.setFocus(lensPosition: lensPosition)
        } catch {
            report(error)
        }
    }

    // MARK: - Audio feedback

    // Sound ONLY — deliberately no haptics: vibration would micro-shake the
    // tripod-mounted phone during the exact frames that need stillness.

    /// Soft tick as each bracket frame starts.
    private func playFrameTick() {
        AudioServicesPlaySystemSound(1057)
    }

    /// Distinct chime when the stacked result is ready.
    private func playCompletionSound() {
        AudioServicesPlaySystemSound(1025)
    }

    // MARK: - Errors

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
