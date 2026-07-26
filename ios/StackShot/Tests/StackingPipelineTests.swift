import CoreImage
import UIKit
import XCTest
@testable import StackShot

/// The imaging pipeline, exercised with no camera and no phone: synthetic frames whose
/// sharp region is known by construction go through `NativeDepthMapStacker`, then through
/// `StackingService`'s persistence contract, then through the whole capture→stack spine
/// with `FakeCamera` standing in for AVFoundation.
///
/// Every test writes into its own temp root, so a `StackStore(root:)` here can never
/// touch the real Documents directory that `StackStore.shared` uses.
final class StackingPipelineTests: XCTestCase {

    private var root: URL!
    private var store: StackStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StackingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = StackStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Part 1: the stacker actually stacks

    /// The load-bearing claim of the whole app: for each region, the pixel comes from the
    /// frame that was sharp *there*. Three frames, each sharp in one vertical third and
    /// gaussian-blurred elsewhere, so the correct depth map is three flat bands with
    /// values 0, 127 and 255 (`255 * index / (frameCount - 1)`).
    ///
    /// Vertical bands specifically: they are invariant to any row-order flip between
    /// CGImage and the bitmap context we sample through, so a wrong answer here is a real
    /// wrong answer and not a coordinate-convention artifact.
    func testDepthMapPicksTheSharpFrameForEachRegion() async throws {
        let width = 240, height = 120, bands = 3
        let urls = try (0..<bands).map { band in
            try writeFrame(named: "band_\(band).png", width: width, height: height,
                           sharpBand: band, bandCount: bands)
        }

        let output = try await NativeDepthMapStacker().stack(frameURLs: urls) { _ in }
        let depth = try XCTUnwrap(output.depthMap)

        // 240px / 3 bands = 80px per band; sampling only the middle 48 columns keeps a
        // 16px margin either side of each boundary. That margin is the tolerance: the
        // sharpness map is a 9-tap box blur of a gaussian-blurred (radius 4) source, so
        // sharpness genuinely bleeds ~12px across a boundary and pixels there may be
        // attributed to the neighbouring frame. Inside the margin the attribution is
        // unambiguous, so the assertion is "the right region came from the right frame"
        // rather than anything about exact pixel values — hence the wide ±30-of-255
        // envelopes below rather than equality.
        let near = meanGray(of: depth, columns: 16..<64)
        let middle = meanGray(of: depth, columns: 96..<144)
        let far = meanGray(of: depth, columns: 176..<224)

        XCTAssertLessThan(near, 30, "left third should come from frame 0 (dark)")
        XCTAssertGreaterThan(middle, 97, "middle third should come from frame 1 (mid grey)")
        XCTAssertLessThan(middle, 157, "middle third should come from frame 1 (mid grey)")
        XCTAssertGreaterThan(far, 225, "right third should come from frame 2 (bright)")

        // Ordering, stated independently of the absolute values: near → far is monotonic.
        XCTAssertLessThan(near, middle)
        XCTAssertLessThan(middle, far)

        // Under the downscale threshold, so the merged image keeps the source dimensions.
        let merged = try XCTUnwrap(output.merged.cgImage)
        XCTAssertEqual(merged.width, width)
        XCTAssertEqual(merged.height, height)
    }

    /// Frames larger than `fallbackMaxDimension` are downscaled, so the merged result is
    /// bounded on its long edge with the aspect ratio preserved. A 2400x60 source keeps
    /// this cheap: it crosses the threshold without producing a multi-megapixel stack.
    func testOversizedFramesAreDownscaledToTheConfiguredMaxDimension() async throws {
        let maxDimension = Double(AppConfig.Stacking.fallbackMaxDimension)
        let sourceWidth = Int(maxDimension) + 352      // 2400 at the current 2048 setting
        let sourceHeight = 60
        let url = try writeFrame(named: "wide.png", width: sourceWidth, height: sourceHeight,
                                 sharpBand: 0, bandCount: 1)

        let output = try await NativeDepthMapStacker().stack(frameURLs: [url]) { _ in }
        let merged = try XCTUnwrap(output.merged.cgImage)

        let scale = maxDimension / Double(sourceWidth)
        // accuracy 2: Core Image integralizes a non-integral scaled extent, so the exact
        // rounding of 60 * 0.8533 is not a contract worth pinning.
        XCTAssertEqual(Double(merged.width), maxDimension, accuracy: 2)
        XCTAssertEqual(Double(merged.height), Double(sourceHeight) * scale, accuracy: 2)
    }

    func testStackingWithNoFramesThrowsNoFrames() async {
        do {
            _ = try await NativeDepthMapStacker().stack(frameURLs: []) { _ in }
            XCTFail("expected noFrames")
        } catch StackEngineError.noFrames {
            // expected
        } catch {
            XCTFail("expected noFrames, got \(error)")
        }
    }

    /// No alignment or padding happens here, so mismatched frames must be rejected rather
    /// than read out of bounds against the first frame's dimensions.
    func testMismatchedFrameSizesThrowEngineFailed() async throws {
        let first = try writeFrame(named: "a.png", width: 160, height: 120,
                                   sharpBand: 0, bandCount: 2)
        let second = try writeFrame(named: "b.png", width: 120, height: 120,
                                    sharpBand: 1, bandCount: 2)

        await assertThrowsEngineFailed {
            _ = try await NativeDepthMapStacker().stack(frameURLs: [first, second]) { _ in }
        }
    }

    /// The per-pixel source index is a `UInt8`, so frame 256 would trap on conversion.
    /// The guard runs before any decoding, which is why repeating one URL is enough.
    func testMoreThan256FramesThrowsRatherThanTrapping() async throws {
        let url = try writeFrame(named: "one.png", width: 32, height: 32,
                                 sharpBand: 0, bandCount: 1)
        let tooMany = [URL](repeating: url, count: 257)

        await assertThrowsEngineFailed {
            _ = try await NativeDepthMapStacker().stack(frameURLs: tooMany) { _ in }
        }
    }

    // MARK: - Part 2: StackingService persistence contract

    func testMergedFileIsNamedForTheFormatAndTheStaleFormatIsRemoved() async throws {
        let set = try makeSetOnDisk(frameCount: 2)
        let service = StackingService(store: store)
        let directory = store.directory(for: set)

        let jpegRun = try await service.stackAndPersist(set, outputFormat: .jpeg)
        XCTAssertEqual(jpegRun.set.result?.mergedFileName, "stacked.jpg")
        XCTAssertTrue(exists(directory.appendingPathComponent("stacked.jpg")))
        XCTAssertFalse(exists(directory.appendingPathComponent("stacked.png")))

        // Re-stacking in the other format must not leave the first file orphaned on disk
        // with the manifest pointing elsewhere.
        let pngRun = try await service.stackAndPersist(jpegRun.set, outputFormat: .png)
        XCTAssertEqual(pngRun.set.result?.mergedFileName, "stacked.png")
        XCTAssertTrue(exists(directory.appendingPathComponent("stacked.png")))
        XCTAssertFalse(exists(directory.appendingPathComponent("stacked.jpg")))
    }

    /// The ordering that keeps a set from being stranded with neither a result nor its
    /// frames: the manifest is written *before* the frames are deleted, so a failed
    /// manifest write must leave every frame in place to retry from.
    ///
    /// `StackStore` is final and `StackingService` takes a concrete store, so there is no
    /// seam to stub. Instead the failure is induced on disk: a non-empty *directory* is
    /// planted at the manifest.json path, which an atomic file write cannot replace. The
    /// first assertion pins that premise, so if the trick ever stops throwing this test
    /// fails loudly instead of passing vacuously.
    func testManifestIsSavedBeforeFramesAreDeleted() async throws {
        let set = try makeSetOnDisk(frameCount: 2)
        let directory = store.directory(for: set)
        let manifestPath = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: manifestPath, withIntermediateDirectories: true)
        try Data([0x00]).write(to: manifestPath.appendingPathComponent("blocker"))

        XCTAssertThrowsError(try store.saveManifest(set),
                             "premise: the planted directory must make saveManifest throw")

        let service = StackingService(store: store)
        var threw = false
        do {
            _ = try await service.stackAndPersist(set, deleteFramesAfter: true)
        } catch {
            threw = true
        }

        XCTAssertTrue(threw, "a failed manifest write must propagate, not be swallowed")
        for frame in set.frames {
            XCTAssertTrue(exists(store.frameURL(set, frame)),
                          "\(frame.fileName) must survive a failed manifest write")
        }
    }

    /// The frames are gone, but the manifest still describes them — that record is what
    /// the library UI renders and what a future re-stack would have to be told about.
    func testDeleteFramesAfterRemovesFramesButKeepsTheManifestRecord() async throws {
        let set = try makeSetOnDisk(frameCount: 2)
        let service = StackingService(store: store)

        let run = try await service.stackAndPersist(set, deleteFramesAfter: true)

        for frame in run.set.frames {
            XCTAssertFalse(exists(store.frameURL(run.set, frame)))
        }
        XCTAssertEqual(run.set.frames.count, 2)

        let persisted = try XCTUnwrap(store.loadAll().first { $0.id == set.id })
        XCTAssertEqual(persisted.frames.map(\.fileName), set.frames.map(\.fileName))
        XCTAssertNotNil(persisted.result)
        XCTAssertTrue(exists(store.directory(for: set)
            .appendingPathComponent(persisted.result?.mergedFileName ?? "")))
    }

    /// One capture-log file carries the whole story. Stacking opens its own `CaptureLog`
    /// over the same folder, so it must extend the bracket's lines rather than replace them.
    func testStackingAppendsToTheExistingCaptureLog() async throws {
        let set = try makeSetOnDisk(frameCount: 2)
        let seeded = CaptureLog(directory: store.directory(for: set))
        seeded.line("bracket start: device=Test lens=back-wide")
        seeded.line("frame 1/2: target=0.2000")
        seeded.flush()

        _ = try await StackingService(store: store).stackAndPersist(set)

        let lines = try logLines(for: set)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("bracket start: device=Test lens=back-wide"))
        XCTAssertTrue(lines[1].hasSuffix("frame 1/2: target=0.2000"))
        XCTAssertTrue(lines[2].contains("stack: engine="))
        XCTAssertTrue(lines[2].contains("framesDeleted=no"))
    }

    /// A failed bracket, or a set captured before logging existed, has no log — callers
    /// must not be handed a URL to a file that isn't there.
    func testCaptureLogURLIsNilWhenNoLogWasWritten() throws {
        let set = try makeSetOnDisk(frameCount: 1)
        XCTAssertNil(StackingService(store: store).captureLogURL(for: set))

        let log = CaptureLog(directory: store.directory(for: set))
        log.line("bracket start")
        log.flush()
        XCTAssertNotNil(StackingService(store: store).captureLogURL(for: set))
    }

    // MARK: - Part 3: end to end, no hardware

    /// The whole spine in one test: a bracket captured through the camera seam, then
    /// stacked and persisted, with nothing but a temp directory behind it.
    func testBracketThenStackProducesAMergedSetWithNoHardware() async throws {
        let fake = FakeCamera()
        // The fake's default payload is a single byte, which no decoder will accept.
        // Real encoded pixels are what makes the stacker reachable from this seam.
        let payload = try framePNGData(width: 160, height: 120, sharpBand: 0, bandCount: 1)
        fake.capturePhotoResult = (payload, false)
        let controller = FocusBracketController(camera: fake, store: store)
        let plan = FocusBracketController.Plan(near: 0.2, far: 0.8, stepCount: 3)

        let captured = try await controller.run(
            plan: plan,
            exposure: .init(iso: 100, shutterSeconds: 1.0 / 60.0, evBias: 1),
            whiteBalance: .init(kelvin: 5000, tint: 0),
            startTimerSeconds: 0,
            progress: { _ in })

        XCTAssertEqual(captured.frames.count, 3)
        for frame in captured.frames {
            XCTAssertTrue(exists(store.frameURL(captured, frame)))
        }

        let run = try await StackingService(store: store)
            .stackAndPersist(captured, outputFormat: .jpeg, deleteFramesAfter: true)

        let mergedURL = store.directory(for: run.set)
            .appendingPathComponent(run.set.result?.mergedFileName ?? "")
        XCTAssertEqual(run.set.result?.mergedFileName, "stacked.jpg")
        XCTAssertTrue(exists(mergedURL))
        let mergedData = try Data(contentsOf: mergedURL)
        XCTAssertGreaterThan(mergedData.count, 0)

        let persisted = try XCTUnwrap(store.loadAll().first { $0.id == captured.id })
        XCTAssertNotNil(persisted.result)
        XCTAssertEqual(persisted.frames.count, 3)
        for frame in persisted.frames {
            XCTAssertFalse(exists(store.frameURL(persisted, frame)))
        }

        let lines = try logLines(for: run.set)
        XCTAssertTrue(lines.contains { $0.contains("bracket start:") })
        XCTAssertTrue(lines.contains { $0.contains("frame 1/3:") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("outcome: completed") })
        XCTAssertTrue(lines.contains { $0.contains("stack: engine=") })
        XCTAssertTrue(lines.contains { $0.contains("framesDeleted=yes") })
    }

    // MARK: - Assertion helpers

    private func assertThrowsEngineFailed(_ body: () async throws -> Void,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected engineFailed", file: file, line: line)
        } catch StackEngineError.engineFailed(_) {
            // expected
        } catch {
            XCTFail("expected engineFailed, got \(error)", file: file, line: line)
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func logLines(for set: StackSet) throws -> [String] {
        let url = store.directory(for: set).appendingPathComponent("capture-log.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Fixtures

    /// A StackSet whose frames are real PNGs on disk in `store`, each sharp in its own
    /// vertical band. No manifest is written — the tests that care about the manifest
    /// write it (or deliberately break it) themselves.
    private func makeSetOnDisk(frameCount: Int, width: Int = 160, height: Int = 120) throws -> StackSet {
        var set = StackSet(
            id: UUID(),
            createdAt: Date(),
            deviceModel: "iPhone15,2",
            lensID: "back-wide",
            exposure: .init(iso: 100, shutterSeconds: 1.0 / 60.0, evBias: 1),
            whiteBalance: .init(kelvin: 5000, tint: 0),
            range: .init(lensPositionNear: 0.2, lensPositionFar: 0.8, stepCount: frameCount),
            frames: [],
            result: nil)
        let directory = try store.createDirectory(for: set)

        for i in 0..<frameCount {
            let fileName = String(format: "frame_%02d.png", i)
            let data = try framePNGData(width: width, height: height,
                                        sharpBand: i, bandCount: frameCount)
            try data.write(to: directory.appendingPathComponent(fileName))
            set.frames.append(.init(index: i, lensPosition: Float(i) / Float(max(frameCount - 1, 1)),
                                    fileName: fileName, capturedAt: Date()))
        }
        return set
    }

    @discardableResult
    private func writeFrame(named name: String, width: Int, height: Int,
                            sharpBand: Int, bandCount: Int) throws -> URL {
        let directory = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try framePNGData(width: width, height: height,
                         sharpBand: sharpBand, bandCount: bandCount).write(to: url)
        return url
    }

    // MARK: - Synthetic image generation

    /// One synthetic "focus frame": a hard-edged checkerboard everywhere, gaussian-blurred
    /// everywhere except the `sharpBand`-th vertical band, which keeps the crisp original.
    /// The band is therefore the only region with high Laplacian energy in this frame.
    private func framePNGData(width: Int, height: Int, sharpBand: Int, bandCount: Int) throws -> Data {
        let sharp = try makeCheckerboard(width: width, height: height)
        let soft = try makeBlurred(sharp, radius: 4)

        let context = try makeRGBAContext(width: width, height: height)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(soft, in: full)

        let bandWidth = CGFloat(width) / CGFloat(bandCount)
        let band = CGRect(x: CGFloat(sharpBand) * bandWidth, y: 0,
                          width: bandWidth, height: CGFloat(height))
        context.saveGState()
        context.clip(to: band)
        context.draw(sharp, in: full)
        context.restoreGState()

        guard let composited = context.makeImage(),
              let data = UIImage(cgImage: composited).pngData() else {
            throw TestImageError.couldNotBuildImage
        }
        return data
    }

    /// Hard black/white 6px checkerboard: maximum contrast on both axes, so the engine's
    /// Laplacian sees a large, unambiguous signal wherever this survives unblurred.
    private func makeCheckerboard(width: Int, height: Int, square: Int = 6) throws -> CGImage {
        let context = try makeRGBAContext(width: width, height: height)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        for row in stride(from: 0, to: height, by: square) {
            for col in stride(from: 0, to: width, by: square) where ((row / square) + (col / square)) % 2 == 0 {
                context.fill(CGRect(x: col, y: row, width: square, height: square))
            }
        }
        guard let image = context.makeImage() else { throw TestImageError.couldNotBuildImage }
        return image
    }

    /// Gaussian blur at a radius comfortably larger than the checker period, which leaves
    /// the region near-flat and its Laplacian energy far below the sharp original's.
    private func makeBlurred(_ image: CGImage, radius: Double) throws -> CGImage {
        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            throw TestImageError.couldNotBuildImage
        }
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let blurred = CIContext().createCGImage(output.cropped(to: source.extent),
                                                      from: source.extent) else {
            throw TestImageError.couldNotBuildImage
        }
        return blurred
    }

    private func makeRGBAContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestImageError.couldNotBuildImage
        }
        return context
    }

    /// Mean luminance over a column range of a grayscale image. The depth map is written
    /// in device gray, and this reads it back through device gray, so no gamma conversion
    /// sits between the engine's byte and the value asserted on.
    private func meanGray(of image: UIImage, columns: Range<Int>) -> Double {
        guard let cg = image.cgImage else { return -1 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let range = columns.clamped(to: 0..<width)
        guard !range.isEmpty else { return -1 }
        var sum = 0.0
        for row in 0..<height {
            for col in range { sum += Double(pixels[row * width + col]) }
        }
        return sum / Double(height * range.count)
    }

    private enum TestImageError: Error {
        case couldNotBuildImage
    }
}
