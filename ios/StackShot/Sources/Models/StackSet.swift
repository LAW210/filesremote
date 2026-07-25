import Foundation

/// One captured focus-bracket session: N frames plus (optionally) a stacked result.
struct StackSet: Codable, Identifiable {
    struct Exposure: Codable {
        var iso: Float
        var shutterSeconds: Double
    }

    struct WhiteBalance: Codable {
        var kelvin: Float
        var tint: Float
    }

    struct Range: Codable {
        var lensPositionNear: Float
        var lensPositionFar: Float
        var stepCount: Int
        /// "linearLensPosition" for v1; "diopter" reserved for later.
        var spacingMode: String
    }

    struct Frame: Codable, Identifiable {
        var id: Int { index }
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
    var result: Result?
    /// True when the source frames were deleted after a successful stack (user setting).
    /// Optional so manifests written before this field still decode.
    var framesPurged: Bool?
}

/// Persists StackSets as folders of frames + manifest.json in the app sandbox.
final class StackStore {
    static let shared = StackStore()

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
        try data.write(to: directory(for: set).appendingPathComponent("manifest.json"), options: .atomic)
    }

    func loadAll() -> (sets: [StackSet], corruptCount: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var sets: [StackSet] = []
        var corruptCount = 0
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { continue }
            if let set = try? decoder.decode(StackSet.self, from: data) {
                sets.append(set)
            } else {
                corruptCount += 1
            }
        }
        sets.sort { $0.createdAt > $1.createdAt }
        return (sets, corruptCount)
    }

    func frameURL(_ set: StackSet, _ frame: StackSet.Frame) -> URL {
        directory(for: set).appendingPathComponent(frame.fileName)
    }
}
