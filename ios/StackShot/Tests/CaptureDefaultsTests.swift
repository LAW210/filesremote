import XCTest
@testable import StackShot

final class CaptureDefaultsTests: XCTestCase {

    private let suiteName = "test.capture.defaults"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testUnsetLoadReturnsDocumentedDefaults() {
        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.evBias, 0)
        XCTAssertEqual(loaded.kelvin, 5000)
        XCTAssertEqual(loaded.stepCount, AppConfig.Bracket.defaultStepCount)
        XCTAssertEqual(loaded.peakingEnabled, true)
        XCTAssertEqual(loaded.zebraEnabled, false)
        XCTAssertEqual(loaded.outputFormat, .jpeg)
        XCTAssertEqual(loaded.autoSaveToPhotos, true)
        XCTAssertEqual(loaded.squareGuideEnabled, false)
    }

    func testRoundtripSaveThenLoadReturnsSameValues() {
        let original = CaptureDefaults(
            evBias: 2.0 / 3.0,      // must be inside evBiasRange, which is positive-only
            kelvin: 3200,
            stepCount: 12,
            peakingEnabled: false,
            zebraEnabled: true,
            outputFormat: .png,
            autoSaveToPhotos: false,
            squareGuideEnabled: true
        )
        original.save(to: defaults)

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.evBias, original.evBias)
        XCTAssertEqual(loaded.kelvin, original.kelvin)
        XCTAssertEqual(loaded.stepCount, original.stepCount)
        XCTAssertEqual(loaded.peakingEnabled, original.peakingEnabled)
        XCTAssertEqual(loaded.zebraEnabled, original.zebraEnabled)
        XCTAssertEqual(loaded.outputFormat, original.outputFormat)
        XCTAssertEqual(loaded.autoSaveToPhotos, original.autoSaveToPhotos)
        XCTAssertEqual(loaded.squareGuideEnabled, original.squareGuideEnabled)
    }

    func testUnrecognizedOutputFormatFallsBackToJPEG() {
        defaults.set("webp", forKey: "capture.outputFormat")

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.outputFormat, .jpeg)
    }

    func testOutOfRangePersistedValuesAreClampedOnLoad() {
        defaults.set(Float(-1), forKey: "capture.kelvin")
        defaults.set(999, forKey: "capture.stepCount")

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.kelvin, AppConfig.Exposure.kelvinRange.lowerBound)
        XCTAssertEqual(loaded.stepCount, AppConfig.Bracket.stepRange.upperBound)
    }

    func testOutOfRangeEVBiasIsClampedOnLoad() {
        defaults.set(Float(12), forKey: "capture.evBias")
        XCTAssertEqual(CaptureDefaults.load(from: defaults).evBias,
                       AppConfig.Exposure.evBiasRange.upperBound)

        defaults.set(Float(-12), forKey: "capture.evBias")
        XCTAssertEqual(CaptureDefaults.load(from: defaults).evBias,
                       AppConfig.Exposure.evBiasRange.lowerBound)
    }
}
