import Foundation

/// The bracket, as `CameraViewModel` needs it: run a sweep, or abandon one.
///
/// `FocusBracketController` is the only production conformer. The protocol exists so the
/// view model can be handed a fake instead — without it, `captureStack()` could only be
/// exercised by running a real bracket against the real `StackStore`, which meant every
/// test of it wrote actual StackSet directories into the host's Documents folder and had to
/// delete them again afterwards. It also left one real fix untestable: a bracket progress
/// tick delivered *late*, after stacking had begun, must be dropped rather than reopening
/// the capture stage — and reproducing that needs the progress closure held and invoked at a
/// chosen moment, which is impossible when the view model constructs the controller itself.
protocol BracketRunning: AnyObject {
    func run(plan: FocusBracketController.Plan,
             exposure: StackSet.Exposure,
             whiteBalance: StackSet.WhiteBalance,
             progress: @escaping (FocusBracketController.Progress) -> Void) async throws -> StackSet
    func cancel()
}

extension FocusBracketController: BracketRunning {

    /// Bridges to the fuller signature, whose `startTimerSeconds` default the protocol can't
    /// carry — protocol requirements take no default arguments, and spelling the timer into
    /// the protocol would put a capture detail in a type that exists only to be faked.
    func run(plan: Plan,
             exposure: StackSet.Exposure,
             whiteBalance: StackSet.WhiteBalance,
             progress: @escaping (Progress) -> Void) async throws -> StackSet {
        try await run(plan: plan,
                      exposure: exposure,
                      whiteBalance: whiteBalance,
                      startTimerSeconds: AppConfig.Bracket.startTimerSeconds,
                      progress: progress)
    }
}
