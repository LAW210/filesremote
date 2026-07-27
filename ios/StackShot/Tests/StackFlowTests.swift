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

    /// Runs the main-actor hops that are already enqueued, and nothing more.
    ///
    /// Tasks of equal priority on the main actor run in the order they were enqueued, so
    /// awaiting one enqueued now means every hop enqueued before it has already run. That
    /// ordering is what makes "the late tick was delivered, and then dropped" assertable:
    /// a bounded pile of `Task.yield()`s would leave "delivered and dropped" and "never
    /// delivered" looking identical, which is how a negative assertion becomes a free pass.
    private func drainMainActorHops() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
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

    /// A progress tick delivered after the stack has finished must be dropped, not applied.
    ///
    /// This is the regression the `reportStackProgress` guard exists for. Ticks are emitted
    /// from the engine's thread and delivered by a `Task { @MainActor }` hop, so a tick sent
    /// just before the engine returned can arrive *after* `phase = .done`. Applied blindly
    /// it reopened a finished stage: the review sheet never appeared, the progress bar sat
    /// over a photo that was already on disk, and `isStacking` armed the "this throws away
    /// frames" cancel confirmation — indistinguishable from a hang.
    ///
    /// The fake hands back the closure it was given, so the late delivery is an ordinary
    /// call at a moment this test picks rather than a race to reproduce.
    func testALateProgressTickIsDroppedRatherThanReopeningAFinishedStack() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = false
        let set = makeSet()

        try await vm.stack(set: set)
        XCTAssertEqual(vm.phase, .done)

        let tick = try XCTUnwrap(stacking.progressClosure, "the view model must pass a progress closure")
        tick(0.9)
        await drainMainActorHops()

        XCTAssertEqual(vm.phase, .done, "a tick delivered after the stack finished must be dropped")
        XCTAssertFalse(vm.isStacking)
        XCTAssertNotNil(vm.resultImage, "and it must not disturb the finished result")

        // Proof the assertion above is not vacuous: the very same closure, awaited through
        // the very same fence, *does* move the phase while stacking is still current. So
        // what dropped the tick was the guard — not a tick that was never delivered, and
        // not a fence too short to see it.
        vm.phase = .stacking(0.1)
        tick(0.55)
        await drainMainActorHops()
        XCTAssertEqual(vm.phase, .stacking(0.55),
                       "premise: this closure and this fence do apply a tick while stacking")
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

    /// A cancel that arrives during the auto-save is too late to mean anything, and must not
    /// be dressed up as a failure.
    ///
    /// By the time `saveFileToPhotos` runs, the merged image is encoded, on disk and in the
    /// manifest — the capture succeeded in every way that matters, and only the Photos copy
    /// was skipped. Routing that `CancellationError` through `report(error)` raised "The
    /// operation was cancelled" as an alert over a completed capture. Note the *absence* of
    /// a discard: this is the one place the two cancellation paths must behave differently,
    /// so folding these two catch arms back together would delete a finished set here.
    func testACancelDuringTheAutoSaveIsNotReportedAsAFailure() async throws {
        let (vm, stacking, _) = makeViewModel()
        vm.autoSaveToPhotos = true
        let url = URL(fileURLWithPath: "/tmp/stackshot-fake/\(UUID().uuidString)/stacked.jpg")
        stacking.mergedFileURLResult = url
        stacking.photosError = CancellationError()
        let set = makeSet()

        try await vm.stack(set: set)

        XCTAssertEqual(vm.phase, .done, "the stack is already on disk; a late cancel cannot undo it")
        XCTAssertTrue(vm.resultImage === stacking.output.merged)
        XCTAssertNotNil(vm.lastSet?.result)
        XCTAssertTrue(vm.anchorsFromPreviousCapture)
        XCTAssertFalse(vm.resultSavedToPhotos, "the Photos copy was skipped, so nothing may claim it")
        XCTAssertNil(vm.errorMessage, "a cancel is not a failure the owner needs an alert about")
        XCTAssertEqual(discardCalls(stacking), [],
                       "a cancelled *save* must not discard the set the way a cancelled stack does")
        // The save really was reached and really did throw — otherwise the arm under test
        // was never entered.
        XCTAssertEqual(stacking.calls, [
            .stackAndPersist(setID: set.id, outputFormat: vm.outputFormat, deleteFramesAfter: true),
            .mergedFileURL(setID: set.id, hasResult: true),
            .saveFileToPhotos(url)
        ])
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

    /// The other half of the failure path, plus what starting a capture must throw away.
    ///
    /// `captureStack()`'s catch is what turns a thrown stacking error into a reported message
    /// and a return to `.idle`, so the shutter comes back instead of the UI sitting on a
    /// progress bar forever. Reaching that catch means running a real bracket, which
    /// `captureStack()` builds itself against `StackStore.shared` — there is no seam for it.
    /// The bracket therefore writes a set into the test host's Documents directory, so this
    /// test records what was there beforehand and removes anything it added.
    ///
    /// The same run covers the previous result being cleared. `lastSet` is the one that
    /// mattered: `mergedFileURL` is derived from it, so a stale `lastSet` left the share and
    /// save actions pointing at the *previous* capture's file while `resultImage` was already
    /// nil — exporting the wrong photo, with nothing on screen to suggest it.
    func testCaptureStackClearsThePreviousResultAndReportsAStackingFailure() async {
        let (vm, stacking, camera) = makeViewModel()
        vm.autoSaveToPhotos = false

        let preexisting = Set(StackStore().loadAll().map(\.id))
        addTeardownBlock {
            let store = StackStore()
            for set in store.loadAll() where !preexisting.contains(set.id) {
                store.delete(set)
            }
        }

        // A finished capture to be superseded. Nothing here touches the filesystem — the
        // real bracket only enters below.
        let previous = makeSet()
        do {
            try await vm.stack(set: previous)
        } catch {
            XCTFail("the first stack must succeed: \(error)")
        }
        XCTAssertNotNil(vm.lastSet, "premise: there is a previous result to clear")
        XCTAssertNotNil(vm.resultImage)
        vm.dismissReview()          // what the UI does as the review sheet goes away

        stacking.stackError = StackFlowError(message: "Stacking engine failed: out of memory")
        camera.lenses = [LensInfo(id: "back.1x", name: "1x")]
        camera.currentLens = camera.lenses.first
        vm.exposureLocked = true
        vm.nearAnchor = 0.2
        vm.farAnchor = 0.8
        vm.stepCount = 3
        XCTAssertTrue(vm.canCapture, "premise: the shutter must be armed")

        vm.captureStack()

        // Synchronous, before the bracket has run a single frame: the clearing happens on
        // the way in, so there is no window where a stale set is still readable.
        XCTAssertNil(vm.lastSet, "a stale lastSet points share/save at the previous capture's file")
        XCTAssertNil(vm.mergedFileURL, "which is exactly what this derived URL would expose")
        XCTAssertNil(vm.resultImage)
        XCTAssertNil(vm.depthMapImage)
        XCTAssertFalse(vm.resultSavedToPhotos)

        // The bracket's own progress reaches the phase, which pins `reportBracketPhase`'s
        // applied branch. Deliberately `.capturing` and not `.countdown`: `captureStack()`
        // now claims `.countdown` synchronously on the way in — to close the double-tap
        // window — so waiting for that would be waiting for something this test's own call
        // already did, and would pass with the gate rejecting everything. `.capturing` can
        // only arrive through the gate. Matched as a pattern rather than compared to a
        // specific frame, so a fast fake can't race past frame 1 and time this out.
        await settle("the bracket's own progress to reach the phase", timeout: 20) {
            if case .capturing = vm.phase { return true }
            return false
        }

        await settle("the stacking failure to be reported", timeout: 30) { vm.errorMessage != nil }

        XCTAssertEqual(vm.errorMessage, "Stacking engine failed: out of memory")
        XCTAssertEqual(vm.phase, .idle, "a failed stack must release the shutter")
        XCTAssertNil(vm.resultImage)
        XCTAssertNil(vm.lastSet)
        XCTAssertEqual(discardCalls(stacking), [],
                       "an ordinary failure must not delete the frames a retry needs")
        XCTAssertEqual(stacking.calls.count, 2, "the first stack, then the failed one — nothing else")
    }

    /// A double-tap on the shutter must start exactly one bracket.
    ///
    /// `captureStack()` used to change nothing synchronously: the phase only left `.idle`
    /// when the bracket's first progress callback hopped back to the main actor, and the
    /// shutter is rendered for exactly as long as the phase is `.idle` with `canCapture`
    /// true. One fat-fingered press therefore ran the method twice inside that window and
    /// started two `FocusBracketController`s against one camera, each writing its own set,
    /// while `bracket` and `captureTask` pointed only at the second — leaving the first
    /// unstoppable, because `cancelCapture()` could not reach it.
    ///
    /// The two calls below have no `await` between them, which is the whole point: they land
    /// in that pre-hop window, exactly as the two taps did.
    func testDoubleTappingTheShutterStartsOnlyOneBracket() async {
        let (vm, stacking, camera) = makeViewModel()
        vm.autoSaveToPhotos = false

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
        XCTAssertEqual(vm.phase, .idle, "premise: the shutter is on screen, so a tap gets through")

        vm.captureStack()
        vm.captureStack()

        // A premise, not the assertion under test: the phase is claimed before the first
        // call returns, which is what leaves the second one nothing to slip through. It
        // would read the same if the second call had also run, so the counts below are what
        // actually decide the test.
        XCTAssertEqual(vm.phase, .countdown(AppConfig.Bracket.startTimerSeconds))

        await settle("the capture to finish", timeout: 40) { vm.phase == .done }

        // The observable is `FakeCamera`'s ordered call log, because it counts what reached
        // the *camera* — the single piece of hardware two brackets would have been
        // contending over — and nothing can retract an entry once it is in there. The
        // store-diff below is kept as a second, weaker check: `FocusBracketController`
        // deletes its own directory whenever a run doesn't complete and only saves its
        // manifest at the very end, so a second bracket that shot three real frames and
        // then unwound would leave the store showing exactly one set. That would be a false
        // pass on its own; the camera log cannot be undone that way.
        let captures = camera.calls.filter { $0 == .capturePhoto }.count
        XCTAssertEqual(captures, 3,
                       "one bracket of 3 frames; 6 capturePhoto calls means a second bracket ran")
        XCTAssertEqual(camera.calls.filter { $0 == .setFocus(lensPosition: 0.2) }.count, 1,
                       "and the sweep started once — two brackets both drive the lens to near")

        let created = Set(StackStore().loadAll().map(\.id)).subtracting(preexisting)
        XCTAssertEqual(created.count, 1, "one capture must leave one StackSet directory, not two")

        XCTAssertEqual(stacking.calls.count, 1, "and only one bracket reached the stacking stage")
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Known gap: a late *bracket* tick

    // `reportBracketPhase`'s drop branch — a `.countdown`/`.capturing` tick arriving after
    // `stack(set:)` has closed the bracket stage — is NOT covered here, and cannot honestly
    // be with the seams that exist.
    //
    // Its applied branch is covered above, by the `.capturing` phase the real bracket
    // produces. The drop branch needs a tick emitted before the bracket returned but
    // delivered after `bracketStageOver` was set. That closure is created inside
    // `captureStack()` and handed to a `FocusBracketController` the view model constructs
    // itself, so a test cannot hold it and call it late the way
    // `FakeStackPersisting.progressClosure` allows for the stacking tick. The only other
    // route is to race a real bracket's final `.capturing` hop against the start of
    // stacking, which is precisely the ordering nobody controls — a test built on winning
    // that race would pass or fail for reasons unrelated to the guard. Injecting the bracket
    // controller (or making the guard internal) is what this would need; a test that cannot
    // fail is worse than an admitted gap.

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
