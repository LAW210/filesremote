import Foundation

/// Persists the last-used capture settings across launches via `UserDefaults.standard`,
/// under a `"capture."` key prefix. Values are clamped to `AppConfig` ranges on load so
/// stale or out-of-range stored data can never put the UI in an invalid state.
struct CaptureDefaults {
    var iso: Float
    var shutterDenominator: Double
    var kelvin: Float
    var tint: Float
    var stepCount: Int
    var peakingEnabled: Bool

    private enum Key {
        static let iso = "capture.iso"
        static let shutterDenominator = "capture.shutterDenominator"
        static let kelvin = "capture.kelvin"
        static let tint = "capture.tint"
        static let stepCount = "capture.stepCount"
        static let peakingEnabled = "capture.peakingEnabled"
    }

    /// Loads persisted values, clamping to `AppConfig` ranges and falling back to
    /// sensible defaults when unset (`UserDefaults`'s numeric accessors return 0 for
    /// missing keys, so `object(forKey:)` is used to distinguish "unset" from "stored").
    static func load(from defaults: UserDefaults = .standard) -> CaptureDefaults {
        let iso: Float
        if let stored = defaults.object(forKey: Key.iso) as? Float {
            iso = stored.clamped(to: AppConfig.Exposure.isoRange)
        } else {
            iso = 100
        }

        let shutterDenominator: Double
        if let stored = defaults.object(forKey: Key.shutterDenominator) as? Double,
           AppConfig.Exposure.shutterDenominators.contains(stored) {
            shutterDenominator = stored
        } else {
            shutterDenominator = 60
        }

        let kelvin: Float
        if let stored = defaults.object(forKey: Key.kelvin) as? Float {
            kelvin = stored.clamped(to: AppConfig.Exposure.kelvinRange)
        } else {
            kelvin = 5000
        }

        let tint: Float
        if let stored = defaults.object(forKey: Key.tint) as? Float {
            tint = stored.clamped(to: AppConfig.Exposure.tintRange)
        } else {
            tint = 0
        }

        let stepCount: Int
        if let stored = defaults.object(forKey: Key.stepCount) as? Int {
            stepCount = stored.clamped(to: AppConfig.Bracket.stepRange)
        } else {
            stepCount = AppConfig.Bracket.defaultStepCount
        }

        let peakingEnabled: Bool
        if let stored = defaults.object(forKey: Key.peakingEnabled) as? Bool {
            peakingEnabled = stored
        } else {
            peakingEnabled = true
        }

        return CaptureDefaults(
            iso: iso,
            shutterDenominator: shutterDenominator,
            kelvin: kelvin,
            tint: tint,
            stepCount: stepCount,
            peakingEnabled: peakingEnabled
        )
    }

    /// Writes the current values back to `UserDefaults.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(iso, forKey: Key.iso)
        defaults.set(shutterDenominator, forKey: Key.shutterDenominator)
        defaults.set(kelvin, forKey: Key.kelvin)
        defaults.set(tint, forKey: Key.tint)
        defaults.set(stepCount, forKey: Key.stepCount)
        defaults.set(peakingEnabled, forKey: Key.peakingEnabled)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
