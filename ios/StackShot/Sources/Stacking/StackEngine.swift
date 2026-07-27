import UIKit

/// The result of a stacking run: the merged image plus an optional depth map
/// (per-pixel source-frame index, visualized as grayscale) when the engine produced one.
struct StackOutput {
    let merged: UIImage
    let depthMap: UIImage?
}

/// A focus-stacking engine: takes N consecutive-focus frames, returns one merged image.
///
/// Stacking is the longest wait in the app — minutes, on the phase where standing over a
/// light box with no way out is most likely to end in a force-quit. Implementations must
/// therefore honour `Task` cancellation and throw `CancellationError` rather than running
/// to completion, and must state their granularity: a pure-Swift engine can check between
/// frames, while a synchronous C-library bridge may only be able to check at its edges.
/// An engine that cannot be interrupted is still valid, but the UI can then only offer a
/// cancel that takes effect late, so say so rather than appearing responsive.
protocol StackEngine {
    var name: String { get }
    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> StackOutput
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
///
/// **Cancellation is edge-only.** `FocusStackBridge.stackImages` is a synchronous C++ call
/// with no interrupt hook, so a cancel raised mid-run cannot stop it — the work finishes and
/// its result is then discarded. That still matters: nothing is written to the stack's folder
/// and the UI returns to idle. It just does so when the engine finishes, not when the button
/// is tapped. Giving the bridge a real abort flag is the fix, and is not done here.
final class FocusStackCppEngine: StackEngine {
    let name = "focus-stack (wavelet EDF + depth map)"

    func stack(frameURLs: [URL], progress: @escaping (Double) -> Void) async throws -> StackOutput {
        guard !frameURLs.isEmpty else { throw StackEngineError.noFrames }
        try Task.checkCancellation()
        let paths = frameURLs.map(\.path)
        // Unique per run, so concurrent/overlapping stacks never read back another
        // run's stale or in-progress depth file — no pre-run delete needed.
        let depthMapPath = NSTemporaryDirectory().appending("stackshot_depth_\(UUID().uuidString).png")
        let merged: UIImage = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSString?
                let result = FocusStackBridge.stackImages(
                    atPaths: paths,
                    depthMapPath: depthMapPath,
                    progress: { p in progress(p.doubleValue) },
                    error: &error)
                if let result {
                    cont.resume(returning: result)
                } else {
                    cont.resume(throwing: StackEngineError.engineFailed((error as String?) ?? "unknown"))
                }
            }
        }
        // The C++ core writes its depth map alongside the merged result on a best-effort
        // basis; its absence is non-fatal, we just show no depth toggle. Clean up the
        // unique-per-run file after reading it so tmp doesn't accumulate.
        let depthMap = UIImage(contentsOfFile: depthMapPath)
        try? FileManager.default.removeItem(atPath: depthMapPath)
        // Clean up first, then honour a cancel that arrived while the bridge was working:
        // throwing before the removeItem above would leak the temp file for every
        // cancelled run.
        try Task.checkCancellation()
        return StackOutput(merged: merged, depthMap: depthMap)
    }
}
#endif
