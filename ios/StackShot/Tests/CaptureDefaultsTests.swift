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
        XCTAssertEqual(loaded.iso, 100)
        XCTAssertEqual(loaded.shutterDenominator, 60)
        XCTAssertEqual(loaded.kelvin, 5000)
        XCTAssertEqual(loaded.tint, 0)
        XCTAssertEqual(loaded.stepCount, AppConfig.Bracket.defaultStepCount)
        XCTAssertEqual(loaded.peakingEnabled, true)
    }

    func testRoundtripSaveThenLoadReturnsSameValues() {
        let original = CaptureDefaults(
            iso: 400,
            shutterDenominator: 250,
            kelvin: 3200,
            tint: -12,
            stepCount: 12,
            peakingEnabled: false
        )
        original.save(to: defaults)

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.iso, original.iso)
        XCTAssertEqual(loaded.shutterDenominator, original.shutterDenominator)
        XCTAssertEqual(loaded.kelvin, original.kelvin)
        XCTAssertEqual(loaded.tint, original.tint)
        XCTAssertEqual(loaded.stepCount, original.stepCount)
        XCTAssertEqual(loaded.peakingEnabled, original.peakingEnabled)
    }

    func testOutOfRangePersistedValuesAreClampedOnLoad() {
        defaults.set(Float(999999), forKey: "capture.iso")
        defaults.set(Float(-1), forKey: "capture.kelvin")
        defaults.set(Float(9999), forKey: "capture.tint")
        defaults.set(999, forKey: "capture.stepCount")

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.iso, AppConfig.Exposure.isoRange.upperBound)
        XCTAssertEqual(loaded.kelvin, AppConfig.Exposure.kelvinRange.lowerBound)
        XCTAssertEqual(loaded.tint, AppConfig.Exposure.tintRange.upperBound)
        XCTAssertEqual(loaded.stepCount, AppConfig.Bracket.stepRange.upperBound)
    }

    func testUnrecognizedShutterDenominatorFallsBackToSixty() {
        defaults.set(Double(37), forKey: "capture.shutterDenominator")

        let loaded = CaptureDefaults.load(from: defaults)
        XCTAssertEqual(loaded.shutterDenominator, 60)
    }
}
