import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

/// Turns camera preview frames into everything the live UI needs: a viewfinder image
/// with the focus-peaking overlay, the magnified loupe crop, and a luminance histogram.
///
/// Runs on the camera's video queue; settings are written from the main thread, so all
/// mutable state lives behind a lock and `process` works on an immutable snapshot.
///
/// To keep the video queue cheap, only every 2nd frame is processed (callers already
/// treat a nil result as "skip this frame"), and the viewfinder render is downscaled to
/// the screen's pixel size. Peaking still runs once on the full-resolution frame — the
/// loupe crops from that full-resolution peaked image, since judging critical focus is
/// its whole purpose — and only the final viewfinder image is produced at screen scale.
///
/// v1 renders with Core Image; a Metal shader can replace `applyPeaking` without
/// changing callers.
final class PreviewFrameProcessor {

    struct Settings {
        /// Normalized loupe center (0–1, top-left origin); nil hides the loupe.
        var loupeCenter: CGPoint?
        var loupeMagnification: CGFloat = AppConfig.Loupe.defaultMagnification
        var peakingEnabled = true
        var peakingThreshold: CGFloat = 0.3
        var zebraEnabled = false
    }

    struct Output {
        let viewfinder: UIImage
        let loupe: UIImage?
        /// 64-bin luminance histogram, normalized to 0–1, for the exposure panel.
        let histogram: [Float]
        /// Fraction of sampled pixels at/above luma 250 — blown highlights that no
        /// edit can recover. Chrome-in-a-light-box clips easily; surfaced in the UI.
        let clippedFraction: Float
    }

    private let lock = NSLock()
    private var settings = Settings()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// Every 2nd frame is skipped entirely to keep the video queue cheap.
    private var frameCounter = 0

    /// Thread-safe settings mutation from any thread.
    func update(_ transform: (inout Settings) -> Void) {
        lock.withLock { transform(&settings) }
    }

    /// Processes one frame using a consistent snapshot of the settings.
    func process(_ pixelBuffer: CVPixelBuffer) -> Output? {
        frameCounter += 1
        guard frameCounter % 2 == 0 else { return nil }

        let snapshot = lock.withLock { settings }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        var composited = snapshot.peakingEnabled
            ? applyPeaking(to: source, threshold: snapshot.peakingThreshold)
            : source
        if snapshot.zebraEnabled {
            composited = applyZebra(to: composited, source: source)
        }

        // Downscale only the viewfinder render to the screen's pixel size; peaking
        // above already ran once on the full-resolution frame.
        let screenScale = min(1, (UIScreen.main.bounds.width * UIScreen.main.scale) / source.extent.width)
        let displaySource = screenScale < 1
            ? composited.transformed(by: .init(scaleX: screenScale, y: screenScale))
            : composited

        guard let vfCG = context.createCGImage(displaySource, from: displaySource.extent) else { return nil }
        let viewfinder = UIImage(cgImage: vfCG)

        var loupe: UIImage?
        if let center = snapshot.loupeCenter {
            // Loupe samples from the full-resolution peaked image, not displaySource,
            // so critical focus judgments aren't degraded by the viewfinder downscale.
            loupe = renderLoupe(from: composited, center: center,
                                magnification: snapshot.loupeMagnification)
        }
        let (histogram, clipped) = luminanceHistogram(of: pixelBuffer)
        return Output(viewfinder: viewfinder, loupe: loupe,
                      histogram: histogram, clippedFraction: clipped)
    }

    // MARK: - Stages

    private func applyPeaking(to source: CIImage, threshold: CGFloat) -> CIImage {
        let edges = CIFilter.edges()
        edges.inputImage = source
        edges.intensity = 4.0
        guard let edgeImage = edges.outputImage else { return source }

        // Keep only strong edges (in-focus detail), kill the rest.
        let mono = edgeImage.applyingFilter("CIColorControls",
                                            parameters: [kCIInputSaturationKey: 0,
                                                         kCIInputContrastKey: 2.0])
        let thresholded = mono.applyingFilter("CIColorThreshold",
                                              parameters: ["inputThreshold": threshold])
            .cropped(to: source.extent)

        // White edges → green edges on black, then screen-blend over the source:
        // black is the identity for screen blending, so only edges light up.
        let tint = CIImage(color: CIColor(red: 0.1, green: 1.0, blue: 0.2))
            .cropped(to: source.extent)
        let greenEdges = thresholded.applyingFilter("CIMultiplyCompositing",
                                                    parameters: [kCIInputBackgroundImageKey: tint])
        return greenEdges.applyingFilter("CIScreenBlendMode",
                                         parameters: [kCIInputBackgroundImageKey: source])
    }

    /// Paints solid red over pixels that are clipped (blown highlights) in the SOURCE
    /// image's luminance, so the overlay reflects what the sensor actually captured,
    /// not the peaked/edge-enhanced composite. Screen-blending red onto near-white
    /// pixels wouldn't show (screen(white, red) ≈ white), so this uses CIBlendWithMask
    /// to replace clipped pixels outright.
    private func applyZebra(to image: CIImage, source: CIImage) -> CIImage {
        let mono = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let mask = mono.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.97])
            .cropped(to: source.extent)

        let red = CIImage(color: CIColor(red: 1.0, green: 0.0, blue: 0.0))
            .cropped(to: source.extent)

        return red.applyingFilter("CIBlendWithMask",
                                  parameters: [kCIInputBackgroundImageKey: image,
                                               kCIInputMaskImageKey: mask])
            .cropped(to: source.extent)
    }

    private func renderLoupe(from image: CIImage, center: CGPoint,
                             magnification: CGFloat) -> UIImage? {
        let extent = image.extent
        let sideOnScreen = AppConfig.Loupe.diameter
        let cropSide = sideOnScreen / magnification * (extent.width / UIScreen.main.bounds.width)
        let cx = extent.minX + center.x * extent.width
        let cy = extent.minY + (1 - center.y) * extent.height
        let cropRect = CGRect(x: cx - cropSide / 2, y: cy - cropSide / 2,
                              width: cropSide, height: cropSide)
            .intersection(extent)
        guard !cropRect.isEmpty else { return nil }

        let cropped = image.cropped(to: cropRect)
        guard let cg = context.createCGImage(cropped, from: cropRect) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Cheap CPU histogram from a strided sample of the BGRA buffer (~16k samples/frame),
    /// plus the fraction of sampled pixels at/above luma 250 (blown highlights).
    private func luminanceHistogram(of pixelBuffer: CVPixelBuffer,
                                    bins: Int = 64) -> (bins: [Float], clippedFraction: Float) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return ([Float](repeating: 0, count: bins), 0)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = max(1, width / 128)

        var counts = [Float](repeating: 0, count: bins)
        var clipped: Float = 0
        var total: Float = 0
        var row = 0
        while row < height {
            let rowPtr = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            var col = 0
            while col < width {
                let p = col * 4                      // BGRA
                let luma = 0.114 * Float(rowPtr[p]) + 0.587 * Float(rowPtr[p + 1])
                         + 0.299 * Float(rowPtr[p + 2])
                let bin = min(bins - 1, Int(luma) * bins / 256)
                counts[bin] += 1
                if luma >= 250 { clipped += 1 }
                total += 1
                col += stride
            }
            row += stride
        }
        let clippedFraction = total > 0 ? clipped / total : 0
        guard let peak = counts.max(), peak > 0 else { return (counts, clippedFraction) }
        return (counts.map { $0 / peak }, clippedFraction)
    }
}
