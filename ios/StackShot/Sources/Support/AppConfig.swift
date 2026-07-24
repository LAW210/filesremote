import CoreGraphics

/// Central tuning knobs — every user-visible range and default lives here,
/// not scattered through views and controllers.
enum AppConfig {

    enum Bracket {
        static let defaultStepCount = 8
        static let stepRange = 3...20
        /// Damps button-press shake on the tripod before the sweep starts.
        static let startTimerSeconds = 2
    }

    enum Loupe {
        static let defaultMagnification: CGFloat = 3
        static let magnificationRange: ClosedRange<CGFloat> = 2...6
        static let diameter: CGFloat = 240
    }

    enum Exposure {
        static let isoRange: ClosedRange<Float> = 25...1600
        static let kelvinRange: ClosedRange<Float> = 2500...8000
        static let tintRange: ClosedRange<Float> = -50...50
        static let shutterDenominators: [Double] = [4, 8, 15, 30, 60, 125, 250, 500, 1000]
        static let whiteBalancePresets: [(name: String, kelvin: Float)] = [
            ("Tungsten", 3200), ("LED", 5000), ("Daylight", 5600),
        ]
    }

    enum Stacking {
        /// The Swift fallback engine downscales to this to bound memory and CPU;
        /// the embedded C++ engine works at full resolution.
        static let fallbackMaxDimension: CGFloat = 2048
        static let mergedFileName = "stacked.heic"
    }
}
