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
        // Diagnostic log for the bracket. If the bracket fails, `completed` stays
        // false and the defer below deletes `dir` — including this log — along with
        // the partial frames. That's accepted: a log for a run that left no frames
        // wouldn't be actionable anyway, and restructuring cleanup to keep it around
        // is out of scope here.
        let log = CaptureLog(directory: dir)
        defer { if !completed { try? FileManager.default.removeItem(at: dir) } }

        log.line("bracket start: device=\(set.deviceModel) lens=\(set.lensID) " +
                 "frames=\(plan.stepCount) near=\(plan.near) far=\(plan.far) " +
                 "startTimer=\(startTimerSeconds)s")

        // Tripod workflow: short start timer damps the button-press shake.
        if startTimerSeconds > 0 {
            progress(.startingTimer(seconds: startTimerSeconds))
            try await Task.sleep(nanoseconds: UInt64(startTimerSeconds) * 1_000_000_000)
        }

        let positions = plan.positions
        for (i, pos) in positions.enumerated() {
            let frameStart = Date()
            if isCancelled {
                log.line("frame \(i + 1)/\(positions.count): cancelled before capture")
                log.line("outcome: cancelled")
                log.flush()
                throw CancellationError()
            }
            progress(.capturing(frame: i + 1, of: positions.count))

            do {
                try camera.setFocus(lensPosition: pos)
            } catch {
                log.line("frame \(i + 1)/\(positions.count): setFocus failed: " +
                         "\(error.localizedDescription)")
                log.line("outcome: error: \(error.localizedDescription)")
                log.flush()
                throw error
            }
            var settled = await camera.waitForFocusSettle(target: pos)

            // One transient-failure retry per frame: a single AVFoundation hiccup
            // shouldn't cost the whole bracket (which cleanup would then delete).
            var captured: (data: Data, isRAW: Bool)?
            var lastError: Error?
            var attemptsUsed = 0
            for attempt in 0..<2 {
                if isCancelled {
                    log.line("frame \(i + 1)/\(positions.count): cancelled mid-attempt")
                    log.line("outcome: cancelled")
                    log.flush()
                    throw CancellationError()
                }
                attemptsUsed = attempt + 1
                do {
                    if attempt > 0 { settled = await camera.waitForFocusSettle(target: pos) }
                    captured = try await camera.capturePhoto()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            guard let (data, isRAW) = captured else {
                let error = lastError ?? CameraError.captureFailed
                log.line("frame \(i + 1)/\(positions.count): capture failed after " +
                         "\(attemptsUsed) attempt(s): \(error.localizedDescription)")
                log.line("outcome: error: \(error.localizedDescription)")
                log.flush()
                throw error
            }
            let fileName = String(format: "frame_%02d.%@", i, isRAW ? "dng" : "heic")
            do {
                try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
            } catch {
                log.line("frame \(i + 1)/\(positions.count): frame write failed: " +
                         "\(error.localizedDescription)")
                log.line("outcome: error: \(error.localizedDescription)")
                log.flush()
                throw error
            }

            set.frames.append(.init(index: i, lensPosition: pos,
                                    fileName: fileName, capturedAt: Date()))

            let actualLensPosition = camera.device?.lensPosition ?? -1
            let elapsed = Date().timeIntervalSince(frameStart)
            log.line(String(
                format: "frame %d/%d: target=%.4f actual=%.4f settle=%@ attempts=%d " +
                        "file=%@ %@ elapsed=%.3fs",
                i + 1, positions.count, pos, actualLensPosition,
                settled ? "ok" : "timeout", attemptsUsed, fileName,
                isRAW ? "RAW" : "HEIF", elapsed))
        }

        do {
            try store.saveManifest(set)
        } catch {
            log.line("manifest save failed: \(error.localizedDescription)")
            log.line("outcome: error: \(error.localizedDescription)")
            log.flush()
            throw error
        }
        log.line("outcome: completed")
        // Flush before `completed = true` so the log is on disk the moment the
        // directory becomes safe from the cleanup defer, regardless of what a caller
        // does with the returned StackSet afterwards.
        log.flush()
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
