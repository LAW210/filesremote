import XCTest
@testable import StackShot

final class StackSetSummaryTests: XCTestCase {

    private func makeSet(frameCount: Int = 8,
                         evBias: Float? = nil,
                         kelvin: Float = 5000) -> StackSet {
        StackSet(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceModel: "iPhone15,2",
            lensID: "com.apple.avfoundation.test",
            exposure: .init(iso: 100, shutterSeconds: 1.0 / 60, evBias: evBias),
            whiteBalance: .init(kelvin: kelvin, tint: 0),
            range: .init(lensPositionNear: 0.2, lensPositionFar: 0.8, stepCount: frameCount),
            frames: (0..<frameCount).map {
                .init(index: $0,
                      lensPosition: 0.2,
                      fileName: "frame-\($0).dng",
                      capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            },
            result: nil
        )
    }

    func testSummaryWithEVBiasNamesFramesBiasAndKelvin() {
        XCTAssertEqual(makeSet(frameCount: 8, evBias: 1.0, kelvin: 5000).captureSummary,
                       "8 frames · EV +1.0 · 5000K")
    }

    /// Manifests written before EV compensation existed decode with a nil bias; the
    /// summary must simply omit the segment rather than printing a placeholder.
    func testSummaryWithoutEVBiasOmitsThatSegment() {
        XCTAssertEqual(makeSet(frameCount: 8, evBias: nil, kelvin: 5000).captureSummary,
                       "8 frames · 5000K")
    }

    /// Zero bias is a deliberate choice, not an absent one, so it stays visible.
    func testZeroEVBiasIsStillShown() {
        XCTAssertEqual(makeSet(frameCount: 8, evBias: 0, kelvin: 5000).captureSummary,
                       "8 frames · EV +0.0 · 5000K")
    }

    func testKelvinIsRenderedWithoutADecimalPoint() {
        XCTAssertEqual(makeSet(frameCount: 8, evBias: nil, kelvin: 3247.8).captureSummary,
                       "8 frames · 3247K")
    }

    func testFrameCountReflectsTheFramesActuallyCaptured() {
        XCTAssertTrue(makeSet(frameCount: 3, evBias: nil).captureSummary.hasPrefix("3 frames"))
    }

    /// A cancelled bracket can persist with nothing captured; the summary is shown in
    /// the library regardless, so it must render rather than assume at least one frame.
    func testEmptySetStillProducesASummary() {
        XCTAssertEqual(makeSet(frameCount: 0, evBias: nil, kelvin: 5000).captureSummary,
                       "0 frames · 5000K")
    }
}
