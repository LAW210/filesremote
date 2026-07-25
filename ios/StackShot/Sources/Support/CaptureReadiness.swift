import Foundation

/// Whether a focus bracket can start, and if not, which preconditions are missing.
///
/// Deliberately pure and outside both the view model and the view: the shutter's
/// enabled state and the hint underneath it are two renderings of one decision, and
/// if they were computed separately they could drift into contradicting each other —
/// a greyed-out button whose caption says everything is ready. One source, two uses.
enum CaptureReadiness {

    /// Every frame in a bracket must share one exposure, or the stack bands where
    /// frames disagree on brightness — hence the lock. The sweep also needs two
    /// distinct endpoints to interpolate between.
    static func canCapture(exposureLocked: Bool, near: Float?, far: Float?) -> Bool {
        guard exposureLocked, let near, let far else { return false }
        return near != far
    }

    /// Names only the preconditions still unmet, so a disabled shutter never reads as
    /// simply broken. Nil exactly when `canCapture` is true.
    static func blockedReason(exposureLocked: Bool, near: Float?, far: Float?) -> String? {
        guard !canCapture(exposureLocked: exposureLocked, near: near, far: far) else { return nil }

        var parts: [String] = []
        if !exposureLocked { parts.append("Lock exposure") }
        switch (near, far) {
        case let (.some(near), .some(far)) where near == far:
            parts.append("Near and Far must differ")
        case (.none, .none):
            parts.append("Set Near and Far")
        case (.none, .some):
            parts.append("Set Near")
        case (.some, .none):
            parts.append("Set Far")
        default:
            break
        }
        return parts.joined(separator: " · ")
    }
}
