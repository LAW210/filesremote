import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// The single path from "captured StackSet" to "persisted merged result", so the
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
    /// `outputFormat` controls the merged file's encoding (JPEG for listing sites, PNG
    /// as a lossless editing master). When `deleteFramesAfter` is true, the source RAW
    /// frames are removed once the merged result is safely on disk, leaving only the
    /// final image — a set with a result therefore has no frame files left.
    func stackAndPersist(_ set: StackSet,
                         outputFormat: AppConfig.Stacking.OutputFormat = .jpeg,
                         deleteFramesAfter: Bool = false,
                         progress: @escaping (Double) -> Void = { _ in }) async throws -> (set: StackSet, output: StackOutput) {
        // Appends to the same capture-log.txt the bracket wrote, so one file carries
        // the whole story from shutter to stacked file — useful for the owner to send
        // verbatim when a stack comes out soft or banded.
        let log = CaptureLog(directory: store.directory(for: set))
        let stackStart = Date()

        let engine = StackEngineFactory.make()
        let urls = set.frames.map { store.frameURL(set, $0) }
        let output = try await engine.stack(frameURLs: urls, progress: progress)
        let stackDuration = Date().timeIntervalSince(stackStart)

        // Encoding failure must surface: silently returning a resultless set would
        // look like success to the caller while nothing reached disk.
        guard let data = encode(output.merged, as: outputFormat, describing: set) else {
            throw StackEngineError.engineFailed(
                "could not encode the stacked image as \(outputFormat.rawValue.uppercased())")
        }

        let directory = store.directory(for: set)
        let fileName = outputFormat.mergedFileName
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)

        // A re-stack after switching formats would otherwise leave the previous
        // format's file behind with the manifest pointing at the new one.
        for other in AppConfig.Stacking.OutputFormat.allCases where other != outputFormat {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(other.mergedFileName))
        }

        // Non-fatal, deliberately. The depth map is a diagnostic — every other path
        // treats it as optional — and this write lands after the merged image is already
        // safely on disk but before the manifest records it. A throw here therefore
        // failed a stack that had actually succeeded: the user waited minutes, got an
        // error, and the finished image sat on disk unreachable, with no re-stack path.
        // Disk-full is exactly the case that hits this line first, since the depth PNG is
        // the largest thing written after the merged file.
        var depthMapFileName: String?
        if let depthData = output.depthMap?.pngData() {
            let depthFileName = AppConfig.Stacking.depthMapFileName
            let written = (try? depthData.write(to: directory.appendingPathComponent(depthFileName),
                                                options: .atomic)) != nil
            depthMapFileName = written ? depthFileName : nil
        }

        var updated = set
        updated.result = .init(mergedFileName: fileName,
                               engine: engine.name,
                               processedAt: Date(),
                               depthMapFileName: depthMapFileName)

        // Manifest first, frames second. If the manifest write fails (disk full is
        // plausible right after writing a full-size image), the source frames must
        // still exist — otherwise the set is stranded: no result to show and no
        // frames to retry from.
        try store.saveManifest(updated)

        if deleteFramesAfter {
            for frame in updated.frames {
                try? FileManager.default.removeItem(at: store.frameURL(updated, frame))
            }
        }

        log.line(String(
            format: "stack: engine=%@ duration=%.3fs format=%@ bytes=%d depthMap=%@ framesDeleted=%@",
            engine.name, stackDuration, outputFormat.rawValue.uppercased(), data.count,
            depthMapFileName != nil ? "yes" : "no", deleteFramesAfter ? "yes" : "no"))
        log.flush()

        return (updated, output)
    }

    /// Encodes via CGImageDestination so real EXIF/TIFF metadata (capture date, device,
    /// ISO, shutter) rides along — UIImage's jpegData()/pngData() strip everything,
    /// leaving files that Photos and editors can't date or attribute.
    private func encode(_ image: UIImage,
                        as format: AppConfig.Stacking.OutputFormat,
                        describing set: StackSet) -> Data? {
        guard let cg = image.cgImage else { return fallbackEncode(image, as: format) }

        let type: UTType = format == .jpeg ? .jpeg : .png

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

    /// URL of the capture log on disk, if one was actually written for this set — a
    /// failed bracket or a set captured before logging existed has none, so callers
    /// must not assume the file is there just because the set is.
    func captureLogURL(for set: StackSet) -> URL? {
        let url = store.directory(for: set)
            .appendingPathComponent(AppConfig.Stacking.captureLogFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Adds the merged file to the photo library AS-IS — the exact encoded bytes go in,
    /// with no decode/re-encode pass, so the quality-95 JPEG is never compressed twice.
    func saveFileToPhotos(_ url: URL) async throws {
        // `.limited` grants add-only writes just as `.authorized` does. Rejecting it
        // meant anyone on limited photo access got "access was not granted" after every
        // single capture, since auto-save is on by default — for a save that would
        // actually have succeeded.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosSaveError.notAuthorized }
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

