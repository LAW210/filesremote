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

    let camera: CameraControlling
    private let preview = PreviewFrameProcessor()
    private let stacking: StackPersisting
    /// Where the persisted capture settings live. Injected for the same reason the camera
    /// and the stacker are: tests used to scrub nine `capture.*` keys out of the real user
    /// store and put them back, which once shipped as a bug that wiped them for good.
    private let defaults: UserDefaults
    private var bracket: FocusBracketController?
    /// The bracket-then-stack run, kept so it can be cancelled. The bracket has its own
    /// `cancel()`, but stacking is a compute loop with no controller — the task handle is
    /// the only thing that reaches it.
    private var captureTask: Task<Void, Never>?

    // Live view
    @Published var viewfinderImage: UIImage?
    @Published var loupeImage: UIImage?
    @Published var loupeVisible = false
    /// Normalized (0–1, top-left origin) sample point the loupe is magnifying — mirrors
    /// `PreviewFrameProcessor.Settings.loupeCenter`, which the UI can't read directly,
    /// so the viewfinder can draw a reticle at the point actually being inspected.
    @Published private(set) var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    /// The single source of truth for loupe zoom — mirrored into the frame processor,
    /// and read by the loupe's label so the two can't disagree. See `scaleLoupe(by:)`.
    @Published private(set) var loupeMagnification = AppConfig.Loupe.defaultMagnification
    /// Magnification at the start of the current pinch.
    private var loupeGestureBase = AppConfig.Loupe.defaultMagnification
    @Published var errorMessage: String?
    /// True when `CameraService` fell back to synthetic preview frames because no
    /// physical camera was found (the Simulator). Read by the UI layer to draw a
    /// badge — the only contract between this view model and that badge.
    @Published private(set) var isPreviewMode = false

    // Lens
    @Published var lenses: [LensInfo] = []
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

    // Pushes to the device on change, like every other live control. Without this the
    // Kelvin slider did nothing until `lockExposure()` happened to apply it — you could
    // not see the colour you were choosing, which is the whole point of the control in a
    // fixed light box.
    @Published var kelvin: Float {
        didSet {
            pushWhiteBalance()
            persistDefaultsIfLoaded()
        }
    }
    @Published var exposureLocked = false

    // Focus
    @Published var lensPosition: Float = 0.5 { didSet { pushFocus() } }
    @Published var nearAnchor: Float?
    @Published var farAnchor: Float?

    // Bracket
    @Published var stepCount: Int { didSet { persistDefaultsIfLoaded() } }
    @Published var phase: Phase = .idle {
        didSet {
            // A resume deferred because the device was busy is owed until it happens.
            // Returning to idle is the moment it becomes safe.
            guard phase == .idle, needsResume else { return }
            needsResume = false
            scheduleResume()
        }
    }
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

    /// True while `start()` is in flight, so the launch `.task` and a `.active` retry
    /// can't configure the session twice at once.
    private var isStarting = false

    /// The most recent lens switch, so the next one can wait for it. See `selectLens`.
    private var lensSwitchTask: Task<Void, Never>?

    /// The session was stopped by a background trip and has not been brought back yet.
    /// `resumeSession()` is the only thing that restarts it after launch, so a resume
    /// that gets skipped is not retried by anything else — it has to be remembered.
    private var needsResume = false

    /// The most recent resume, so a second one waits rather than interleaving. Two
    /// resumes running at once can put a `lockExposure` between the other's settle and
    /// its white-balance write, and the lock would freeze the colour that was about to
    /// be replaced.
    private var resumeTask: Task<Void, Never>?

    /// Set while `kelvin` is being assigned from a device measurement, so its observer
    /// doesn't immediately push the rounded value back over it. See
    /// `lockGrayCardWB()`.
    private var suppressWhiteBalancePush = false

    /// Whether a neutral measurement has been taken on the current lens.
    ///
    /// Surfaced so the exposure panel can say so. Without it there is no way to tell a
    /// measured white balance from a coincidentally similar Kelvin value, and the one
    /// question that actually matters mid-setup — "did I already meter the backdrop,
    /// before I raised EV and put the reel back?" — had no answer anywhere on screen.
    @Published private(set) var neutralMeasured = false

    /// The green/magenta component of the last gray-card measurement, carried forward
    /// into subsequent white-balance writes.
    ///
    /// Tint is not a control — a fixed light box does not drift on that axis, and asking
    /// anyone to judge green versus magenta by eye is worse than measuring it. But the
    /// measurement genuinely finds one: cheap LED panels commonly have a green spike, and
    /// Kelvin cannot correct for it at any setting. Keeping the measured value here means
    /// nudging Kelvin afterwards re-derives gains that still include the cast the card
    /// found, instead of quietly resetting that axis to neutral.
    private var measuredTint: Float = 0

    /// True when the current anchors were carried over from a completed capture rather
    /// than set for what is in front of the camera now.
    ///
    /// Anchors deliberately survive a capture, so re-shooting the same reel at a different
    /// frame count is one tap. The hazard is the other case: swap the reel and the shutter
    /// is still armed with the previous product's focus planes, which would stack the
    /// wrong distances and look like the sweep misbehaving. Cleared the moment either
    /// anchor is set again.
    @Published private(set) var anchorsFromPreviousCapture = false

    /// Label for the lens button — the lens currently attached.
    var currentLensName: String {
        lenses.first { $0.id == selectedLensID }?.name ?? "—"
    }

    var canCapture: Bool {
        CaptureReadiness.canCapture(exposureLocked: exposureLocked,
                                    near: nearAnchor, far: farAnchor)
    }

    /// Why the shutter is disabled, or nil when it isn't — same decision as
    /// `canCapture`, so the button and its caption can never contradict each other.
    var captureBlockedReason: String? {
        CaptureReadiness.blockedReason(exposureLocked: exposureLocked,
                                       near: nearAnchor, far: farAnchor)
    }

    // MARK: - Lifecycle

    /// Every collaborator that reaches outside the process is injected, so tests can drive
    /// the control paths, the post-capture path and the persistence path with fakes; the
    /// defaults keep production call sites (`StackShotApp`) writing `CameraViewModel()`.
    init(camera: CameraControlling = CameraService(),
         stacking: StackPersisting = StackingService.shared,
         defaults: UserDefaults = .standard) {
        self.camera = camera
        self.stacking = stacking
        self.defaults = defaults
        let loaded = CaptureDefaults.load(from: defaults)
        _evBias = Published(initialValue: loaded.evBias)
        _kelvin = Published(initialValue: loaded.kelvin)
        _neutralMeasured = Published(initialValue: loaded.neutralMeasured)
        _stepCount = Published(initialValue: loaded.stepCount)
        _peakingEnabled = Published(initialValue: loaded.peakingEnabled)
        _zebraEnabled = Published(initialValue: loaded.zebraEnabled)
        _outputFormat = Published(initialValue: loaded.outputFormat)
        _autoSaveToPhotos = Published(initialValue: loaded.autoSaveToPhotos)
        _squareGuideEnabled = Published(initialValue: loaded.squareGuideEnabled)
        measuredTint = loaded.measuredTint
        isLoaded = true
    }

    /// Configures the camera and brings the session up. Safe to call again: the scene
    /// -phase handler retries this when nothing is configured, so the launch `.task` and
    /// the first `.active` can both land here, and a permission grant made in iOS
    /// Settings can be picked up on return. A second call while one is in flight is a
    /// no-op rather than a concurrent reconfiguration.
    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            try await camera.configure()
            isPreviewMode = camera.isPreviewMode
            lenses = camera.lenses
            selectedLensID = camera.currentLens?.id
            camera.onPreviewFrame = { [weak self] buffer in
                guard let self, let output = self.preview.process(buffer) else { return }
                Task { @MainActor in
                    self.viewfinderImage = output.viewfinder
                    self.loupeImage = output.loupe
                }
            }
            syncPreviewSettings()
            await camera.start()
            applyExposureBias()
            // The persisted colour temperature has to reach the device too, or the
            // viewfinder opens on the camera's own guess while the panel shows the
            // value from the last session. Focus likewise: a new device defaults to
            // continuous AF, so without this the slider reads 0.5 while the lens is
            // doing something else entirely — `resumeSession()` already pushed it, and
            // the two startup paths disagreeing is what made it easy to miss.
            pushWhiteBalance()
            pushFocus()
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
        // Claim the new lens before awaiting the hardware switch. `cycleLens()` derives
        // the next lens from this value, so leaving it stale until the await returned
        // meant two quick taps both computed the same target and the button advanced
        // one step instead of two. Restored below if the switch fails.
        let previousLensID = selectedLensID
        selectedLensID = id

        // Switches are chained rather than fired independently. `camera.select` is
        // nonisolated async, so two taps hop off the main actor and can reach the device
        // in either order — which left the hardware on one lens while `selectedLensID`
        // named another, permanently, until the next tap. Awaiting the previous switch
        // makes the last tap the one that wins, which is what the button appears to
        // promise. It costs one extra session reconfiguration on a double-tap; skipping
        // the intermediate lens would be nicer still, but `select` isn't cancellable
        // once it has begun and a half-applied switch is worse than a wasted one.
        let previousSwitch = lensSwitchTask
        lensSwitchTask = Task {
            await previousSwitch?.value
            do {
                try await camera.select(lens: lens)
            } catch {
                // Only the attach itself gets rolled back. The reconfiguration below can
                // fail on its own, and rolling back then would name a lens that IS
                // attached — leaving the button label, `currentLensName` and the next
                // `cycleLens()` all describing the wrong module while the new one is live.
                // Restore only if this is still the switch the UI is showing; a later tap
                // may already have claimed a different lens.
                // Roll back to what the service says is actually attached, not to the
                // lens the previous tap was aiming at. `previousLensID` is the optimistic
                // claim made at tap time, so with two failures in a row it names a lens
                // that was never attached either — reintroducing exactly the mismatch
                // this rollback exists to prevent.
                if selectedLensID == id { selectedLensID = camera.currentLens?.id ?? previousLensID }
                report(error)
                return
            }

            exposureLocked = false      // new module → re-set and re-lock exposure
            nearAnchor = nil
            farAnchor = nil
            torchEnabled = false        // torch belongs to the previous device
            measuredTint = 0            // and so does a neutral measurement
            neutralMeasured = false
            persistDefaults()           // or a relaunch would restore the stale one
            applyExposureBias()         // metering bias is per-device
            pushWhiteBalance()          // and so is white balance
            // The new device defaults to continuous AF. Push the slider's value
            // so the displayed focus actually matches the hardware; didSet won't
            // fire because lensPosition itself hasn't changed.
            do {
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

    /// Applies the chosen colour temperature to the device. Called at slider rate, so
    /// failures are swallowed rather than raised as an alert per tick — same reasoning
    /// as `pushFocus()`. There is no continuous-auto WB path in this app: colour is
    /// always the value shown in the panel.
    private func pushWhiteBalance() {
        guard !suppressWhiteBalancePush else { return }
        try? camera.setWhiteBalance(kelvin: kelvin, tint: measuredTint)
    }

    /// Freezes metering and white balance so every frame in the bracket matches.
    func lockExposure() {
        Task {
            do {
                try await freezeExposureAndWhiteBalance()
                exposureLocked = true
                persistDefaults()
            } catch {
                report(error)
            }
        }
    }

    /// Settle → lock → re-apply colour, in that order. Shared by the Lock button and by
    /// `resumeSession()`, which has to redo exactly the same thing after iOS hands the
    /// camera to another app: two copies of an order-sensitive sequence would eventually
    /// drift apart.
    private func freezeExposureAndWhiteBalance() async throws {
        await camera.waitForExposureSettle()
        lockedExposure = try camera.lockExposure()
        try camera.setWhiteBalance(kelvin: kelvin, tint: measuredTint)
    }

    /// Returns to live metering so the EV slider takes effect again.
    func unlockExposure() {
        exposureLocked = false
        lockedExposure = nil
        applyExposureBias()
    }

    /// Locks white balance from a neutral gray/white card filling the frame.
    ///
    /// The measured gray-world gains are what the device keeps. Reflecting the equivalent
    /// Kelvin back into the slider must therefore NOT push it out again: that
    /// would re-derive gains from numbers that have been round-tripped and clamped to the
    /// slider's range, quietly throwing away the measurement the card was held up for.
    /// A card reading outside `kelvinRange` shows the nearest value the slider can
    /// represent while the device holds the real one.
    func lockGrayCardWB() {
        do {
            let result = try camera.lockNeutralWhiteBalance()
            measuredTint = result.tint
            neutralMeasured = true
            withWhiteBalancePushSuppressed {
                kelvin = result.kelvin.clamped(to: AppConfig.Exposure.kelvinRange)
            }
            persistDefaults()
        } catch {
            report(error)
        }
    }

    /// Runs `body` with the `kelvin` observer's device push disabled, for the one
    /// case where the values are being set *from* the device rather than sent to it.
    private func withWhiteBalancePushSuppressed(_ body: () -> Void) {
        suppressWhiteBalancePush = true
        defer { suppressWhiteBalancePush = false }
        body()
    }

    // MARK: - Persistence

    private func persistDefaults() {
        CaptureDefaults(
            evBias: evBias,
            kelvin: kelvin,
            measuredTint: measuredTint,
            neutralMeasured: neutralMeasured,
            stepCount: stepCount,
            peakingEnabled: peakingEnabled,
            zebraEnabled: zebraEnabled,
            outputFormat: outputFormat,
            autoSaveToPhotos: autoSaveToPhotos,
            squareGuideEnabled: squareGuideEnabled
        ).save(to: defaults)
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

    /// Scales the loupe during a pinch, relative to where the gesture started.
    ///
    /// Magnification lives here rather than as `@State` in the loupe view. It used to be
    /// stored in both places: the view's copy reset to 3× every time the loupe was hidden
    /// and shown (SwiftUI re-initialises `@State` on a conditionally-built view) while the
    /// processor kept the pinched value, so the label read "3.0×" over a crop rendered at
    /// 6× and the next pinch multiplied from the wrong base. Same class of bug as a
    /// disabled shutter whose caption says it's ready — one decision, two renderings.
    func scaleLoupe(by factor: CGFloat) {
        loupeMagnification = (loupeGestureBase * factor)
            .clamped(to: AppConfig.Loupe.magnificationRange)
        preview.update { $0.loupeMagnification = loupeMagnification }
    }

    /// Ends a pinch, so the next one starts from where this one finished.
    func commitLoupeScale() {
        loupeGestureBase = loupeMagnification
    }

    /// Nudges magnification by a fixed step, for the loupe's ± buttons. Kept alongside
    /// `scaleLoupe(by:)` rather than replacing it so the multiplicative path stays
    /// available if a pinch is ever wanted again; both write the one stored value.
    func stepLoupeMagnification(by delta: CGFloat) {
        loupeMagnification = (loupeMagnification + delta)
            .clamped(to: AppConfig.Loupe.magnificationRange)
        loupeGestureBase = loupeMagnification
        preview.update { $0.loupeMagnification = loupeMagnification }
    }

    func markNear() {
        nearAnchor = lensPosition
        anchorsFromPreviousCapture = false
    }

    func markFar() {
        farAnchor = lensPosition
        anchorsFromPreviousCapture = false
    }

    // MARK: - Torch

    func setTorch(_ on: Bool) {
        do {
            try camera.setTorch(enabled: on)
            torchEnabled = on
        } catch {
            // Leave the flag alone: it still describes the torch's actual state, since
            // the change didn't happen. Forcing it to false here was right for a failed
            // switch-on (where it was already false) but wrong for a failed switch-off,
            // which would leave the torch lit while the icon claimed it was out.
            report(error)
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
        let wb = StackSet.WhiteBalance(kelvin: kelvin, tint: measuredTint)

        captureTask = Task {
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

    /// Aborts whatever stage the capture is in.
    ///
    /// The two stages need different mechanisms. During the bracket the controller owns the
    /// device and has to unwind its own configuration, so it is asked to stop. During
    /// stacking there is no device involved and the work is a long compute loop in the
    /// engine, which honours `Task` cancellation — so cancelling the task is what reaches
    /// it. Both are done unconditionally: the task also covers the window between the
    /// stages, and asking a finished bracket to cancel is a no-op.
    func cancelCapture() {
        bracket?.cancel()
        captureTask?.cancel()
    }

    /// True while a cancel would abandon a stack rather than a bracket — the case that also
    /// throws away frames already on disk, so the UI asks first.
    var isStacking: Bool {
        if case .stacking = phase { return true }
        return false
    }

    func stack(set: StackSet) async throws {
        phase = .stacking(0)
        let (updated, output): (StackSet, StackOutput)
        do {
            (updated, output) = try await stacking.stackAndPersist(
                set,
                outputFormat: outputFormat,
                deleteFramesAfter: true) { p in
                Task { @MainActor in self.phase = .stacking(p) }
            }
        } catch is CancellationError {
            // The frames are still on disk at this point and nothing can ever stack them:
            // there is no re-stack path, so keeping them would leave a permanent
            // "not stacked" row in the Library holding a full bracket's storage. A
            // cancelled bracket already deletes its own directory; this matches it.
            stacking.discard(set)
            throw CancellationError()
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
        // The anchors stay, so the same reel can be re-shot at a different frame count —
        // but they are now a carry-over, and the focus panel says so, because the next
        // subject may not be the one they were set on.
        anchorsFromPreviousCapture = true
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
            needsResume = true
            // Stopping the session extinguishes the torch in hardware; keep the UI
            // from claiming it is still on.
            if torchEnabled { torchEnabled = false }
        case .active:
            // Nothing configured yet. That is either the initial .active at launch,
            // which arrives before configure() completes and which start() handles
            // itself, or a configure() that failed — most often denied camera
            // permission. Retrying is what makes the second case recoverable: granting
            // access in iOS Settings and coming back used to leave the viewfinder on a
            // spinner forever, because .task never runs again and this guard returned.
            // Preview mode has no lenses by definition, so it can't be gated on those;
            // it still needs its synthetic frame timer restarted.
            guard !lenses.isEmpty || isPreviewMode else {
                Task { await start() }
                return
            }
            // Not while a bracket owns the device. `.active` also fires for trips that
            // never reach `.background` — a Control Center pull, a notification banner —
            // so nothing was stopped and there is nothing to resume, but re-applying
            // would write to the device from the main actor while the bracket is writing
            // to it from its own thread. That is an unbalanced `lockForConfiguration`
            // pair, which raises an ObjC exception Swift cannot catch. It would also
            // push the *slider's* focus position, which is stale mid-sweep, so the
            // frame in flight would be shot at the wrong distance.
            //
            // Deferred, not dropped. An earlier version simply returned here, which was
            // wrong: `resumeSession()` is the only thing that restarts the session after
            // launch, so a skipped resume was never retried by anything. Backgrounding
            // while the review sheet was up — an ordinary thing to do — left the
            // viewfinder dead until the app was backgrounded and foregrounded a second
            // time. The claim that a background trip always returns with `phase` back at
            // `.idle` was also false: `stop()` fails the pending capture asynchronously
            // and the bracket then spends up to 1.5 s in a settle wait, none of which
            // runs while suspended. `needsResume` survives instead, and `phase`'s
            // observer drains it on the way back to idle.
            //
            // `self.` is load-bearing: the parameter is also called `phase`, and it is a
            // ScenePhase, which has no `.idle`.
            guard self.phase == .idle else { return }
            needsResume = false
            scheduleResume()
        default:
            break
        }
    }

    /// Chains resumes so two never interleave, and so a deferred one runs after any
    /// resume already in flight.
    private func scheduleResume() {
        let previous = resumeTask
        resumeTask = Task {
            await previous?.value
            await resumeSession()
        }
    }

    /// Re-applies the manual locks after a background trip. iOS can hand the camera
    /// to another app while we are suspended and reset the device's exposure, white
    /// balance, and focus, which would silently un-lock a carefully metered setup.
    private func resumeSession() async {
        await camera.start()
        do {
            try camera.setExposureBias(evBias)
            if exposureLocked {
                // Re-freeze: iOS may have handed the camera to another app and reset
                // the device while we were suspended.
                //
                // If this throws, the flag must come down with it. Leaving it true put
                // the lock chip on green over a camera that was actually still metering
                // — and the shutter, which only asks for a lock when the flag is false,
                // would have let a bracket run and banded the stack. Better to make the
                // owner re-lock than to lie about the one precondition that matters.
                do {
                    try await freezeExposureAndWhiteBalance()
                } catch {
                    exposureLocked = false
                    lockedExposure = nil
                    throw error
                }
            } else {
                // Colour is a manual setting either way, so it has to be restored even
                // when exposure is live — otherwise a background trip silently reverts
                // the light box's white balance to whatever the device decides.
                try camera.setWhiteBalance(kelvin: kelvin, tint: measuredTint)
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
