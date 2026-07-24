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
    }

    /// Normalized loupe center in image coordinates (0–1); nil hides the loupe.
    var loupeCenter: CGPoint? = CGPoint(x: 0.5, y: 0.5)
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
        return Output(viewfinder: viewfinder, loupe: loupe)
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

        // Tint surviving edges bright green and composite over the source frame.
        let tint = CIImage(color: CIColor(red: 0.1, green: 1.0, blue: 0.2))
            .cropped(to: source.extent)
        let tintedEdges = tint.applyingFilter("CIBlendWithMask",
                                              parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                           kCIInputMaskImageKey: thresholded])
        return tintedEdges.composited(over: source)
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
