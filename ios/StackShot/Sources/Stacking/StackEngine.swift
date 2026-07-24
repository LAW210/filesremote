import CoreImage
import UIKit

/// A focus-stacking engine: takes N consecutive-focus frames, returns one merged image.
protocol StackEngine {
    var name: String { get }
    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> UIImage
}

enum StackEngineError: LocalizedError {
    case noFrames
    case decodeFailed(URL)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames to stack."
        case .decodeFailed(let url): return "Could not decode \(url.lastPathComponent)."
        case .engineFailed(let msg): return "Stacking engine failed: \(msg)"
        }
    }
}

/// Picks the best available engine: the embedded focus-stack C++ core when the app is built
/// with ENGINE_EMBEDDED (see scripts/fetch_engine.sh), otherwise the native Swift fallback.
enum StackEngineFactory {
    static func make() -> StackEngine {
        #if ENGINE_EMBEDDED
        return FocusStackCppEngine()
        #else
        return NativeDepthMapStacker()
        #endif
    }
}

#if ENGINE_EMBEDDED
/// Bridges to PetteriAimonen/focus-stack (MIT) + OpenCV via Bridge/FocusStackBridge.mm.
/// This is the Helicon-Method-B-analog path: per-pixel sharpest-source selection with
/// depth-map smoothing and ECC alignment.
final class FocusStackCppEngine: StackEngine {
    let name = "focus-stack (wavelet EDF + depth map)"

    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> UIImage {
        guard !frameURLs.isEmpty else { throw StackEngineError.noFrames }
        let paths = frameURLs.map(\.path)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSString?
                let result = FocusStackBridge.stackImages(
                    atPaths: paths,
                    progress: { p in progress(p.doubleValue) },
                    error: &error)
                if let result {
                    cont.resume(returning: result)
                } else {
                    cont.resume(throwing: StackEngineError.engineFailed((error as String?) ?? "unknown"))
                }
            }
        }
    }
}
#endif
