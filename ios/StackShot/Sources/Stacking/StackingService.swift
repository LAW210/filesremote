import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

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
    ///
    /// `outputFormat` controls the merged file's encoding (JPEG by default — listing
    /// sites like eBay don't accept HEIC). When `deleteFramesAfter` is true, the source
    /// RAW frames are removed once the merged result and manifest are safely on disk,
    /// leaving only the final image (the set is marked `framesPurged`, so re-stacking
    /// is no longer possible for it).
    func stackAndPersist(_ set: StackSet,
                         outputFormat: AppConfig.Stacking.OutputFormat = .jpeg,
                         deleteFramesAfter: Bool = false,
                         progress: @escaping (Double) -> Void = { _ in }) async throws -> (set: StackSet, output: StackOutput) {
        let engine = StackEngineFactory.make()
        let urls = set.frames.map { store.frameURL(set, $0) }
        let output = try await engine.stack(frameURLs: urls, progress: progress)

        var updated = set
        if let data = encode(output.merged, as: outputFormat, describing: set) {
            let fileName = outputFormat.mergedFileName
            try data.write(to: store.directory(for: set).appendingPathComponent(fileName),
                           options: .atomic)

            // A re-stack after switching formats would otherwise leave the previous
            // format's file behind with the manifest pointing at the new one.
            for other in AppConfig.Stacking.OutputFormat.allCases where other != outputFormat {
                try? FileManager.default.removeItem(
                    at: store.directory(for: set).appendingPathComponent(other.mergedFileName))
            }

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

            // Frames are deleted only after the merged file exists on disk, and the
            // purge is recorded in the same manifest write that records the result.
            if deleteFramesAfter {
                for frame in updated.frames {
                    try? FileManager.default.removeItem(at: store.frameURL(updated, frame))
                }
                updated.framesPurged = true
            }

            try store.saveManifest(updated)
        }
        return (updated, output)
    }

    /// Encodes via CGImageDestination so real EXIF/TIFF metadata (capture date, device,
    /// ISO, shutter) rides along — UIImage's jpegData()/pngData() strip everything,
    /// leaving files that Photos and editors can't date or attribute.
    private func encode(_ image: UIImage,
                        as format: AppConfig.Stacking.OutputFormat,
                        describing set: StackSet) -> Data? {
        guard let cg = image.cgImage else { return fallbackEncode(image, as: format) }

        let type: UTType
        switch format {
        case .jpeg: type = .jpeg
        case .png: type = .png
        case .heic: type = .heic
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return fallbackEncode(image, as: format)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"     // EXIF date format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = formatter.string(from: set.createdAt)

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [Int(set.exposure.iso)],
                kCGImagePropertyExifExposureTime: set.exposure.shutterSeconds,
                kCGImagePropertyExifDateTimeOriginal: dateString,
                kCGImagePropertyExifDateTimeDigitized: dateString,
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: set.deviceModel,
                kCGImagePropertyTIFFDateTime: dateString,
            ] as [CFString: Any],
        ]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = AppConfig.Stacking.jpegQuality
        }

        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return fallbackEncode(image, as: format)
        }
        return data as Data
    }

    /// Metadata-less fallback if CGImageDestination can't handle the input.
    private func fallbackEncode(_ image: UIImage, as format: AppConfig.Stacking.OutputFormat) -> Data? {
        switch format {
        case .jpeg: return image.jpegData(compressionQuality: AppConfig.Stacking.jpegQuality)
        case .png: return image.pngData()
        case .heic: return image.heicOrJPEGData()
        }
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

    /// URL of the merged file on disk, if the set has been stacked.
    func mergedFileURL(for set: StackSet) -> URL? {
        guard let result = set.result else { return nil }
        return store.directory(for: set).appendingPathComponent(result.mergedFileName)
    }

    /// Adds the merged file to the photo library AS-IS — the exact encoded bytes go in,
    /// with no decode/re-encode pass, so the quality-95 JPEG is never compressed twice.
    func saveFileToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else { throw PhotosSaveError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

enum PhotosSaveError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Photo library access was not granted."
        }
    }
}

extension UIImage {
    /// iOS 17's built-in heicData(), falling back to JPEG for exotic pixel formats.
    func heicOrJPEGData() -> Data? {
        heicData() ?? jpegData(compressionQuality: 0.95)
    }
}
