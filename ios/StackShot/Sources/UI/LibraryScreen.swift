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
                Text("\(set.frames.count) frames · ISO \(Int(set.exposure.iso)) · " +
                     "\(Int(set.whiteBalance.kelvin))K" +
                     (set.result == nil ? " · not stacked" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    @State private var errorText: String?

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

                Text(set.captureSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // File-based save/share: the exact encoded bytes, never re-compressed.
                if merged != nil, let url = service.mergedFileURL(for: set) {
                    HStack(spacing: 12) {
                        Button("Save to Photos") {
                            Task {
                                do { try await service.saveFileToPhotos(url) }
                                catch { errorText = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.bordered)

                        ShareLink(item: url)
                            .buttonStyle(.bordered)
                    }
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
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
