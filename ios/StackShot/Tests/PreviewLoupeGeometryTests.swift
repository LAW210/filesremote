import CoreImage
import CoreVideo
import UIKit
import XCTest
@testable import StackShot

/// The loupe's crop geometry, sampled at the frame's corners and edges.
///
/// `PreviewFrameProcessor.renderLoupe` slides the crop rectangle back inside the frame
/// rather than intersecting it. With `.intersection(extent)` a sample point near an edge
/// yields a *smaller, non-square* crop, which is then stretched to fill the loupe's fixed
/// square view — so the magnified image is squashed (2:1 at an edge, 4:1 at a corner)
/// while the label still claims 3.0×, on the one control whose entire job is judging
/// critical focus. Nothing else in the suite looks at the loupe's geometry, so reverting
/// the clamp is invisible today.
///
/// The assertions are deliberately about geometry, not centring: once the crop has been
/// slid inside the frame the sample point is no longer at its centre, and that is the
/// intended behaviour.
final class PreviewLoupeGeometryTests: XCTestCase {

    // Chosen so the crop maths is exact and the expected pixel dimensions are integers:
    // `screenPointWidth` equals the buffer width, so the frame-to-screen ratio is exactly
    // 1, and 170 / 2.5 = 68 with a half-side of 34 — every clamped origin below lands on a
    // whole pixel, so no rect ever has to be integralized on the way to a CGImage.
    private let width = 400
    private let height = 300
    private let magnification: CGFloat = 2.5

    /// The crop's side in frame pixels: what `renderLoupe` computes for these settings.
    private var expectedSide: CGFloat { AppConfig.Loupe.diameter / magnification }

    // MARK: - Tests

    /// The premise the expected sizes rest on. If `AppConfig.Loupe.diameter` ever changes
    /// to something that does not divide evenly, this says so instead of leaving the size
    /// assertions failing by a pixel for no visible reason.
    func testTheChosenSettingsGiveAWholePixelCrop() {
        XCTAssertEqual(expectedSide, expectedSide.rounded())
        XCTAssertLessThan(expectedSide, CGFloat(min(width, height)))
    }

    /// A corner is the worst case: intersecting there keeps only a quarter of the crop, so
    /// the loupe would show a half-width, half-height region blown up to the same square.
    func testACornerSampleStillProducesAFullSizeSquareCrop() throws {
        let processor = makeProcessor()
        let buffer = try makeCheckerboardBuffer()
        let expected = try pixelSize(of: try loupe(processor, at: CGPoint(x: 0.5, y: 0.5), from: buffer))

        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
            let image = try loupe(processor, at: corner, from: buffer)
            let size = try pixelSize(of: image)
            XCTAssertEqual(size.width, size.height, "corner \(corner) produced a non-square crop")
            XCTAssertEqual(size, expected,
                           "corner \(corner) produced a different-sized crop than a centre sample")
            // The crop was moved, not extended past the frame: anything outside the
            // frame's extent would come back transparent.
            let opaque = try isFullyOpaque(image)
            XCTAssertTrue(opaque, "corner \(corner) sampled outside the frame")
        }
    }

    /// The mid-edge cases, which are the ones actually hit in use — you check focus on the
    /// edge of a subject far more often than in the literal corner of the frame. Each of
    /// these is squashed on exactly one axis under `.intersection`, so squareness alone
    /// catches them.
    func testEdgeSamplesStillProduceFullSizeSquareCrops() throws {
        let processor = makeProcessor()
        let buffer = try makeCheckerboardBuffer()
        let expected = try pixelSize(of: try loupe(processor, at: CGPoint(x: 0.5, y: 0.5), from: buffer))

        for edge in [CGPoint(x: 0.5, y: 0),        // top
                     CGPoint(x: 0.5, y: 1),        // bottom
                     CGPoint(x: 0, y: 0.5),        // left
                     CGPoint(x: 1, y: 0.5)] {      // right
            let image = try loupe(processor, at: edge, from: buffer)
            let size = try pixelSize(of: image)
            XCTAssertEqual(size.width, size.height, "edge \(edge) produced a non-square crop")
            XCTAssertEqual(size, expected, "edge \(edge) produced a crop of a different size")
            let opaque = try isFullyOpaque(image)
            XCTAssertTrue(opaque, "edge \(edge) sampled outside the frame")
        }
    }

    /// The centre sample, pinned on its own: the crop is the side the magnification asks
    /// for, so the sizes the tests above compare against are the right ones rather than
    /// merely consistent with each other.
    func testACentreSampleCropsTheSideTheMagnificationAsksFor() throws {
        let processor = makeProcessor()
        let buffer = try makeCheckerboardBuffer()

        let size = try pixelSize(of: try loupe(processor, at: CGPoint(x: 0.5, y: 0.5), from: buffer))

        // `accuracy: 1` only because a CGImage is whole pixels and the crop side is a
        // CGFloat; the exact-equality assertions that matter are the comparisons between
        // samples above, which are unaffected by any rounding at this seam.
        XCTAssertEqual(size.width, expectedSide, accuracy: 1)
        XCTAssertEqual(size.height, expectedSide, accuracy: 1)
    }

    /// A magnification low enough that the requested crop is wider than the frame must
    /// collapse to the frame's short side and stay square — the other way the crop can
    /// stop being a square, and the reason `cropSide` takes a `min` before clamping.
    func testACropLargerThanTheFrameCollapsesToTheShortSideAndStaysSquare() throws {
        let processor = makeProcessor()
        processor.update { $0.loupeMagnification = 0.25 }   // 170 / 0.25 = 680 > 400
        let buffer = try makeCheckerboardBuffer()

        let size = try pixelSize(of: try loupe(processor, at: CGPoint(x: 0, y: 0), from: buffer))

        XCTAssertEqual(size.width, size.height)
        XCTAssertEqual(size.width, CGFloat(min(width, height)), accuracy: 1)
    }

    // MARK: - Helpers

    private func makeProcessor() -> PreviewFrameProcessor {
        let processor = PreviewFrameProcessor()
        processor.update {
            // Both overlays off: this test is about the crop rectangle, and peaking's
            // filter chain would put its own extent between the frame and the crop.
            $0.peakingEnabled = false
            $0.zebraEnabled = false
            $0.loupeMagnification = magnification
            $0.screenPointWidth = CGFloat(width)
            $0.screenPixelWidth = CGFloat(width)     // no viewfinder downscale
        }
        return processor
    }

    /// Renders one loupe image for `point`. `process` deliberately skips every other frame,
    /// so two frames are fed per sample and the processed one is the second — which keeps
    /// the parity stable across repeated calls.
    private func loupe(_ processor: PreviewFrameProcessor,
                       at point: CGPoint,
                       from buffer: CVPixelBuffer,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> UIImage {
        processor.update { $0.loupeCenter = point }
        _ = processor.process(buffer)
        let output = try XCTUnwrap(processor.process(buffer), file: file, line: line)
        return try XCTUnwrap(output.loupe, "no loupe image for \(point)", file: file, line: line)
    }

    /// Pixel dimensions of the rendered crop. `CGSize` rather than a tuple purely so
    /// `XCTAssertEqual` can compare two of them.
    private func pixelSize(of image: UIImage) throws -> CGSize {
        let cg = try XCTUnwrap(image.cgImage)
        return CGSize(width: cg.width, height: cg.height)
    }

    /// True when every pixel carries full alpha. A crop that reached past the frame's
    /// extent would be transparent there, so this is the "the crop is inside the frame"
    /// check — the source buffer is filled fully opaque.
    private func isFullyOpaque(_ image: UIImage) throws -> Bool {
        let cg = try XCTUnwrap(image.cgImage)
        let pixelWidth = cg.width, pixelHeight = cg.height
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drew else { throw LoupeTestError.couldNotReadBackPixels }
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] != 255 {
            return false
        }
        return true
    }

    /// An opaque 8px checkerboard, so the crop has real detail in it and a blank or
    /// out-of-frame region is distinguishable from a valid one.
    private func makeCheckerboardBuffer() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        kCVPixelFormatType_32BGRA,
                                        attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            throw LoupeTestError.couldNotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw LoupeTestError.couldNotCreatePixelBuffer
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let pixel = bytes + row * rowBytes + col * 4
                let light = ((row / 8) + (col / 8)) % 2 == 0
                let value: UInt8 = light ? 220 : 40
                pixel[0] = value        // B
                pixel[1] = value        // G
                pixel[2] = value        // R
                pixel[3] = 255          // A — opaque, which `isFullyOpaque` relies on
            }
        }
        return buffer
    }

    private enum LoupeTestError: Error {
        case couldNotCreatePixelBuffer
        case couldNotReadBackPixels
    }
}
