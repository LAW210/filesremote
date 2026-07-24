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
/// v1 renders with Core Image; a Metal shader can replace `applyPeaking` without
/// changing callers.
final class PreviewFrameProcessor {

    struct Settings {
        /// Normalized loupe center (0–1, top-left origin); nil hides the loupe.
        var loupeCenter: CGPoint?
        var loupeMagnification: CGFloat = AppConfig.Loupe.defaultMagnification
        var peakingEnabled = true
        var peakingThreshold: CGFloat = 0.3
    }

    struct Output {
        let viewfinder: UIImage
        let loupe: UIImage?
        /// 64-bin luminance histogram, normalized to 0–1, for the exposure panel.
        let histogram: [Float]
    }

    private let lock = NSLock()
    private var settings = Settings()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Thread-safe settings mutation from any thread.
    func update(_ transform: (inout Settings) -> Void) {
        lock.withLock { transform(&settings) }
    }

    /// Processes one frame using a consistent snapshot of the settings.
    func process(_ pixelBuffer: CVPixelBuffer) -> Output? {
        let snapshot = lock.withLock { settings }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let composited = snapshot.peakingEnabled
            ? applyPeaking(to: source, threshold: snapshot.peakingThreshold)
            : source

        guard let vfCG = context.createCGImage(composited, from: composited.extent) else { return nil }
        let viewfinder = UIImage(cgImage: vfCG)

        var loupe: UIImage?
        if let center = snapshot.loupeCenter {
            loupe = renderLoupe(from: composited, center: center,
                                magnification: snapshot.loupeMagnification)
        }
        return Output(viewfinder: viewfinder, loupe: loupe,
                      histogram: luminanceHistogram(of: pixelBuffer))
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

    /// Cheap CPU histogram from a strided sample of the BGRA buffer (~16k samples/frame).
    private func luminanceHistogram(of pixelBuffer: CVPixelBuffer, bins: Int = 64) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [Float](repeating: 0, count: bins)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = max(1, width / 128)

        var counts = [Float](repeating: 0, count: bins)
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
                col += stride
            }
            row += stride
        }
        guard let peak = counts.max(), peak > 0 else { return counts }
        return counts.map { $0 / peak }
    }
}
