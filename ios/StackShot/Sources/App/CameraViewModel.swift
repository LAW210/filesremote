import Photos
import SwiftUI

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
    private let peaking = FocusPeakingProcessor()
    private var bracket: FocusBracketController?

    // Live view
    @Published var viewfinderImage: UIImage?
    @Published var loupeImage: UIImage?
    @Published var loupeVisible = false
    @Published var errorMessage: String?

    // Lens
    @Published var lenses: [CameraService.Lens] = []
    @Published var selectedLensID: String?

    // Exposure (EV = ISO + shutter) and color (Kelvin WB) — independent controls.
    @Published var iso: Float = 100
    @Published var shutterDenominator: Double = 60      // 1/60 s
    @Published var kelvin: Float = 5000
    @Published var tint: Float = 0
    @Published var exposureLocked = false

    // Focus
    @Published var lensPosition: Float = 0.5 { didSet { pushFocus() } }
    @Published var nearAnchor: Float?
    @Published var farAnchor: Float?

    // Bracket
    @Published var stepCount = 8
    @Published var phase: Phase = .idle
    @Published var resultImage: UIImage?
    @Published var lastSet: StackSet?

    var shutterSeconds: Double { 1.0 / shutterDenominator }
    var canCapture: Bool {
        exposureLocked && nearAnchor != nil && farAnchor != nil && nearAnchor != farAnchor
    }

    func start() async {
        do {
            try await camera.configure()
            lenses = camera.lenses
            selectedLensID = camera.currentLens?.id
            camera.onPreviewFrame = { [weak self] buffer in
                guard let self, let output = self.peaking.process(buffer) else { return }
                Task { @MainActor in
                    self.viewfinderImage = output.viewfinder
                    self.loupeImage = output.loupe
                }
            }
            camera.start()
        } catch {
            errorMessage = error.localizedDescription
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Exposure / WB

    func applyAndLockExposure() {
        do {
            try camera.setExposure(iso: iso, shutterSeconds: shutterSeconds)
            try camera.setWhiteBalance(kelvin: kelvin, tint: tint)
            exposureLocked = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockExposure() { exposureLocked = false }

    // MARK: Focus

    private func pushFocus() {
        try? camera.setFocus(lensPosition: lensPosition)
    }

    func setLoupe(visible: Bool) {
        loupeVisible = visible
        peaking.loupeCenter = visible ? CGPoint(x: 0.5, y: 0.5) : nil
    }

    func moveLoupe(to normalizedPoint: CGPoint) {
        peaking.loupeCenter = normalizedPoint
    }

    func setLoupeMagnification(_ m: CGFloat) {
        peaking.loupeMagnification = min(max(m, 2), 6)
    }

    func markNear() { nearAnchor = lensPosition }
    func markFar() { farAnchor = lensPosition }

    // MARK: Capture + stack

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
                        case .capturing(let f, let n): self.phase = .capturing(frame: f, of: n)
                        case .done: break
                        }
                    }
                }
                lastSet = set
                try await stack(set: set)
            } catch is CancellationError {
                phase = .idle
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    func cancelCapture() {
        bracket?.cancel()
    }

    func stack(set: StackSet) async throws {
        phase = .stacking(0)
        let engine = StackEngineFactory.make()
        let urls = set.frames.map { StackStore.shared.frameURL(set, $0) }
        let image = try await engine.stack(frameURLs: urls) { p in
            Task { @MainActor in self.phase = .stacking(p) }
        }
        resultImage = image

        // Persist merged result next to the frames and record it in the manifest.
        if let data = image.heicOrJPEGData() {
            var updated = set
            let fileName = "stacked.heic"
            try data.write(to: StackStore.shared.directory(for: set).appendingPathComponent(fileName),
                           options: .atomic)
            updated.result = .init(mergedFileName: fileName, engine: engine.name, processedAt: Date())
            try StackStore.shared.saveManifest(updated)
            lastSet = updated
        }
        phase = .done
    }

    func saveResultToPhotos() {
        guard let image = resultImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    func resetForNextStack() {
        phase = .idle
        resultImage = nil
    }
}

private extension UIImage {
    func heicOrJPEGData() -> Data? {
        if let heic = heicData() { return heic }
        return jpegData(compressionQuality: 0.95)
    }

    func heicData() -> Data? {
        guard let cg = cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                          "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
