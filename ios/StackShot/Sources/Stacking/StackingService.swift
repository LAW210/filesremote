import UIKit

/// The single path from "captured StackSet" to "persisted merged result".
/// Both the live capture flow and library re-stacking go through here, so the
/// manifest, file naming, and engine choice can never drift apart.
final class StackingService {
    static let shared = StackingService()

    private let store: StackStore

    init(store: StackStore = .shared) {
        self.store = store
    }

    /// Runs the best available engine over the set's frames, writes the merged image
    /// beside them, records it in the manifest, and returns the updated set + StackOutput.
    func stackAndPersist(_ set: StackSet,
                         progress: @escaping (Double) -> Void = { _ in }) async throws -> (set: StackSet, output: StackOutput) {
        let engine = StackEngineFactory.make()
        let urls = set.frames.map { store.frameURL(set, $0) }
        let output = try await engine.stack(frameURLs: urls, progress: progress)

        var updated = set
        if let data = output.merged.heicOrJPEGData() {
            let fileName = AppConfig.Stacking.mergedFileName
            try data.write(to: store.directory(for: set).appendingPathComponent(fileName),
                           options: .atomic)

            var depthMapFileName: String?
            if let depthData = output.depthMap?.heicOrJPEGData() {
                let depthFileName = AppConfig.Stacking.depthMapFileName
                try depthData.write(to: store.directory(for: set).appendingPathComponent(depthFileName),
                                    options: .atomic)
                depthMapFileName = depthFileName
            }

            updated.result = .init(mergedFileName: fileName,
                                   engine: engine.name,
                                   processedAt: Date(),
                                   depthMapFileName: depthMapFileName)
            try store.saveManifest(updated)
        }
        return (updated, output)
    }

    /// Loads a previously merged result from disk, if the set has one.
    func mergedImage(for set: StackSet) -> UIImage? {
        guard let result = set.result else { return nil }
        let url = store.directory(for: set).appendingPathComponent(result.mergedFileName)
        return UIImage(contentsOfFile: url.path)
    }

    /// Loads a previously saved depth map from disk, if the set has one.
    func depthMapImage(for set: StackSet) -> UIImage? {
        guard let result = set.result, let depthMapFileName = result.depthMapFileName else { return nil }
        let url = store.directory(for: set).appendingPathComponent(depthMapFileName)
        return UIImage(contentsOfFile: url.path)
    }

    func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}

extension UIImage {
    /// iOS 17's built-in heicData(), falling back to JPEG for exotic pixel formats.
    func heicOrJPEGData() -> Data? {
        heicData() ?? jpegData(compressionQuality: 0.95)
    }
}
