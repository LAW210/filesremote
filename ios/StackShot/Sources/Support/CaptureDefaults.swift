import Foundation

/// Persists the last-used capture settings across launches via `UserDefaults.standard`,
/// under a `"capture."` key prefix. Values are clamped to `AppConfig` ranges on load so
/// stale or out-of-range stored data can never put the UI in an invalid state.
struct CaptureDefaults {
    var evBias: Float
    var kelvin: Float
    var stepCount: Int
    var peakingEnabled: Bool
    var zebraEnabled: Bool
    var outputFormat: AppConfig.Stacking.OutputFormat
    var autoSaveToPhotos: Bool
    var squareGuideEnabled: Bool

    enum Key {
        static let evBias = "capture.evBias"
        static let kelvin = "capture.kelvin"
        static let stepCount = "capture.stepCount"
        static let peakingEnabled = "capture.peakingEnabled"
        static let zebraEnabled = "capture.zebraEnabled"
        static let outputFormat = "capture.outputFormat"
        static let autoSaveToPhotos = "capture.autoSaveToPhotos"
        static let squareGuideEnabled = "capture.squareGuideEnabled"
    }

    /// Every key this type owns. Tests isolate exactly this surface, and having one list
    /// means a tenth setting added above is covered automatically rather than quietly
    /// leaking into whatever `UserDefaults` the tests happen to run against.
    static let allKeys = [
        Key.evBias, Key.kelvin, Key.stepCount, Key.peakingEnabled,
        Key.zebraEnabled, Key.outputFormat, Key.autoSaveToPhotos, Key.squareGuideEnabled,
    ]

    /// Loads persisted values, clamping to `AppConfig` ranges and falling back to
    /// sensible defaults when unset (`UserDefaults`'s numeric accessors return 0 for
    /// missing keys, so `object(forKey:)` is used to distinguish "unset" from "stored").
    static func load(from defaults: UserDefaults = .standard) -> CaptureDefaults {
        let evBias: Float
        if let stored = defaults.object(forKey: Key.evBias) as? Float {
            evBias = stored.clamped(to: AppConfig.Exposure.evBiasRange)
        } else {
            evBias = 0
        }

        let kelvin: Float
        if let stored = defaults.object(forKey: Key.kelvin) as? Float {
            kelvin = stored.clamped(to: AppConfig.Exposure.kelvinRange)
        } else {
            kelvin = 5000
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

        let zebraEnabled: Bool
        if let stored = defaults.object(forKey: Key.zebraEnabled) as? Bool {
            zebraEnabled = stored
        } else {
            zebraEnabled = false
        }

        // Unrecognized stored strings fall back to JPEG (the listing-site-safe default).
        let outputFormat = (defaults.string(forKey: Key.outputFormat)
            .flatMap(AppConfig.Stacking.OutputFormat.init(rawValue:))) ?? .jpeg

        let autoSaveToPhotos: Bool
        if let stored = defaults.object(forKey: Key.autoSaveToPhotos) as? Bool {
            autoSaveToPhotos = stored
        } else {
            autoSaveToPhotos = true
        }

        let squareGuideEnabled: Bool
        if let stored = defaults.object(forKey: Key.squareGuideEnabled) as? Bool {
            squareGuideEnabled = stored
        } else {
            squareGuideEnabled = false
        }

        return CaptureDefaults(
            evBias: evBias,
            kelvin: kelvin,
            stepCount: stepCount,
            peakingEnabled: peakingEnabled,
            zebraEnabled: zebraEnabled,
            outputFormat: outputFormat,
            autoSaveToPhotos: autoSaveToPhotos,
            squareGuideEnabled: squareGuideEnabled
        )
    }

    /// Writes the current values back to `UserDefaults.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(evBias, forKey: Key.evBias)
        defaults.set(kelvin, forKey: Key.kelvin)
        defaults.set(stepCount, forKey: Key.stepCount)
        defaults.set(peakingEnabled, forKey: Key.peakingEnabled)
        defaults.set(zebraEnabled, forKey: Key.zebraEnabled)
        defaults.set(outputFormat.rawValue, forKey: Key.outputFormat)
        defaults.set(autoSaveToPhotos, forKey: Key.autoSaveToPhotos)
        defaults.set(squareGuideEnabled, forKey: Key.squareGuideEnabled)
    }
}
