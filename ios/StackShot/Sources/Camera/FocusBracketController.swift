import Foundation

/// Drives the near→far focus sweep: N evenly spaced steps, inclusive endpoints,
/// settle-wait before each frame, exposure and white balance untouched throughout.
final class FocusBracketController {

    struct Plan {
        var near: Float
        var far: Float
        var stepCount: Int          // default 8, adjustable 3–20

        /// Inclusive endpoints: step 0 == near, step N-1 == far.
        var positions: [Float] {
            guard stepCount > 1 else { return [near] }
            return (0..<stepCount).map { i in
                let t = Float(i) / Float(stepCount - 1)
                return near + (far - near) * t
            }
        }
    }

    enum Progress {
        case startingTimer(seconds: Int)
        case capturing(frame: Int, of: Int)
    }

    private let camera: CameraService
    private let store: StackStore
    private(set) var isCancelled = false

    init(camera: CameraService, store: StackStore = .shared) {
        self.camera = camera
        self.store = store
    }

    func cancel() { isCancelled = true }

    /// Runs the full bracket and returns a persisted StackSet (frames on disk, manifest saved).
    func run(plan: Plan,
             exposure: StackSet.Exposure,
             whiteBalance: StackSet.WhiteBalance,
             startTimerSeconds: Int = AppConfig.Bracket.startTimerSeconds,
             progress: @escaping (Progress) -> Void) async throws -> StackSet {
        isCancelled = false

        var set = StackSet(
            id: UUID(),
            createdAt: Date(),
            deviceModel: deviceModelIdentifier(),
            lensID: camera.currentLens?.id ?? "unknown",
            exposure: exposure,
            whiteBalance: whiteBalance,
            range: .init(lensPositionNear: plan.near,
                         lensPositionFar: plan.far,
                         stepCount: plan.stepCount),
            frames: [],
            result: nil)
        let dir = try store.createDirectory(for: set)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: dir) } }

        // Tripod workflow: short start timer damps the button-press shake.
        if startTimerSeconds > 0 {
            progress(.startingTimer(seconds: startTimerSeconds))
            try await Task.sleep(nanoseconds: UInt64(startTimerSeconds) * 1_000_000_000)
        }

        let positions = plan.positions
        for (i, pos) in positions.enumerated() {
            if isCancelled { throw CancellationError() }
            progress(.capturing(frame: i + 1, of: positions.count))

            try camera.setFocus(lensPosition: pos)
            await camera.waitForFocusSettle(target: pos)

            // One transient-failure retry per frame: a single AVFoundation hiccup
            // shouldn't cost the whole bracket (which cleanup would then delete).
            var captured: (data: Data, isRAW: Bool)?
            var lastError: Error?
            for attempt in 0..<2 {
                if isCancelled { throw CancellationError() }
                do {
                    if attempt > 0 { await camera.waitForFocusSettle(target: pos) }
                    captured = try await camera.capturePhoto()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            guard let (data, isRAW) = captured else {
                throw lastError ?? CameraError.captureFailed
            }
            let fileName = String(format: "frame_%02d.%@", i, isRAW ? "dng" : "heic")
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)

            set.frames.append(.init(index: i, lensPosition: pos,
                                    fileName: fileName, capturedAt: Date()))
        }

        try store.saveManifest(set)
        completed = true
        return set
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
