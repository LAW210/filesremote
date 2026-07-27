import Foundation
import UIKit
@testable import StackShot

/// In-memory `StackPersisting` for tests: records the order of every call, lets a test
/// script the returned set/output and per-method failures, and can suspend mid-stack so an
/// intermediate `.stacking` phase is observable. Nothing here touches the filesystem or the
/// photo library, so the whole post-capture path runs in CI instead of only on a phone.
///
/// Every property is behind a lock, for the same reason `FakeCamera`'s are:
/// `stackAndPersist` is a nonisolated async member, so a `@MainActor` caller hops off the
/// main actor to reach it and the recorded calls genuinely arrive from another thread. An
/// unlocked `calls` array silently lost an append in exactly that situation in `FakeCamera`,
/// which read as a missing call and sent us hunting a bug in the view model. A fake that
/// drops evidence is worse than no fake.
final class FakeStackPersisting: StackPersisting {

    /// One recorded call. The associated values are the arguments worth asserting on —
    /// notably `hasResult` on `mergedFileURL`, which is how a test can tell whether the
    /// view model passed the *updated* set (the one carrying `result`) or the stale input.
    enum Call: Equatable {
        case stackAndPersist(setID: UUID,
                             outputFormat: AppConfig.Stacking.OutputFormat,
                             deleteFramesAfter: Bool)
        case mergedFileURL(setID: UUID, hasResult: Bool)
        case saveFileToPhotos(URL)
        case discard(setID: UUID)
    }

    /// Recursive so a scripted closure can call back into the fake while a lock is held.
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Recorded calls

    private var _calls: [Call] = []

    /// Every call in order. Sequence-sensitive behaviour — the stack is persisted before
    /// Photos is touched — is only assertable against this, not against the end state.
    var calls: [Call] { withLock { _calls } }

    // MARK: - Scripted results

    private var _output: StackOutput
    private var _updatedSet: StackSet?
    private var _stackError: Error?
    private var _photosError: Error?
    private var _progressValues: [Double] = []
    private var _mergedFileURLResult: URL? = URL(fileURLWithPath: "/tmp/stackshot-fake/stacked.jpg")

    /// What `stackAndPersist` returns as its `StackOutput`. Defaults to a 1x1 merged image
    /// plus a 1x1 depth map — the view model only ever hands these on, so nothing needs to
    /// be decodable.
    var output: StackOutput {
        get { withLock { _output } }
        set { withLock { _output = newValue } }
    }

    /// The set `stackAndPersist` returns. When nil, the input set with a `result` attached,
    /// which is what the real service does.
    var updatedSet: StackSet? {
        get { withLock { _updatedSet } }
        set { withLock { _updatedSet = newValue } }
    }

    /// Thrown by `stackAndPersist` instead of returning. A `CancellationError` here is the
    /// cancelled-stack path; anything else is an ordinary failure.
    var stackError: Error? {
        get { withLock { _stackError } }
        set { withLock { _stackError = newValue } }
    }

    /// Thrown by `saveFileToPhotos` — the deliberately non-fatal failure.
    var photosError: Error? {
        get { withLock { _photosError } }
        set { withLock { _photosError = newValue } }
    }

    /// Values reported through the `progress` closure, in order, before `stackAndPersist`
    /// suspends on the gate (if enabled) and returns.
    var progressValues: [Double] {
        get { withLock { _progressValues } }
        set { withLock { _progressValues = newValue } }
    }

    /// What `mergedFileURL(for:)` returns. Set to nil for "nothing was stacked, so there is
    /// nothing to save".
    var mergedFileURLResult: URL? {
        get { withLock { _mergedFileURLResult } }
        set { withLock { _mergedFileURLResult = newValue } }
    }

    // MARK: - The mid-stack gate

    private var _gateEnabled = false
    private var _gateReleased = false
    private var _gateContinuation: CheckedContinuation<Void, Never>?

    /// When true, `stackAndPersist` reports its progress and then suspends until
    /// `releaseStack()` is called. That is what makes the intermediate `.stacking` phase
    /// observable without sleeping and hoping.
    var gatesStack: Bool {
        get { withLock { _gateEnabled } }
        set { withLock { _gateEnabled = newValue } }
    }

    /// Lets a gated `stackAndPersist` finish. Safe to call before it has reached the gate.
    func releaseStack() {
        let waiting = withLock { () -> CheckedContinuation<Void, Never>? in
            _gateReleased = true
            let continuation = _gateContinuation
            _gateContinuation = nil
            return continuation
        }
        waiting?.resume()
    }

    private func waitForGate() async {
        guard withLock({ () -> Bool in _gateEnabled && !_gateReleased }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-check under the lock: `releaseStack()` may have landed between the guard
            // above and here, and a continuation parked after the release would never be
            // resumed — a hang rather than a failure.
            let alreadyReleased = withLock { () -> Bool in
                if _gateReleased { return true }
                _gateContinuation = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    init(output: StackOutput? = nil) {
        _output = output ?? StackOutput(merged: FakeStackPersisting.pixel(.red),
                                        depthMap: FakeStackPersisting.pixel(.blue))
    }

    /// A 1x1 image — enough for anything that only carries a `UIImage` around.
    static func pixel(_ color: UIColor = .red) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// The input set with a `result` attached, i.e. what a successful real stack returns.
    static func stacked(_ set: StackSet,
                        format: AppConfig.Stacking.OutputFormat = .jpeg,
                        engine: String = "fake engine") -> StackSet {
        var updated = set
        updated.result = .init(mergedFileName: format.mergedFileName,
                               engine: engine,
                               processedAt: Date(),
                               depthMapFileName: AppConfig.Stacking.depthMapFileName)
        return updated
    }

    // MARK: - StackPersisting

    func stackAndPersist(_ set: StackSet,
                         outputFormat: AppConfig.Stacking.OutputFormat,
                         deleteFramesAfter: Bool,
                         progress: @escaping (Double) -> Void) async throws -> (set: StackSet, output: StackOutput) {
        let reported = withLock { () -> [Double] in
            _calls.append(.stackAndPersist(setID: set.id,
                                           outputFormat: outputFormat,
                                           deleteFramesAfter: deleteFramesAfter))
            return _progressValues
        }
        // Outside the lock: the view model's progress closure hops to the main actor, and
        // a test's closure may call back into the fake.
        for value in reported { progress(value) }

        await waitForGate()
        // A real engine notices a cancel raised while it was working, so this fake does
        // too — that is the path where the view model must discard the set.
        try Task.checkCancellation()
        if let error = withLock({ () -> Error? in _stackError }) { throw error }

        return withLock { () -> (set: StackSet, output: StackOutput) in
            (set: _updatedSet ?? FakeStackPersisting.stacked(set), output: _output)
        }
    }

    func mergedFileURL(for set: StackSet) -> URL? {
        withLock { () -> URL? in
            _calls.append(.mergedFileURL(setID: set.id, hasResult: set.result != nil))
            return _mergedFileURLResult
        }
    }

    func saveFileToPhotos(_ url: URL) async throws {
        if let error = withLock({ () -> Error? in
            _calls.append(.saveFileToPhotos(url))
            return _photosError
        }) {
            throw error
        }
    }

    func discard(_ set: StackSet) {
        withLock { _calls.append(.discard(setID: set.id)) }
    }
}
