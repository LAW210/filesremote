import SwiftUI

/// Shows the stacked result with a per-frame filmstrip, save/share, and re-stack.
struct ReviewSheet: View {
    @EnvironmentObject var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = vm.resultImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView("Stacking…")
                }

                if let set = vm.lastSet {
                    filmstrip(set: set)
                    Text("\(set.frames.count) frames · ISO \(Int(set.exposure.iso)) · " +
                         "1/\(Int(1 / set.exposure.shutterSeconds)) s · \(Int(set.whiteBalance.kelvin))K")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Stacked result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saved ? "Saved ✓" : "Save to Photos") {
                        vm.saveResultToPhotos()
                        saved = true
                    }
                    .disabled(vm.resultImage == nil || saved)
                }
            }
        }
    }

    private func filmstrip(set: StackSet) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(set.frames) { frame in
                    VStack(spacing: 2) {
                        FrameThumbnail(url: StackStore.shared.frameURL(set, frame))
                        Text(String(format: "%.2f", frame.lensPosition))
                            .font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 76)
    }
}

struct FrameThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            image = await Self.thumbnail(for: url)
        }
    }

    static func thumbnail(for url: URL, side: CGFloat = 120) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
