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
        /// Kept a modest fraction of screen width (roughly a third on a 390pt phone) —
        /// large enough to judge focus, small enough that it doesn't dominate the frame
        /// or bury the very region it's meant to be inspecting.
        static let diameter: CGFloat = 170
    }

    enum Exposure {
        /// Exposure compensation applied to the camera's own metering. Positive only:
        /// a light box is mostly white field, so the meter reads it as overexposure and
        /// darkens the subject — the correction is always upward. The device's own
        /// supported range is applied as a second clamp at set time.
        static let evBiasRange: ClosedRange<Float> = 0...3
        static let evBiasStep: Float = 1.0 / 3.0      // third-stop detents
        static let kelvinRange: ClosedRange<Float> = 2500...8000
        static let tintRange: ClosedRange<Float> = -50...50
        static let whiteBalancePresets: [(name: String, kelvin: Float)] = [
            ("Tungsten", 3200), ("LED", 5000), ("Daylight", 5600),
        ]
    }

    enum Stacking {
        /// The Swift fallback engine downscales to this to bound memory and CPU;
        /// the embedded C++ engine works at full resolution.
        static let fallbackMaxDimension: CGFloat = 2048
        /// Diagnostic artifact — PNG so the per-pixel frame indices stay exact.
        static let depthMapFileName = "depthmap.png"
        /// Written by `CaptureLog` and read back by `StackingService.captureLogURL(for:)`.
        /// Those lived as separate string literals in separate files: renaming one would
        /// have made the Library's "Capture log" button quietly stop appearing, with no
        /// error and no failing test.
        static let captureLogFileName = "capture-log.txt"

        /// Format of the final stacked image. Both are formats listing sites accept
        /// (eBay takes JPEG/PNG/TIFF/BMP/GIF/WebP — notably not HEIC): JPEG for
        /// direct upload, PNG as a lossless master for edit-then-export workflows
        /// (~4–6× larger, so the only JPEG generation is your editor's final export).
        enum OutputFormat: String, CaseIterable, Identifiable {
            case jpeg
            case png

            var id: String { rawValue }

            var mergedFileName: String {
                switch self {
                case .jpeg: return "stacked.jpg"
                case .png: return "stacked.png"
                }
            }

            var label: String {
                switch self {
                case .jpeg: return "JPEG (eBay-friendly)"
                case .png: return "PNG (lossless, for editing)"
                }
            }
        }

        static let jpegQuality: CGFloat = 0.95
    }
}
