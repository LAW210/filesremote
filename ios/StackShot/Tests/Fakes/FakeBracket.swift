import Foundation
@testable import StackShot

/// In-memory `BracketRunning` for tests: records the order of every call, lets a test script
/// the captured set or a failure, hands out the progress closure it was given, and can park
/// inside `run` until released. Nothing here touches the filesystem — no `StackStore`, no
/// directories, no frame files — so `captureStack()` can be driven end to end without
/// writing anything into the test host's Documents folder.
///
/// Every property is behind a lock, for the same reason `FakeCamera`'s and
/// `FakeStackPersisting`'s are: `run` is a nonisolated async member, so the `@MainActor`
/// caller hops off the main actor to reach it and the recorded calls genuinely arrive from
/// another thread. An unlocked `calls` array silently lost an append in exactly that
/// situation in `FakeCamera`, which read as a missing call and sent us hunting a bug in the
/// view model. A fake that drops evidence is worse than no fake.
final class FakeBracket: BracketRunning {

    /// One recorded call. `FocusBracketController.Progress`, `Plan`, `Exposure` and
    /// `WhiteBalance` are not `Equatable`, so the plan's three numbers are recorded here —
    /// they are what `captureStack()` derives from the anchors and the step count — and the
    /// rest is exposed as `lastExposure` / `lastWhiteBalance` for tests that want it.
    enum Call: Equatable {
        case run(near: Float, far: Float, stepCount: Int)
        case cancel
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

    /// Every call in order. That a cancel reached the bracket *while it was running* is only
    /// assertable against this, not against the end state — a capture that unwinds through
    /// `Task` cancellation alone looks identical from the outside.
    var calls: [Call] { withLock { _calls } }

    private var _madeCount = 0
    private var _lastCamera: CameraControlling?
    private var _lastExposure: StackSet.Exposure?
    private var _lastWhiteBalance: StackSet.WhiteBalance?

    /// How many times the view model asked for a bracket.
    ///
    /// This is the sharpest signal available for "how many brackets were started":
    /// `captureStack()` calls the factory synchronously, on the main actor, before it
    /// returns — so a second call that slipped past the shutter guard is visible immediately,
    /// with nothing to wait for and no cross-thread ordering to get wrong.
    var madeCount: Int { withLock { _madeCount } }

    /// The camera the factory was handed, so a test can check the view model passes its own.
    var lastCamera: CameraControlling? { withLock { _lastCamera } }

    /// The exposure the last `run` was given — the values that land in the set's manifest
    /// and, in production, in the merged file's EXIF.
    var lastExposure: StackSet.Exposure? { withLock { _lastExposure } }

    var lastWhiteBalance: StackSet.WhiteBalance? { withLock { _lastWhiteBalance } }

    /// A factory closure for `CameraViewModel(makeBracket:)` that hands out this fake and
    /// counts the asking. The same instance every time, deliberately: two brackets started
    /// against one camera is the bug being guarded against, and one shared log records both.
    var factory: (CameraControlling) -> BracketRunning {
        { camera in
            self.withLock {
                self._madeCount += 1
                self._lastCamera = camera
            }
            return self
        }
    }

    // MARK: - Scripted results

    private var _setToReturn: StackSet?
    private var _error: Error?
    private var _progressEvents: [FocusBracketController.Progress] = []
    private var _progressClosure: ((FocusBracketController.Progress) -> Void)?

    /// The set `run` returns. When nil, one synthesized from the plan — frames named but
    /// never written, since nothing in these tests decodes them.
    var setToReturn: StackSet? {
        get { withLock { _setToReturn } }
        set { withLock { _setToReturn = newValue } }
    }

    /// Thrown by `run` instead of returning. A `CancellationError` here is what a cancelled
    /// sweep throws; anything else is an ordinary bracket failure.
    var error: Error? {
        get { withLock { _error } }
        set { withLock { _error = newValue } }
    }

    /// Progress reported, in order, before `run` parks on the gate (if enabled) and returns.
    var progressEvents: [FocusBracketController.Progress] {
        get { withLock { _progressEvents } }
        set { withLock { _progressEvents = newValue } }
    }

    /// The `progress` closure the most recent `run` was handed, kept so a test can invoke a
    /// bracket tick at a moment of its choosing — in particular *after* the sweep has ended
    /// and stacking has begun, which is the delivery the view model's stage guard exists for
    /// and which no amount of waiting can otherwise reproduce.
    var progressClosure: ((FocusBracketController.Progress) -> Void)? {
        withLock { _progressClosure }
    }

    // MARK: - The mid-run gate

    private var _gateEnabled = false
    private var _gateReleased = false
    /// A list, not a single slot: if the shutter guard ever regresses, two `run` calls park
    /// here at once, and a single slot would drop the first continuation on the floor —
    /// turning a regression into a hang instead of a failing assertion.
    private var _gateContinuations: [CheckedContinuation<Void, Never>] = []

    /// When true, `run` reports its progress events and then parks until `releaseRun()`,
    /// so mid-capture state is observable without sleeping and hoping.
    var gatesRun: Bool {
        get { withLock { _gateEnabled } }
        set { withLock { _gateEnabled = newValue } }
    }

    /// Lets every parked `run` finish. Safe to call before one has reached the gate.
    func releaseRun() {
        let waiting = withLock { () -> [CheckedContinuation<Void, Never>] in
            _gateReleased = true
            let continuations = _gateContinuations
            _gateContinuations = []
            return continuations
        }
        for continuation in waiting { continuation.resume() }
    }

    private func waitForGate() async {
        guard withLock({ () -> Bool in _gateEnabled && !_gateReleased }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-check under the lock: `releaseRun()` may have landed between the guard above
            // and here, and a continuation parked after the release would never be resumed —
            // a hang rather than a failure.
            let alreadyReleased = withLock { () -> Bool in
                if _gateReleased { return true }
                _gateContinuations.append(continuation)
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    /// A StackSet describing the plan, with no files behind it.
    static func capturedSet(plan: FocusBracketController.Plan,
                            exposure: StackSet.Exposure,
                            whiteBalance: StackSet.WhiteBalance) -> StackSet {
        StackSet(
            id: UUID(),
            createdAt: Date(),
            deviceModel: "FakeBracket",
            lensID: "fake-lens",
            exposure: exposure,
            whiteBalance: whiteBalance,
            range: .init(lensPositionNear: plan.near,
                         lensPositionFar: plan.far,
                         stepCount: plan.stepCount),
            frames: plan.positions.enumerated().map { index, position in
                StackSet.Frame(index: index,
                               lensPosition: position,
                               fileName: String(format: "frame_%02d.dng", index),
                               capturedAt: Date())
            },
            result: nil)
    }

    // MARK: - BracketRunning

    func run(plan: FocusBracketController.Plan,
             exposure: StackSet.Exposure,
             whiteBalance: StackSet.WhiteBalance,
             progress: @escaping (FocusBracketController.Progress) -> Void) async throws -> StackSet {
        let events = withLock { () -> [FocusBracketController.Progress] in
            _calls.append(.run(near: plan.near, far: plan.far, stepCount: plan.stepCount))
            _lastExposure = exposure
            _lastWhiteBalance = whiteBalance
            _progressClosure = progress
            return _progressEvents
        }
        // Outside the lock: the view model's progress closure hops to the main actor, and a
        // test's closure may call back into the fake.
        for event in events { progress(event) }

        await waitForGate()
        // A real sweep notices a cancel raised while it was running, so this fake does too.
        try Task.checkCancellation()
        if let error = withLock({ () -> Error? in _error }) { throw error }

        return withLock { () -> StackSet in
            _setToReturn ?? FakeBracket.capturedSet(plan: plan,
                                                    exposure: exposure,
                                                    whiteBalance: whiteBalance)
        }
    }

    func cancel() {
        withLock { _calls.append(.cancel) }
    }
}
