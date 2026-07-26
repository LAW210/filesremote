import Foundation

/// One captured focus-bracket session: N frames plus (optionally) a stacked result.
struct StackSet: Codable, Identifiable {
    struct Exposure: Codable {
        /// What the camera metered and locked to — the values that actually shot
        /// the frames, and what lands in EXIF.
        var iso: Float
        var shutterSeconds: Double
        /// The compensation the photographer dialled in. Optional so manifests
        /// written before EV compensation existed still decode.
        var evBias: Float?
    }

    struct WhiteBalance: Codable {
        var kelvin: Float
        var tint: Float
    }

    struct Range: Codable {
        var lensPositionNear: Float
        var lensPositionFar: Float
        var stepCount: Int
    }

    struct Frame: Codable {
        var index: Int
        var lensPosition: Float
        /// Relative to the StackSet directory.
        var fileName: String
        var capturedAt: Date
    }

    struct Result: Codable {
        var mergedFileName: String
        var engine: String
        var processedAt: Date
        /// Optional so manifests saved before the depth-map toggle still decode.
        var depthMapFileName: String?
    }

    var id: UUID
    var createdAt: Date
    var deviceModel: String
    var lensID: String
    var exposure: Exposure
    var whiteBalance: WhiteBalance
    var range: Range
    var frames: [Frame]
    /// Non-nil once stacking succeeded. Source frames are always deleted at that
    /// point, so a set with a result is final — its frame files no longer exist.
    var result: Result?

    /// One-line capture summary shared by the review sheet and the library detail.
    /// Surfaces what the photographer chose (EV bias) rather than ISO/shutter, which
    /// the camera metered internally and the owner doesn't want exposed in the UI.
    var captureSummary: String {
        var segments = ["\(frames.count) frames"]
        if let bias = exposure.evBias {
            segments.append(String(format: "EV %+.1f", bias))
        }
        segments.append("\(Int(whiteBalance.kelvin))K")
        return segments.joined(separator: " · ")
    }
}

/// Persists StackSets as folders of frames + manifest.json in the app sandbox.
final class StackStore {
    static let shared = StackStore()

    /// One name, written by `saveManifest` and read by `loadAll`. Held as separate
    /// literals, a rename would have emptied the Library silently — every stack still
    /// on disk, none of them listed, and nothing to point at the cause.
    private static let manifestFileName = "manifest.json"

    private let root: URL

    init(root: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? docs.appendingPathComponent("StackSets", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func directory(for set: StackSet) -> URL {
        root.appendingPathComponent(set.id.uuidString, isDirectory: true)
    }

    func createDirectory(for set: StackSet) throws -> URL {
        let dir = directory(for: set)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func saveManifest(_ set: StackSet) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(set)
        try data.write(to: directory(for: set).appendingPathComponent(Self.manifestFileName),
                       options: .atomic)
    }

    func loadAll() -> [StackSet] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent(Self.manifestFileName)) }
            .compactMap { try? decoder.decode(StackSet.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func frameURL(_ set: StackSet, _ frame: StackSet.Frame) -> URL {
        directory(for: set).appendingPathComponent(frame.fileName)
    }

    /// Removes the set's entire directory (frames, merged result, manifest).
    func delete(_ set: StackSet) {
        try? FileManager.default.removeItem(at: directory(for: set))
    }
}
