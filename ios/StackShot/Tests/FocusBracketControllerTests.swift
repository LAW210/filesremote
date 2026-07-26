import CoreVideo
import XCTest
@testable import StackShot

/// Exercises the capture spine end to end with `FakeCamera` behind it and a temp-directory
/// `StackStore` in front, so the whole bracket — sweep order, per-frame retry, cleanup,
/// cancellation, manifest and capture log — runs in CI instead of only on a phone.
final class FocusBracketControllerTests: XCTestCase {

    private var root: URL!
    private var store: StackStore!
    private var camera: FakeCamera!

    private let exposure = StackSet.Exposure(iso: 100, shutterSeconds: 1.0 / 60.0, evBias: 1)
    private let whiteBalance = StackSet.WhiteBalance(kelvin: 5000, tint: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A temp root, never the real Documents folder: these tests write real files.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusBracketControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = StackStore(root: root)
        camera = FakeCamera()
        camera.currentLens = LensInfo(id: "com.apple.avfoundation.wide", name: "1x")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        camera = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeController(_ injected: CameraControlling? = nil) -> FocusBracketController {
        FocusBracketController(camera: injected ?? camera, store: store)
    }

    /// Always `startTimerSeconds: 0` — the 2 s production timer is real sleep time.
    @discardableResult
    private func runBracket(_ controller: FocusBracketController,
                            _ plan: FocusBracketController.Plan,
                            progress: @escaping (FocusBracketController.Progress) -> Void = { _ in }
    ) async throws -> StackSet {
        try await controller.run(plan: plan,
                                 exposure: exposure,
                                 whiteBalance: whiteBalance,
                                 startTimerSeconds: 0,
                                 progress: progress)
    }

    private func rootEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    private func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func setFocusPositions() -> [Float] {
        camera.calls.compactMap { call -> Float? in
            if case .setFocus(let position) = call { return position }
            return nil
        }
    }

    private func captureCount() -> Int {
        camera.calls.filter { $0 == .capturePhoto }.count
    }

    private func loadManifest(in directory: URL) throws -> StackSet {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try decoder.decode(StackSet.self, from: data)
    }

    private func logLines(in directory: URL) throws -> [String] {
        let url = directory.appendingPathComponent("capture-log.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Happy path

    func testEveryPlannedPositionIsFocusedInNearToFarOrder() async throws {
        let plan = FocusBracketController.Plan(near: 0.1, far: 0.9, stepCount: 5)
        var events: [String] = []

        let set = try await runBracket(makeController(), plan) { event in
            switch event {
            case .startingTimer(let seconds): events.append("timer:\(seconds)")
            case .capturing(let frame, let total): events.append("capture:\(frame)/\(total)")
            }
        }

        let focused = setFocusPositions()
        XCTAssertEqual(focused.count, plan.stepCount)
        for (actual, expected) in zip(focused, plan.positions) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6)
        }
        // Near→far and never the reverse: the sweep direction is what the stacker assumes.
        XCTAssertEqual(focused, focused.sorted())
        XCTAssertEqual(captureCount(), plan.stepCount)
        XCTAssertEqual(set.frames.map(\.index), [0, 1, 2, 3, 4])
        // A zero start timer must skip the stage outright rather than announce a 0 s wait.
        XCTAssertEqual(events, ["capture:1/5", "capture:2/5", "capture:3/5",
                                "capture:4/5", "capture:5/5"])
    }

    func testFramesAndManifestOnDiskMatchTheReturnedStackSet() async throws {
        let plan = FocusBracketController.Plan(near: 0.2, far: 0.8, stepCount: 4)

        let set = try await runBracket(makeController(), plan)

        let directory = store.directory(for: set)
        XCTAssertEqual(rootEntries(), [set.id.uuidString])
        XCTAssertEqual(entries(in: directory),
                       ["capture-log.txt", "frame_00.dng", "frame_01.dng",
                        "frame_02.dng", "frame_03.dng", "manifest.json"])
        for frame in set.frames {
            let url = store.frameURL(set, frame)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), frame.fileName)
            XCTAssertEqual(try Data(contentsOf: url), camera.capturePhotoResult.data)
        }

        // The returned value is only useful if it is exactly what a later launch will read.
        let manifest = try loadManifest(in: directory)
        XCTAssertEqual(manifest.id, set.id)
        XCTAssertEqual(manifest.frames.map(\.index), set.frames.map(\.index))
        XCTAssertEqual(manifest.frames.map(\.fileName), set.frames.map(\.fileName))
        XCTAssertEqual(manifest.frames.map(\.lensPosition), set.frames.map(\.lensPosition))
    }

    func testManifestRecordsTheLensAndTheRangeThePlanAskedFor() async throws {
        let plan = FocusBracketController.Plan(near: 0.15, far: 0.85, stepCount: 6)

        let set = try await runBracket(makeController(), plan)

        let manifest = try loadManifest(in: store.directory(for: set))
        XCTAssertEqual(manifest.lensID, "com.apple.avfoundation.wide")
        XCTAssertEqual(manifest.range.lensPositionNear, plan.near, accuracy: 1e-6)
        XCTAssertEqual(manifest.range.lensPositionFar, plan.far, accuracy: 1e-6)
        XCTAssertEqual(manifest.range.stepCount, plan.stepCount)
        XCTAssertEqual(manifest.frames.count, plan.stepCount)
        // Per-frame positions are the plan's, not a re-derivation at save time.
        for (frame, expected) in zip(manifest.frames, plan.positions) {
            XCTAssertEqual(frame.lensPosition, expected, accuracy: 1e-6)
        }
        XCTAssertEqual(manifest.exposure.evBias, 1)
        XCTAssertEqual(manifest.whiteBalance.kelvin, 5000)
        XCTAssertNil(manifest.result)
    }

    // MARK: - File format

    func testRAWCapturesLandAsDNG() async throws {
        camera.capturePhotoResult = (Data([0x44, 0x4E, 0x47]), true)

        let set = try await runBracket(makeController(),
                                       .init(near: 0.2, far: 0.6, stepCount: 3))

        XCTAssertEqual(set.frames.map(\.fileName),
                       ["frame_00.dng", "frame_01.dng", "frame_02.dng"])
    }

    /// The extension follows what the camera actually handed back, not a capture setting —
    /// a device that silently drops to HEIF must still produce a readable stack.
    func testHEIFCapturesLandAsHEIC() async throws {
        camera.capturePhotoResult = (Data([0x48, 0x45, 0x49]), false)

        let set = try await runBracket(makeController(),
                                       .init(near: 0.2, far: 0.6, stepCount: 3))

        XCTAssertEqual(set.frames.map(\.fileName),
                       ["frame_00.heic", "frame_01.heic", "frame_02.heic"])
        let directory = store.directory(for: set)
        XCTAssertTrue(entries(in: directory).contains("frame_02.heic"))
        XCTAssertFalse(entries(in: directory).contains("frame_02.dng"))
    }

    // MARK: - Per-frame retry

    /// One AVFoundation hiccup must not cost a bracket that is otherwise fine — cleanup
    /// would delete every frame already shot.
    func testASingleTransientCaptureFailureIsRetriedAndTheBracketCompletes() async throws {
        camera.failOnce("capturePhoto", with: CameraError.captureFailed)
        let plan = FocusBracketController.Plan(near: 0.1, far: 0.5, stepCount: 3)

        let set = try await runBracket(makeController(), plan)

        XCTAssertEqual(set.frames.count, 3)
        XCTAssertEqual(captureCount(), 4)               // frame 1 twice, frames 2 and 3 once
        XCTAssertEqual(entries(in: store.directory(for: set)).filter { $0.hasPrefix("frame_") },
                       ["frame_00.dng", "frame_01.dng", "frame_02.dng"])

        let lines = try logLines(in: store.directory(for: set))
        XCTAssertTrue(lines.contains { $0.contains("frame 1/3:") && $0.contains("attempts=2") })
        XCTAssertTrue(lines.contains { $0.contains("frame 2/3:") && $0.contains("attempts=1") })
    }

    /// Two in a row is not a hiccup: the retry budget is one per frame, and the bracket
    /// must surface the second failure rather than write a short stack.
    func testTwoConsecutiveCaptureFailuresOnOneFrameFailTheBracket() async throws {
        camera.failOnce("capturePhoto", with: CameraError.captureFailed)
        camera.failOnce("capturePhoto", with: CameraError.captureInterrupted)

        do {
            try await runBracket(makeController(), .init(near: 0.1, far: 0.5, stepCount: 3))
            XCTFail("expected the bracket to fail after two failures on the same frame")
        } catch {
            // The *last* error is what the photographer is shown.
            XCTAssertEqual(error as? CameraError, CameraError.captureInterrupted)
        }
        XCTAssertEqual(captureCount(), 2)
        XCTAssertEqual(rootEntries(), [], "a failed bracket must leave nothing behind")
    }

    // MARK: - Cleanup on failure

    func testAFailedBracketDeletesItsEntireDirectory() async throws {
        var partialEntries: [String] = []
        // Fail from frame 3 onward, so frames 1–2 are already written when it blows up.
        let onProgress: (FocusBracketController.Progress) -> Void = { [self] event in
            guard case .capturing(let frame, _) = event, frame == 3 else { return }
            let directory = root.appendingPathComponent(rootEntries().first ?? "missing")
            partialEntries = entries(in: directory)
            camera.fail("capturePhoto", with: CameraError.captureFailed)
        }

        do {
            try await runBracket(makeController(), .init(near: 0.1, far: 0.9, stepCount: 5),
                                 progress: onProgress)
            XCTFail("expected the bracket to fail on frame 3")
        } catch {
            XCTAssertEqual(error as? CameraError, CameraError.captureFailed)
        }

        // There really was something to clean up: two frames and nothing else yet.
        XCTAssertEqual(partialEntries, ["frame_00.dng", "frame_01.dng"])
        // No partial frames, no manifest, no log: the whole folder goes.
        XCTAssertEqual(rootEntries(), [])
    }

    /// `setFocus` throwing is not retried at all — the lens is the one thing the bracket
    /// cannot work around — and the same cleanup has to apply.
    func testAFocusFailureFailsTheBracketWithoutRetryingAndCleansUp() async throws {
        camera.fail("setFocus", with: CameraError.configurationFailed)

        do {
            try await runBracket(makeController(), .init(near: 0.1, far: 0.9, stepCount: 4))
            XCTFail("expected the bracket to fail when the lens cannot be driven")
        } catch {
            XCTAssertEqual(error as? CameraError, CameraError.configurationFailed)
        }
        XCTAssertEqual(captureCount(), 0)
        XCTAssertEqual(setFocusPositions().count, 1)
        XCTAssertEqual(rootEntries(), [])
    }

    // MARK: - Cancellation

    func testCancellingMidBracketThrowsCancellationErrorAndRemovesTheDirectory() async throws {
        let controller = makeController()
        var framesAnnounced = 0
        let onProgress: (FocusBracketController.Progress) -> Void = { event in
            guard case .capturing(let frame, _) = event else { return }
            framesAnnounced = frame
            if frame == 3 { controller.cancel() }
        }

        do {
            try await runBracket(controller, .init(near: 0.1, far: 0.9, stepCount: 6),
                                 progress: onProgress)
            XCTFail("expected cancellation to abort the bracket")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        // It stopped where it was told: frame 3 is announced but never captured.
        XCTAssertEqual(framesAnnounced, 3)
        XCTAssertEqual(captureCount(), 2)
        XCTAssertTrue(controller.isCancelled)
        // Cancellation is not a partial save — the folder goes the same way a failure's does.
        XCTAssertEqual(rootEntries(), [])
    }

    // MARK: - Capture log

    func testTheCaptureLogRecordsTheStartEveryFrameAndTheOutcome() async throws {
        let plan = FocusBracketController.Plan(near: 0.2, far: 0.8, stepCount: 4)

        let set = try await runBracket(makeController(), plan)

        let lines = try logLines(in: store.directory(for: set))
        let start = try XCTUnwrap(lines.first { $0.contains("bracket start:") })
        XCTAssertTrue(start.contains("lens=com.apple.avfoundation.wide"), start)
        XCTAssertTrue(start.contains("frames=4"), start)
        XCTAssertTrue(start.contains("startTimer=0s"), start)

        for index in 1...plan.stepCount {
            XCTAssertEqual(lines.filter { $0.contains("frame \(index)/4:") }.count, 1)
        }
        XCTAssertTrue(lines.contains { $0.contains("outcome: completed") })
        // bracket start + one line per frame + outcome, and nothing else.
        XCTAssertEqual(lines.count, plan.stepCount + 2)
    }

    /// A settle timeout is a normal outcome the log has to record, not an error — it is the
    /// only evidence left when a stack comes out soft.
    func testTheCaptureLogReportsASettleTimeoutAndTheLensPositionActuallyReached() async throws {
        camera.focusSettles = false
        // FakeCamera's own setFocus parks `currentLensPosition` on the target, so the only
        // way to prove the log reads the device rather than echoing the request is to wrap
        // it in a camera whose lens never arrives.
        let drifting = DriftingLensCamera(inner: camera, reportedLensPosition: 0.75)

        let set = try await runBracket(makeController(drifting),
                                       .init(near: 0.2, far: 0.9, stepCount: 2))

        let lines = try logLines(in: store.directory(for: set))
        let first = try XCTUnwrap(lines.first { $0.contains("frame 1/2:") })
        XCTAssertTrue(first.contains("target=0.2000 actual=0.7500 settle=timeout"), first)
        XCTAssertTrue(first.contains("attempts=1 file=frame_00.dng RAW"), first)
        let second = try XCTUnwrap(lines.first { $0.contains("frame 2/2:") })
        XCTAssertTrue(second.contains("target=0.9000 actual=0.7500 settle=timeout"), second)
        // A timeout is logged, not thrown: the frames are still captured and kept.
        XCTAssertEqual(set.frames.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("outcome: completed") })
    }

    /// With no device to ask, `currentLensPosition` is nil and the column has to render as
    /// -1 rather than crash or print "nil".
    func testTheCaptureLogRendersAnUnknownLensPositionAsMinusOne() async throws {
        let unknown = DriftingLensCamera(inner: camera, reportedLensPosition: nil)

        let set = try await runBracket(makeController(unknown), .init(near: 0.3, far: 0.6, stepCount: 2))

        let lines = try logLines(in: store.directory(for: set))
        let first = try XCTUnwrap(lines.first { $0.contains("frame 1/2:") })
        XCTAssertTrue(first.contains("actual=-1.0000"), first)
    }
}

// MARK: - Plan edge cases

/// Cases `FocusBracketPlanTests` does not cover: degenerate step counts and a zero-width
/// range. Both are reachable from a corrupted manifest or a mis-clamped UI value, and the
/// controller shoots exactly what `positions` returns.
final class FocusBracketPlanEdgeCaseTests: XCTestCase {

    func testStepCountZeroCollapsesToASingleNearFrame() {
        let plan = FocusBracketController.Plan(near: 0.4, far: 0.9, stepCount: 0)
        XCTAssertEqual(plan.positions.count, 1)
        XCTAssertEqual(plan.positions[0], 0.4, accuracy: 1e-6)
    }

    /// Guarding with `> 1` rather than clamping means a negative count behaves like 1 — no
    /// empty sweep, no crash on `Float(stepCount - 1)`.
    func testNegativeStepCountCollapsesToASingleNearFrame() {
        let plan = FocusBracketController.Plan(near: 0.25, far: 0.75, stepCount: -3)
        XCTAssertEqual(plan.positions.count, 1)
        XCTAssertEqual(plan.positions[0], 0.25, accuracy: 1e-6)
    }

    /// near == far is a legal-but-pointless sweep: N frames, all at one position. It must
    /// not divide by zero or drift off the endpoint.
    func testZeroWidthRangeRepeatsTheSamePosition() {
        let plan = FocusBracketController.Plan(near: 0.5, far: 0.5, stepCount: 5)
        XCTAssertEqual(plan.positions.count, 5)
        for position in plan.positions {
            XCTAssertEqual(position, 0.5, accuracy: 1e-6)
        }
    }

    /// The top of `AppConfig.Bracket.stepRange`, monotonic and still landing exactly on
    /// both endpoints after 19 accumulated float steps.
    func testTwentyStepsStayMonotonicAndHitBothEndpoints() {
        let plan = FocusBracketController.Plan(near: 0.0, far: 1.0, stepCount: 20)
        let positions = plan.positions
        XCTAssertEqual(positions.count, 20)
        XCTAssertEqual(positions.first!, 0.0, accuracy: 1e-6)
        XCTAssertEqual(positions.last!, 1.0, accuracy: 1e-6)
        for index in 1..<positions.count {
            XCTAssertGreaterThan(positions[index], positions[index - 1])
        }
    }

    /// The default step count has to produce the default frame count, or the manifest's
    /// `range.stepCount` and `frames.count` would disagree out of the box.
    func testDefaultStepCountProducesThatManyPositions() {
        let plan = FocusBracketController.Plan(near: 0.1, far: 0.9,
                                               stepCount: AppConfig.Bracket.defaultStepCount)
        XCTAssertEqual(plan.positions.count, AppConfig.Bracket.defaultStepCount)
    }
}

// MARK: - Fakes local to this suite

/// Forwards everything to a `FakeCamera` but reports a lens position of its own. Needed
/// because `FakeCamera.setFocus` pins `currentLensPosition` to the target it was given,
/// and the bracket gives a test no hook between `setFocus` and the log line where the
/// `actual=` column is rendered.
private final class DriftingLensCamera: CameraControlling {

    let inner: FakeCamera
    private let reportedLensPosition: Float?

    init(inner: FakeCamera, reportedLensPosition: Float?) {
        self.inner = inner
        self.reportedLensPosition = reportedLensPosition
    }

    var lenses: [LensInfo] { inner.lenses }
    var currentLens: LensInfo? { inner.currentLens }
    var isPreviewMode: Bool { inner.isPreviewMode }
    var currentExposure: (iso: Float, shutterSeconds: Double)? { inner.currentExposure }
    var currentLensPosition: Float? { reportedLensPosition }

    var onPreviewFrame: ((CVPixelBuffer) -> Void)? {
        get { inner.onPreviewFrame }
        set { inner.onPreviewFrame = newValue }
    }

    func configure() async throws { try await inner.configure() }
    func start() async { await inner.start() }
    func stop() { inner.stop() }
    func select(lens: LensInfo) async throws { try await inner.select(lens: lens) }

    func setExposureBias(_ ev: Float) throws { try inner.setExposureBias(ev) }

    func waitForExposureSettle(timeout: TimeInterval) async {
        await inner.waitForExposureSettle(timeout: timeout)
    }

    @discardableResult
    func lockExposure() throws -> (iso: Float, shutterSeconds: Double) { try inner.lockExposure() }

    func setWhiteBalance(kelvin: Float, tint: Float) throws {
        try inner.setWhiteBalance(kelvin: kelvin, tint: tint)
    }

    func lockNeutralWhiteBalance() throws -> (kelvin: Float, tint: Float) {
        try inner.lockNeutralWhiteBalance()
    }

    func setTorch(enabled: Bool) throws { try inner.setTorch(enabled: enabled) }
    func setFocus(lensPosition: Float) throws { try inner.setFocus(lensPosition: lensPosition) }

    @discardableResult
    func waitForFocusSettle(target: Float, tolerance: Float, timeout: TimeInterval) async -> Bool {
        await inner.waitForFocusSettle(target: target, tolerance: tolerance, timeout: timeout)
    }

    func capturePhoto() async throws -> (data: Data, isRAW: Bool) { try await inner.capturePhoto() }
}
