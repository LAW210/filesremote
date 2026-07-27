import UIKit
import XCTest
@testable import StackShot

/// The post-capture path: `CameraViewModel.stack(set:)` and what it publishes.
///
/// This is the region where a mistake loses a finished photo rather than producing a
/// visibly wrong one — the merged image exists, the frames are already deleted, and there
/// is no re-stack path — so the assertions here are mostly about what must survive a
/// partial failure. Everything runs against `FakeStackPersisting`, so no filesystem and no
/// photo library are involved; the one test that needs `captureStack()`'s error handling
/// runs a real bracket through `FakeCamera` and cleans up after itself.
@MainActor
final class StackFlowTests: XCTestCase {

    /// A failure with a message worth asserting on, so "the error was reported" can be
    /// checked as "*this* error was reported" rather than merely "something was".
    private struct StackFlowError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Fixtures

    private func makeViewModel() -> (CameraViewModel, FakeStackPersisting, FakeCamera) {
        let camera = FakeCamera()
        let stacking = FakeStackPersisting()
        let vm = CameraViewModel(camera: camera,
                                 stacking: stacking,
                                 defaults: makeIsolatedDefaults())
        return (vm, stacking, camera)
    }

    /// A StackSet with no files behind it. The fake never reads a frame, so nothing needs
    /// to be on disk — and `result` is deliberately nil, which is what makes "the view
    /// model published the *updated* set" an assertable distinction.
    private func makeSet(frameCount: Int = 3) -> StackSet {
        StackSet(
            id: UUID(),
            createdAt: Date(),
            deviceModel: "iPhone15,2",
            lensID: "back-wide",
            exposure: .init(iso: 100, shutterSeconds: 1.0 / 60.0, evBias: 1),
            whiteBalance: .init(kelvin: 5000, tint: 0),
            range: .init(lensPositionNear: 0.2, lensPositionFar: 0.8, stepCount: frameCount),
            frames: (0..<frameCount).map { index -> StackSet.Frame in
                StackSet.Frame(index: index,
                               lensPosition: Float(index) / Float(max(frameCount - 1, 1)),
                               fileName: String(format: "frame_%02d.dng", index),
                               capturedAt: Date())
            },
            result: nil)
    }

    /// Waits for `condition`, failing the test if it never holds. Same shape as
    /// `SessionLifecycleTests.settle` and for the same reason: silently giving up would
    /// turn every negative assertion that follows into a free pass.
    private func settle(_ description: String = "the expected state",
                        timeout: TimeInterval = 5,
                        file: StaticString = #filePath,
                        line: UInt = #line,
                        until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func discardCalls(_ stacking: FakeStackPersisting) -> [FakeStackPersisting.Call] {
        stacking.calls.filter { if case .discard = $0 { return true } else { return false } }
    }

    // MARK: - The happy path

    /// Everything a finished stack has to publish, in one place: the images come from the
    /// returned `StackOutput`, `lastSet` is the set the *service* returned rather than the
    /// one handed in (only that one carries `result`, and the Library reads the merged file
    /// through it), and the anchors are marked as carried over.
    func testSuccessfulStackPublishesTheResultAndTheUpdatedSet() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = false
        let set = makeSet()
        stacking.updatedSet = FakeStackPersisting.stacked(set, format: .png, engine: "fake engine v2")
        XCTAssertNil(set.result, "premise: the set passed in must carry no result")
        XCTAssertFalse(vm.anchorsFromPreviousCapture)

        try await vm.stack(set: set)

        XCTAssertEqual(vm.phase, .done)
        XCTAssertFalse(vm.isStacking)
        XCTAssertTrue(vm.resultImage === stacking.output.merged)
        XCTAssertTrue(vm.depthMapImage === stacking.output.depthMap)
        XCTAssertEqual(vm.lastSet?.id, set.id)
        XCTAssertNotNil(vm.lastSet?.result,
                        "lastSet must be the updated set — the input one has no result to read")
        XCTAssertEqual(vm.lastSet?.result?.mergedFileName, "stacked.png")
        XCTAssertEqual(vm.lastSet?.result?.engine, "fake engine v2")
        XCTAssertTrue(vm.anchorsFromPreviousCapture)
        XCTAssertNil(vm.errorMessage)
        // A set that stacked successfully must never be deleted.
        XCTAssertEqual(discardCalls(stacking), [])
    }

    // MARK: - Progress

    /// The `progress` closure the view model hands to the service is what drives the
    /// progress bar. It hops to the main actor through a `Task`, so this waits for the
    /// value to arrive rather than asserting synchronously — and the fake holds the stack
    /// open at a gate, so the intermediate phase is observable without sleeping and hoping.
    func testProgressFromTheServiceDrivesTheStackingPhase() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = false
        stacking.progressValues = [0.42]
        stacking.gatesStack = true
        let set = makeSet()

        let run = Task { try await vm.stack(set: set) }
        await settle("progress 0.42 to reach the phase") { vm.phase == .stacking(0.42) }
        XCTAssertTrue(vm.isStacking)

        stacking.releaseStack()
        try await run.value

        XCTAssertEqual(vm.phase, .done)
        XCTAssertFalse(vm.isStacking)
    }

    /// `isStacking` gates the "this will throw away frames" cancel confirmation, so it must
    /// be true for exactly one phase.
    func testIsStackingIsTrueOnlyForTheStackingPhase() {
        let (vm, _, _) = makeViewModel()

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertFalse(vm.isStacking)
        vm.phase = .countdown(2)
        XCTAssertFalse(vm.isStacking)
        vm.phase = .capturing(frame: 1, of: 3)
        XCTAssertFalse(vm.isStacking)
        vm.phase = .stacking(0)
        XCTAssertTrue(vm.isStacking)
        vm.phase = .stacking(0.9)
        XCTAssertTrue(vm.isStacking)
        vm.phase = .done
        XCTAssertFalse(vm.isStacking)
    }

    // MARK: - What is forwarded to the service

    /// The format the Settings sheet holds is the format that gets written, and the frames
    /// are always deleted afterwards — the app's entire storage model is that only the
    /// final image is kept, so `deleteFramesAfter: false` here would silently retain a full
    /// bracket of RAW frames per capture.
    func testOutputFormatAndDeleteFramesAfterAreForwarded() async throws {
        XCTAssertEqual(AppConfig.Stacking.OutputFormat.allCases, [.jpeg, .png],
                       "premise: both formats are covered below")

        for format in AppConfig.Stacking.OutputFormat.allCases {
            let (vm, stacking, _) = makeViewModel()
            vm.autoSaveToPhotos = false
            vm.outputFormat = format
            let set = makeSet()

            try await vm.stack(set: set)

            XCTAssertEqual(stacking.calls,
                           [FakeStackPersisting.Call.stackAndPersist(setID: set.id,
                                                                     outputFormat: format,
                                                                     deleteFramesAfter: true)],
                           "the view model must forward \(format.rawValue) and delete the frames")
        }
    }

    // MARK: - Auto-save to Photos

    /// The fully automatic flow: the exact encoded file on disk is the thing added to
    /// Photos, so the URL matters, not just that a save happened. The order matters too —
    /// the stack is persisted before Photos is touched, or a Photos add could race a file
    /// that isn't finished.
    func testAutoSaveAddsTheMergedFileToPhotos() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        let url = URL(fileURLWithPath: "/tmp/stackshot-fake/\(UUID().uuidString)/stacked.jpg")
        stacking.mergedFileURLResult = url
        let set = makeSet()

        try await vm.stack(set: set)

        XCTAssertEqual(stacking.calls, [
            .stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true),
            .mergedFileURL(setID: set.id, hasResult: true),
            .saveFileToPhotos(url)
        ])
        XCTAssertTrue(vm.resultSavedToPhotos)
        XCTAssertEqual(vm.phase, .done)
        XCTAssertNil(vm.errorMessage)
    }

    /// Auto-save off means the photo library is never consulted at all — not even asked for
    /// the merged file's URL, since that is what the `if autoSaveToPhotos` guard sits in
    /// front of.
    func testAutoSaveOffNeverTouchesPhotos() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = false
        let set = makeSet()

        try await vm.stack(set: set)

        XCTAssertEqual(stacking.calls,
                       [.stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true)])
        XCTAssertFalse(vm.resultSavedToPhotos)
        XCTAssertEqual(vm.phase, .done)
        XCTAssertNil(vm.errorMessage)
    }

    /// The rule this whole seam exists for: a Photos failure must not fail the stack.
    ///
    /// At the point `saveFileToPhotos` runs, the merged image is encoded, on disk, and
    /// recorded in the manifest, and the source frames have already been deleted — there is
    /// no re-stack path. Letting the error abort the flow would leave the owner with an
    /// alert, no review sheet, and a finished photo reachable only through the Library, for
    /// a cause (denied photo access) that has nothing to do with the stack. It is reported
    /// rather than swallowed, and `resultSavedToPhotos` must stay false so the manual Save
    /// button is still offered.
    func testAPhotosFailureIsReportedButStillLeavesTheStackDone() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        stacking.photosError = StackFlowError(message: "Photo library access was not granted.")
        let set = makeSet()

        try await vm.stack(set: set)

        XCTAssertEqual(vm.phase, .done, "a Photos failure must not abort a finished stack")
        XCTAssertTrue(vm.resultImage === stacking.output.merged)
        XCTAssertNotNil(vm.lastSet?.result)
        XCTAssertTrue(vm.anchorsFromPreviousCapture)
        XCTAssertFalse(vm.resultSavedToPhotos, "nothing reached Photos, so nothing may claim it did")
        XCTAssertEqual(vm.errorMessage, "Photo library access was not granted.",
                       "the failure is reported, not swallowed")
        XCTAssertEqual(discardCalls(stacking), [], "the stacked set must survive a Photos failure")
    }

    /// No merged file to save — the set came back without a result, so `mergedFileURL` is
    /// nil. Nothing is handed to Photos, nothing crashes on an unwrapped URL, and the stack
    /// still finishes.
    func testANilMergedFileURLSkipsPhotosAndStillFinishes() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        stacking.mergedFileURLResult = nil
        let set = makeSet()

        try await vm.stack(set: set)

        XCTAssertEqual(stacking.calls, [
            .stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true),
            .mergedFileURL(setID: set.id, hasResult: true)
        ])
        XCTAssertFalse(vm.resultSavedToPhotos)
        XCTAssertEqual(vm.phase, .done)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Failure

    /// An ordinary stacking failure propagates to the caller, publishes nothing, and — the
    /// load-bearing part — does NOT discard the set. The frames are still on disk at that
    /// point and are the only copy of the capture; deleting them on a plain failure would
    /// destroy what a retry could still use.
    func testAStackingFailurePropagatesWithoutDiscardingTheSet() async {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        stacking.stackError = StackFlowError(message: "Stacking engine failed: out of memory")
        let set = makeSet()

        do {
            try await vm.stack(set: set)
            XCTFail("expected the stacking failure to propagate")
        } catch let error as StackFlowError {
            XCTAssertEqual(error.message, "Stacking engine failed: out of memory")
        } catch {
            XCTFail("expected StackFlowError, got \(error)")
        }

        // Only the stack was attempted: no discard, and Photos was never consulted.
        XCTAssertEqual(stacking.calls,
                       [.stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true)])
        XCTAssertNil(vm.resultImage)
        XCTAssertNil(vm.depthMapImage)
        XCTAssertNil(vm.lastSet)
        XCTAssertFalse(vm.resultSavedToPhotos)
        XCTAssertFalse(vm.anchorsFromPreviousCapture)
        // `stack(set:)` deliberately leaves the phase alone on the way out — resetting it
        // is `captureStack()`'s job, which is what the next test covers.
        XCTAssertTrue(vm.isStacking)
    }

    /// The other half of the failure path: `captureStack()`'s catch is what turns a thrown
    /// stacking error into a reported message and a return to `.idle`, so the shutter comes
    /// back instead of the UI sitting on a progress bar forever.
    ///
    /// Reaching that catch means running a real bracket, which `captureStack()` builds
    /// itself against `StackStore.shared` — there is no seam for it. The bracket therefore
    /// writes a set into the test host's Documents directory, so this test records what was
    /// there beforehand and removes anything it added.
    func testCaptureStackReportsAStackingFailureAndReturnsToIdle() async {
        let (vm, stacking, camera) = makeViewModel()
        vm.autoSaveToPhotos = false
        stacking.stackError = StackFlowError(message: "Stacking engine failed: out of memory")

        let preexisting = Set(StackStore().loadAll().map(\.id))
        addTeardownBlock {
            let store = StackStore()
            for set in store.loadAll() where !preexisting.contains(set.id) {
                store.delete(set)
            }
        }

        camera.lenses = [LensInfo(id: "back.1x", name: "1x")]
        camera.currentLens = camera.lenses.first
        vm.exposureLocked = true
        vm.nearAnchor = 0.2
        vm.farAnchor = 0.8
        vm.stepCount = 3
        XCTAssertTrue(vm.canCapture, "premise: the shutter must be armed")

        vm.captureStack()
        // The bracket runs a start timer before its first frame, so this is a real wait.
        await settle("the stacking failure to be reported", timeout: 30) { vm.errorMessage != nil }

        XCTAssertEqual(vm.errorMessage, "Stacking engine failed: out of memory")
        XCTAssertEqual(vm.phase, .idle, "a failed stack must release the shutter")
        XCTAssertNil(vm.resultImage)
        XCTAssertNil(vm.lastSet)
        XCTAssertEqual(discardCalls(stacking), [],
                       "an ordinary failure must not delete the frames a retry needs")
        XCTAssertEqual(stacking.calls.count, 1, "only stackAndPersist was attempted")
    }

    // MARK: - Cancellation

    /// A cancelled stack discards the set, and rethrows so the caller can unwind.
    ///
    /// Discarding is deliberate and asymmetric with the failure case above: there is no
    /// re-stack path, so frames kept after a cancel would sit in the Library as a
    /// permanently "not stacked" row holding a full bracket's storage. A cancelled bracket
    /// already deletes its own directory; this keeps the two cancellation paths identical.
    func testCancellationDiscardsTheSetAndRethrows() async {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        stacking.gatesStack = true
        let set = makeSet()

        let run = Task { try await vm.stack(set: set) }
        await settle("the stack to start") { vm.isStacking }
        run.cancel()
        stacking.releaseStack()

        do {
            try await run.value
            XCTFail("expected CancellationError to be rethrown")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(stacking.calls, [
            .stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true),
            .discard(setID: set.id)
        ], "the cancelled set is discarded, and Photos is never reached")
        XCTAssertNil(vm.resultImage)
        XCTAssertNil(vm.lastSet)
        XCTAssertFalse(vm.resultSavedToPhotos)
        XCTAssertFalse(vm.anchorsFromPreviousCapture)
    }
}
