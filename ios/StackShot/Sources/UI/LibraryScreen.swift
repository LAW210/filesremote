import SwiftUI

/// Saved StackSets: browse stacked results, export them, delete them.
/// Deliberately independent of CameraViewModel — it only touches the store.
///
/// There is no re-stack here: source frames are deleted once a stack succeeds,
/// so a saved set is its final image plus its capture metadata.
struct LibraryScreen: View {
    @State private var sets: [StackSet] = []

    var body: some View {
        List {
            if sets.isEmpty {
                ContentUnavailableView("No stacks yet",
                                       systemImage: "photo.stack",
                                       description: Text("Captured focus stacks appear here."))
            }
            ForEach(sets) { set in
                NavigationLink {
                    StackSetDetail(set: set)
                } label: {
                    row(for: set)
                }
            }
            .onDelete { offsets in
                for index in offsets { StackStore.shared.delete(sets[index]) }
                sets.remove(atOffsets: offsets)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            NavigationLink("Licenses") { AcknowledgementsScreen() }
        }
        .onAppear { sets = StackStore.shared.loadAll() }
    }

    private func row(for set: StackSet) -> some View {
        HStack(spacing: 12) {
            thumbnailURL(for: set).map { url in
                FrameThumbnail(url: url)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(set.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Text(librarySummary(for: set))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `StackSet.captureSummary` plus the library-specific "not stacked" suffix. It
    /// delegates rather than re-deriving the line: a second copy of the format drifts
    /// the moment the shared one changes, and nothing would flag it.
    private func librarySummary(for set: StackSet) -> String {
        set.captureSummary + (set.result == nil ? " · not stacked" : "")
    }

    private func thumbnailURL(for set: StackSet) -> URL? {
        StackingService.shared.mergedFileURL(for: set)
            ?? set.frames.first.map { StackStore.shared.frameURL(set, $0) }
    }
}

struct StackSetDetail: View {
    let set: StackSet

    @State private var merged: UIImage?
    @State private var depthMap: UIImage?
    @State private var showDepthMap = false

    private let service = StackingService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image = (showDepthMap ? depthMap : nil) ?? merged {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Not stacked yet").foregroundStyle(.secondary)
                }

                if depthMap != nil {
                    Toggle("Depth", isOn: $showDepthMap)
                        .toggleStyle(.button)
                }

                if showDepthMap {
                    Text(ReviewSheet.depthMapHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(set.captureSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Share only. A "Save to Photos" button used to sit beside this, but
                // auto-save already puts every finished stack in the library the moment it
                // completes, and the share sheet can save too — it was a third route to
                // the same file, on a screen you only visit to look back at a result.
                // Shares the file itself, so the exact encoded bytes go out uncompressed
                // a second time.
                if merged != nil, let url = service.mergedFileURL(for: set) {
                    ShareLink(item: url)
                        .buttonStyle(.bordered)
                }

                // Diagnostic, not a primary action: kept visually secondary to the
                // share button above, and only offered when a log actually exists.
                if let logURL = service.captureLogURL(for: set) {
                    ShareLink(item: logURL) {
                        Label("Capture log", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()
        }
        .navigationTitle(set.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            merged = service.mergedImage(for: set)
            depthMap = service.depthMapImage(for: set)
        }
    }
}
