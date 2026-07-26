import Foundation

extension Comparable {
    /// Constrains a value to a configured range — ISO and Kelvin to their device or
    /// `AppConfig` limits, focus and loupe magnification to their UI bounds, and so on.
    ///
    /// Deliberately not used for array-index boundary clamping (e.g. the box blur's
    /// edge padding in `NativeDepthMapStacker`): that is algorithmic edge handling,
    /// and raw `min`/`max` reads more honestly there.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
