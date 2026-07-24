import Accelerate
import CoreImage
import UIKit

/// Pure-Swift fallback stacker used until the embedded C++ engine is wired in.
///
/// Method-B-style: for every pixel, measure local sharpness (Laplacian energy) in each
/// frame, smooth the sharpness maps, pick the sharpest source frame per pixel (a depth
/// map by construction, since frames are in near→far order), then composite.
/// No alignment — acceptable for the tripod-mounted v1 draft; the C++ engine adds ECC.
final class NativeDepthMapStacker: StackEngine {
    let name = "native depth-map (Swift fallback)"

    /// Frames are downscaled to this max dimension for the draft to bound memory.
    private let maxDimension: CGFloat = 2048

    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> UIImage {
        guard !frameURLs.isEmpty else { throw StackEngineError.noFrames }

        let context = CIContext()
        var rgbaFrames: [vImage_Buffer] = []
        var sharpness: [[Float]] = []
        var width = 0, height = 0

        defer { for buf in rgbaFrames { free(buf.data) } }

        for (i, url) in frameURLs.enumerated() {
            guard var ci = CIImage(contentsOf: url) else { throw StackEngineError.decodeFailed(url) }
            let scale = min(1, maxDimension / max(ci.extent.width, ci.extent.height))
            if scale < 1 { ci = ci.transformed(by: .init(scaleX: scale, y: scale)) }
            guard let cg = context.createCGImage(ci, from: ci.extent) else {
                throw StackEngineError.decodeFailed(url)
            }

            var format = vImage_CGImageFormat(
                bitsPerComponent: 8, bitsPerPixel: 32,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))!
            var buffer = vImage_Buffer()
            guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, cg, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                throw StackEngineError.decodeFailed(url)
            }
            if rgbaFrames.isEmpty {
                width = Int(buffer.width)
                height = Int(buffer.height)
            } else if Int(buffer.width) != width || Int(buffer.height) != height {
                free(buffer.data)
                throw StackEngineError.engineFailed("frame size mismatch at index \(i)")
            }
            rgbaFrames.append(buffer)
            sharpness.append(sharpnessMap(of: buffer, width: width, height: height))
            progress(0.7 * Double(i + 1) / Double(frameURLs.count))
        }

        // Per-pixel argmax over smoothed sharpness == the depth map.
        let count = width * height
        var bestIndex = [UInt8](repeating: 0, count: count)
        var bestValue = sharpness[0]
        for f in 1..<sharpness.count {
            let map = sharpness[f]
            for p in 0..<count where map[p] > bestValue[p] {
                bestValue[p] = map[p]
                bestIndex[p] = UInt8(f)
            }
        }
        bestIndex = medianSmooth(bestIndex, width: width, height: height)
        progress(0.85)

        // Composite: copy each pixel from its selected source frame.
        var out = [UInt8](repeating: 0, count: count * 4)
        for p in 0..<count {
            let src = rgbaFrames[Int(bestIndex[p])]
            let row = p / width, col = p % width
            let srcPtr = src.data.advanced(by: row * src.rowBytes + col * 4)
                .assumingMemoryBound(to: UInt8.self)
            for c in 0..<4 { out[p * 4 + c] = srcPtr[c] }
        }
        progress(1.0)

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { throw StackEngineError.engineFailed("could not build output image") }
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
