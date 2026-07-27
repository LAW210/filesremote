import Accelerate
import CoreImage
import UIKit

/// Pure-Swift fallback stacker used until the embedded C++ engine is wired in.
///
/// Method-B-style: for every pixel, measure local sharpness (Laplacian energy) in each
/// frame, smooth the sharpness maps, pick the sharpest source frame per pixel (a depth
/// map by construction, since frames are in near→far order), then composite.
/// No alignment — acceptable for the tripod-mounted v1 draft; the C++ engine adds ECC.
///
/// **Cancellation granularity is one frame.** The checks sit at the frame boundaries of
/// both passes, not inside the per-pixel loops: `sharpnessMap` and `medianSmooth` are
/// non-throwing pure functions over flat arrays, and threading a cancellation check
/// through their inner loops would cost a branch per pixel to shave at most a couple of
/// seconds off the response. Cancelling therefore takes effect within roughly one frame's
/// processing time rather than instantly, which is the honest thing to promise the caller.
final class NativeDepthMapStacker: StackEngine {
    let name = "native depth-map (Swift fallback)"

    /// Frames are downscaled to this max dimension for the draft to bound memory.
    private let maxDimension = AppConfig.Stacking.fallbackMaxDimension

    /// Two passes over the frames, decoding each one twice, so only a single frame is
    /// ever resident. Holding all N frames plus all N sharpness maps at once cost
    /// ~25 MB per frame — ~200 MB for the default 8 and ~500 MB at the 20-frame
    /// maximum, which risks termination. Peak is now roughly 40 MB regardless of N.
    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> StackOutput {
        guard !frameURLs.isEmpty else { throw StackEngineError.noFrames }
        // The per-pixel source index is a UInt8, so frame 256 would trap on conversion.
        // The UI caps a bracket at 20, but this is a protocol entry point — turn an
        // unreachable-today crash into an error a caller can actually report.
        guard frameURLs.count <= 256 else {
            throw StackEngineError.engineFailed(
                "this engine supports at most 256 frames, got \(frameURLs.count)")
        }

        var width = 0, height = 0
        var bestValue: [Float] = []
        var bestIndex: [UInt8] = []

        // Pass 1: accumulate the per-pixel sharpest-frame index.
        for (i, url) in frameURLs.enumerated() {
            // Before the decode, so a cancelled run doesn't pay for a frame it will
            // discard. Throwing here leaves nothing to clean up: this engine writes no
            // files, and every buffer it owns is freed by the `defer` below.
            try Task.checkCancellation()
            let buffer = try decodeFrame(at: url)
            defer { free(buffer.data) }

            if i == 0 {
                width = Int(buffer.width)
                height = Int(buffer.height)
                bestIndex = [UInt8](repeating: 0, count: width * height)
            } else if Int(buffer.width) != width || Int(buffer.height) != height {
                throw StackEngineError.engineFailed("frame size mismatch at index \(i)")
            }

            let map = sharpnessMap(of: buffer, width: width, height: height)
            if i == 0 {
                bestValue = map
            } else {
                for p in 0..<map.count where map[p] > bestValue[p] {
                    bestValue[p] = map[p]
                    bestIndex[p] = UInt8(i)
                }
            }
            progress(0.6 * Double(i + 1) / Double(frameURLs.count))
        }
        bestValue = []      // no longer needed; release before the composite pass
        try Task.checkCancellation()
        bestIndex = medianSmooth(bestIndex, width: width, height: height)

        // Pass 2: re-decode each frame and copy only the pixels it won.
        let count = width * height
        var out = [UInt8](repeating: 0, count: count * 4)
        for (i, url) in frameURLs.enumerated() {
            try Task.checkCancellation()
            let buffer = try decodeFrame(at: url)
            defer { free(buffer.data) }
            let tag = UInt8(i)
            for p in 0..<count where bestIndex[p] == tag {
                let row = p / width, col = p % width
                let srcPtr = buffer.data.advanced(by: row * buffer.rowBytes + col * 4)
                    .assumingMemoryBound(to: UInt8.self)
                for c in 0..<4 { out[p * 4 + c] = srcPtr[c] }
            }
            progress(0.6 + 0.4 * Double(i + 1) / Double(frameURLs.count))
        }

        // Last gate before a result exists. Past this point the caller has an image and
        // will start writing files, so a cancellation noticed later would have to be
        // ignored rather than honoured.
        try Task.checkCancellation()

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { throw StackEngineError.engineFailed("could not build output image") }

        let depthMap = depthMapImage(from: bestIndex, width: width, height: height, frameCount: frameURLs.count)
        return StackOutput(merged: UIImage(cgImage: cg), depthMap: depthMap)
    }

    /// Decodes one frame, downscaled to `maxDimension`, into a freshly allocated
    /// premultiplied-RGBA buffer. The caller owns the buffer and must `free` its data.
    private func decodeFrame(at url: URL) throws -> vImage_Buffer {
        guard var ci = CIImage(contentsOf: url) else { throw StackEngineError.decodeFailed(url) }
        let scale = min(1, maxDimension / max(ci.extent.width, ci.extent.height))
        if scale < 1 { ci = ci.transformed(by: .init(scaleX: scale, y: scale)) }
        // A fresh context per frame keeps Core Image's internal caches from holding
        // every decoded frame alive for the duration of the stack.
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else {
            throw StackEngineError.decodeFailed(url)
        }

        var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))!
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, cg,
                                           vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw StackEngineError.decodeFailed(url)
        }
        return buffer
    }

    /// Renders the smoothed per-pixel source-frame index as a grayscale image:
    /// near (frame 0) is dark, far (last frame) is bright.
    private func depthMapImage(from bestIndex: [UInt8], width: Int, height: Int, frameCount: Int) -> UIImage? {
        let denom = max(frameCount - 1, 1)
        var gray = [UInt8](repeating: 0, count: width * height)
        for p in 0..<gray.count {
            gray[p] = UInt8(255 * Int(bestIndex[p]) / denom)
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Laplacian energy per pixel on the green channel, box-blurred so the depth map
    /// prefers coherent regions over speckle.
    private func sharpnessMap(of buffer: vImage_Buffer, width: Int, height: Int) -> [Float] {
        let count = width * height
        var gray = [Float](repeating: 0, count: count)
        for row in 0..<height {
            let rowPtr = buffer.data.advanced(by: row * buffer.rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                gray[row * width + col] = Float(rowPtr[col * 4 + 1])   // green channel
            }
        }

        var lap = [Float](repeating: 0, count: count)
        for row in 1..<(height - 1) {
            for col in 1..<(width - 1) {
                let p = row * width + col
                let v = 4 * gray[p] - gray[p - 1] - gray[p + 1] - gray[p - width] - gray[p + width]
                lap[p] = v * v
            }
        }

        // 9x9 box blur via two 1-D passes.
        var tmp = [Float](repeating: 0, count: count)
        let radius = 4
        for row in 0..<height {
            for col in 0..<width {
                var sum: Float = 0
                for d in -radius...radius {
                    let c = min(max(col + d, 0), width - 1)
                    sum += lap[row * width + c]
                }
                tmp[row * width + col] = sum
            }
        }
        var blurred = [Float](repeating: 0, count: count)
        for row in 0..<height {
            for col in 0..<width {
                var sum: Float = 0
                for d in -radius...radius {
                    let r = min(max(row + d, 0), height - 1)
                    sum += tmp[r * width + col]
                }
                blurred[row * width + col] = sum
            }
        }
        return blurred
    }

    /// 3x3 median on the index map to remove isolated wrong-frame picks.
    private func medianSmooth(_ index: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = index
        var window = [UInt8](repeating: 0, count: 9)
        for row in 1..<(height - 1) {
            for col in 1..<(width - 1) {
                var k = 0
                for dr in -1...1 {
                    for dc in -1...1 {
                        window[k] = index[(row + dr) * width + (col + dc)]
                        k += 1
                    }
                }
                window.sort()
                out[row * width + col] = window[4]
            }
        }
        return out
    }
}
