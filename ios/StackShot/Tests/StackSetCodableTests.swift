import XCTest
@testable import StackShot

final class StackSetCodableTests: XCTestCase {

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeStackSet(depthMapFileName: String?) -> StackSet {
        StackSet(
            id: UUID(),
            createdAt: Date(),
            deviceModel: "iPhone15,2",
            lensID: "back-wide",
            exposure: .init(iso: 100, shutterSeconds: 1.0 / 60.0),
            whiteBalance: .init(kelvin: 5000, tint: 0),
            range: .init(lensPositionNear: 0.2, lensPositionFar: 0.9, stepCount: 8,
                        spacingMode: "linearLensPosition"),
            frames: [
                .init(index: 0, lensPosition: 0.2, fileName: "frame_00.heic", capturedAt: Date()),
                .init(index: 1, lensPosition: 0.4, fileName: "frame_01.heic", capturedAt: Date()),
            ],
            result: .init(mergedFileName: "stacked.heic", engine: "swift-fallback",
                         processedAt: Date(), depthMapFileName: depthMapFileName)
        )
    }

    func testRoundtripWithDepthMapFileNameNil() throws {
        let original = makeStackSet(depthMapFileName: nil)
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(StackSet.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.result?.depthMapFileName, nil)
        XCTAssertEqual(decoded.frames.count, original.frames.count)
        XCTAssertEqual(decoded.range.stepCount, original.range.stepCount)
    }

    func testRoundtripWithDepthMapFileNameNonNil() throws {
        let original = makeStackSet(depthMapFileName: "depthmap.heic")
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(StackSet.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.result?.depthMapFileName, "depthmap.heic")
    }

    func testDecodingLegacyManifestWithoutDepthMapFileNameSucceeds() throws {
        let legacyJSON = """
        {
          "id": "9E3C6B2A-6B7F-4B2A-9C3E-1234567890AB",
          "createdAt": "2024-01-15T10:30:00Z",
          "deviceModel": "iPhone14,2",
          "lensID": "back-wide",
          "exposure": { "iso": 100, "shutterSeconds": 0.016666666666666666 },
          "whiteBalance": { "kelvin": 5000, "tint": 0 },
          "range": { "lensPositionNear": 0.2, "lensPositionFar": 0.9, "stepCount": 8, "spacingMode": "linearLensPosition" },
          "frames": [
            { "index": 0, "lensPosition": 0.2, "fileName": "frame_00.heic", "capturedAt": "2024-01-15T10:30:05Z" }
          ],
          "result": {
            "mergedFileName": "stacked.heic",
            "engine": "swift-fallback",
            "processedAt": "2024-01-15T10:30:10Z"
          }
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try makeDecoder().decode(StackSet.self, from: data)

        XCTAssertEqual(decoded.result?.mergedFileName, "stacked.heic")
        XCTAssertNil(decoded.result?.depthMapFileName)
    }
}
