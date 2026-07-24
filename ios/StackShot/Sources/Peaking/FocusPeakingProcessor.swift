import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

/// Turns preview frames into (a) a viewfinder image with a focus-peaking overlay and
/// (b) a magnified loupe crop, both throttled to keep the UI responsive.
///
/// v1 uses Core Image (CIEdges + threshold + tint composited over the frame).
/// A Metal shader can replace this later without changing callers.
final class FocusPeakingProcessor {

    struct Output {
        let viewfinder: UIImage
        let loupe: UIImage?
        /// 64-bin luminance histogram, normalized to 0–1, for the exposure panel.
        let histogram: [Float]
    }

    /// Normalized loupe center in image coordinates (0–1, top-left origin); nil hides the loupe.
    var loupeCenter: CGPoint?
    var loupeMagnification: CGFloat = 3.0     // default 3x, pinchable 2x–6x
    var peakingEnabled = true
    var peakingThreshold: CGFloat = 0.3

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var busy = false

    /// Processes one frame; returns nil when the previous frame is still being processed.
    func process(_ pixelBuffer: CVPixelBuffer) -> Output? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let composited = peakingEnabled ? applyPeaking(to: source) : source

        guard let vfCG = context.createCGImage(composited, from: composited.extent) else { return nil }
        let viewfinder = UIImage(cgImage: vfCG)

        var loupe: UIImage?
        if let center = loupeCenter {
            loupe = renderLoupe(from: composited, center: center)
        }
        return Output(viewfinder: viewfinder, loupe: loupe,
                      histogram: luminanceHistogram(of: pixelBuffer))
    }

    private func applyPeaking(to source: CIImage) -> CIImage {
        let edges = CIFilter.edges()
        edges.inputImage = source
        edges.intensity = 4.0
        guard let edgeImage = edges.outputImage else { return source }

        // Keep only strong edges (in-focus detail), kill the rest.
        let mono = edgeImage.applyingFilter("CIColorControls",
                                            parameters: [kCIInputSaturationKey: 0,
                                                         kCIInputContrastKey: 2.0])
        let thresholded = mono.applyingFilter("CIColorThreshold",
                                              parameters: ["inputThreshold": peakingThreshold])
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
                total += 1
                col += stride
            }
            row += stride
        }
        guard let peak = counts.max(), peak > 0 else { return counts }
        return counts.map { $0 / peak }
    }

    private func renderLoupe(from image: CIImage, center: CGPoint) -> UIImage? {
        let extent = image.extent
        let sideOnScreen: CGFloat = 240
        let cropSide = sideOnScreen / loupeMagnification * (extent.width / UIScreen.main.bounds.width)
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
}
