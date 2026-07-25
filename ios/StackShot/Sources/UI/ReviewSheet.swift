import SwiftUI

/// Shows the stacked result with its capture settings, a depth-map toggle, and share.
///
/// No per-frame filmstrip and no Save-to-Photos button: source frames are deleted as
/// soon as the stack succeeds, and the finished file is auto-saved to Photos (see
/// Settings) — the share sheet covers everything else.
struct ReviewSheet: View {
    @EnvironmentObject var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDepthMap = false

    /// Dark = near, light = far. Explains what the greyscale map means and what to do
    /// about it — shared verbatim with `StackSetDetail`'s depth map.
    static let depthMapHint =
        "Dark = near frame, light = far frame. Smooth gradation means good coverage; " +
        "flat bands or patches mean adjacent steps didn't overlap — add frames or tighten Near/Far."

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

                if showDepthMap {
                    Text(Self.depthMapHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let set = vm.lastSet {
                    Text(set.captureSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Confirms the auto-save landed; the Library can re-save if it didn't.
                if vm.resultSavedToPhotos {
                    Label("Saved to Photos", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
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
            }
        }
    }
}
