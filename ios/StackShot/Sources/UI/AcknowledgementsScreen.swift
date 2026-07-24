import SwiftUI

/// Third-party license credits, required for shipping the embedded engine.
struct AcknowledgementsScreen: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let license: String
        let url: String
        let note: String
    }

    private let entries = [
        Entry(name: "focus-stack (Petteri Aimonen)",
              license: "MIT License",
              url: "https://github.com/PetteriAimonen/focus-stack",
              note: "Focus-stacking core: wavelet extended-depth-of-field merge, ECC alignment, depth map."),
        Entry(name: "OpenCV",
              license: "Apache License 2.0",
              url: "https://opencv.org",
              note: "Image processing library used by the stacking core."),
    ]

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.headline)
                Text(entry.license).font(.subheadline).foregroundStyle(.secondary)
                Text(entry.note).font(.caption)
                if let url = URL(string: entry.url) {
                    Link(entry.url, destination: url).font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Acknowledgements")
    }
}
