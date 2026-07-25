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
    /// Normalized (0–1, top-left origin) sample point the loupe is magnifying — mirrors
    /// `PreviewFrameProcessor.Settings.loupeCenter`, which the UI can't read directly,
    /// so the viewfinder can draw a reticle at the point actually being inspected.
    @Published private(set) var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    @Published var histogram: [Float] = []
    @Published var errorMessage: String?

    // Lens
    @Published var lenses: [CameraService.Lens] = []
    @Published var selectedLensID: String?

    // Brightness (EV compensation on the camera's metering) and colour (Kelvin WB)
    // are independent controls. The camera chooses ISO and shutter; EV biases it.
    @Published var evBias: Float {
        didSet {
            applyExposureBias()
            persistDefaultsIfLoaded()
        }
    }
    /// The values exposure was locked at; these shot the frames and land in EXIF.
    /// Recorded silently — ISO and shutter are not surfaced in the UI.
    private var lockedExposure: (iso: Float, shutterSeconds: Double)?

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

    /// Label for the lens button — the lens currently attached.
    var currentLensName: String {
        lenses.first { $0.id == selectedLensID }?.name ?? "—"
    }

    var canCapture: Bool {
        exposureLocked && nearAnchor != nil && farAnchor != nil && nearAnchor != farAnchor
    }

    // MARK: - Lifecycle

    init() {
        let defaults = CaptureDefaults.load()
        _evBias = Published(initialValue: defaults.evBias)
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
            applyExposureBias()
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

    /// Steps to the next available back camera. One button beats three chips when
    /// there are only ever two or three lenses to choose between.
    func cycleLens() {
        guard lenses.count > 1 else { return }
        let index = lenses.firstIndex { $0.id == selectedLensID } ?? -1
        selectLens(id: lenses[(index + 1) % lenses.count].id)
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
                applyExposureBias()         // metering bias is per-device
                // The new device defaults to continuous AF. Push the slider's value
                // so the displayed focus actually matches the hardware; didSet won't
                // fire because lensPosition itself hasn't changed.
                try camera.setFocus(lensPosition: lensPosition)
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Exposure / WB

    private func applyExposureBias() {
        guard !exposureLocked else { return }
        do { try camera.setExposureBias(evBias) } catch { report(error) }
    }

    /// Freezes metering and white balance so every frame in the bracket matches.
    func lockExposure() {
        Task {
            await camera.waitForExposureSettle()
            do {
                lockedExposure = try camera.lockExposure()
                try camera.setWhiteBalance(kelvin: kelvin, tint: tint)
                exposureLocked = true
                persistDefaults()
            } catch {
                report(error)
            }
        }
    }

    /// Returns to live metering so the EV slider takes effect again.
    func unlockExposure() {
        exposureLocked = false
        lockedExposure = nil
        applyExposureBias()
    }

    /// Locks white balance from a neutral gray/white card filling the frame.
    func lockGrayCardWB() {
        do {
            let result = try camera.lockNeutralWhiteBalance()
            kelvin = result.kelvin.clamped(to: AppConfig.Exposure.kelvinRange)
            tint = result.tint.clamped(to: AppConfig.Exposure.tintRange)
            persistDefaults()
        } catch {
            report(error)
        }
    }

    // MARK: - Persistence

    private func persistDefaults() {
        CaptureDefaults(
            evBias: evBias,
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
        loupeCenter = CGPoint(x: 0.5, y: 0.5)
        preview.update { $0.loupeCenter = visible ? loupeCenter : nil }
    }

    func moveLoupe(to normalizedPoint: CGPoint) {
        loupeCenter = normalizedPoint
        preview.update { $0.loupeCenter = normalizedPoint }
    }

    func setLoupeMagnification(_ m: CGFloat) {
        preview.update { $0.loupeMagnification = m.clamped(to: AppConfig.Loupe.magnificationRange) }
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
        // Clear the previous result here rather than on review dismissal, so the
        // outgoing sheet keeps showing its image until it is actually gone.
        resultImage = nil
        depthMapImage = nil
        resultSavedToPhotos = false

        let controller = FocusBracketController(camera: camera)
        bracket = controller
        let plan = FocusBracketController.Plan(near: near, far: far, stepCount: stepCount)
        let settled = lockedExposure ?? camera.currentExposure ?? (iso: 0, shutterSeconds: 0)
        let exposure = StackSet.Exposure(iso: settled.iso,
                                         shutterSeconds: settled.shutterSeconds,
                                         evBias: evBias)
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

    /// Called as the review sheet begins dismissing. Only the phase changes here:
    /// clearing the result images now would swap the finished photo for a spinner
    /// while the sheet is still animating away. The images are cleared when the next
    /// capture starts instead.
    func dismissReview() {
        phase = .idle
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
                // Re-freeze: iOS may have handed the camera to another app and reset
                // the device while we were suspended.
                try camera.setExposureBias(evBias)
                await camera.waitForExposureSettle()
                lockedExposure = try camera.lockExposure()
                try camera.setWhiteBalance(kelvin: kelvin, tint: tint)
            } else {
                try camera.setExposureBias(evBias)
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
