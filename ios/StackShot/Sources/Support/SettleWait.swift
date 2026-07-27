import Foundation

/// The poll-until-stable loop shared by the exposure and focus settle waits.
///
/// Both waits are the same shape — sample a device property, require a few consecutive
/// stable readings so a value passing through the target isn't mistaken for arrival, and
/// give up at a deadline — so they live here once rather than twice. Extracting them also
/// makes the loop testable: `CameraService` cannot run anywhere but a device, and the bug
/// this exists to prevent is invisible from the outside.
///
/// That bug: `Task.sleep` throws *immediately* on a cancelled task. Both loops used to wait
/// with `try? await Task.sleep(...)`, which swallowed the throw and left the deadline as the
/// only brake — so a cancelled settle stopped sleeping and spun as fast as it could read a
/// device property for the rest of its 1.5 s budget. Cancelling a bracket is exactly when
/// that happens, on a tripod-mounted phone sealed in a light box with nowhere to dump the
/// heat. `tick` returning false is how the loop is told to stop instead.
enum SettleWait {

    /// Consecutive in-tolerance samples required before the value counts as settled.
    /// Three at the 30 ms poll interval is ~90 ms of stability.
    static let defaultStableTicks = 3

    /// Polls `isSettled` until it reports `stableTicksRequired` consecutive true samples
    /// (returns true), the deadline passes (false), or `tick` reports that waiting should
    /// stop (false).
    ///
    /// - Parameters:
    ///   - deadline: when to give up.
    ///   - now: the clock, injectable so a test needn't wait in real time.
    ///   - tick: waits one poll interval. Returns false when the wait must stop — which is
    ///     what a cancelled task reports, and what keeps this from becoming a busy-spin.
    ///   - isSettled: samples the property being waited on.
    /// - Returns: true only when the value actually settled.
    static func poll(stableTicksRequired: Int = defaultStableTicks,
                     deadline: Date,
                     now: () -> Date = Date.init,
                     tick: () async -> Bool,
                     isSettled: () -> Bool) async -> Bool {
        var stableTicks = 0
        while now() < deadline {
            if isSettled() {
                stableTicks += 1
                if stableTicks >= stableTicksRequired { return true }
            } else {
                // Reset rather than decrement: the requirement is consecutive stability, so
                // a single wobble has to restart the count, not merely set it back one.
                stableTicks = 0
            }
            guard await tick() else { return false }
        }
        return false
    }

    /// The production tick: sleep one poll interval, reporting false if the task was
    /// cancelled. `Task.sleep` throws on cancellation, and that throw is the signal —
    /// discarding it is precisely the bug this type documents.
    static func sleepTick(nanoseconds: UInt64 = 30_000_000) async -> Bool {
        (try? await Task.sleep(nanoseconds: nanoseconds)) != nil
    }
}
