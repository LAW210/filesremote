import SwiftUI

/// Shows the stacked result with a per-frame filmstrip, save/share, and re-stack.
struct ReviewSheet: View {
    @EnvironmentObject var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var showDepthMap = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = showDepthMap ? vm.depthMapImage : vm.resultImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView("Stacking…")
                }

                if vm.depthMapImage != nil {
                    Toggle("Depth", isOn: $showDepthMap)
                        .toggleStyle(.button)
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
                ToolbarItem(placement: .primaryAction) {
                    // Shares the exact JPEG file on disk — same bytes eBay receives.
                    if let url = vm.mergedFileURL {
                        ShareLink(item: url)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saved ? "Saved ✓" : "Save to Photos") {
                        vm.saveResultToPhotos()
                        saved = true
                    }
                    .disabled(vm.mergedFileURL == nil || saved)
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

