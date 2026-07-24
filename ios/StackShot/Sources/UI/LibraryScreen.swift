import SwiftUI

/// Saved StackSets: browse, re-open, re-stack without re-shooting.
/// Deliberately independent of CameraViewModel — it only touches the store.
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
        if let result = set.result {
            return StackStore.shared.directory(for: set).appendingPathComponent(result.mergedFileName)
        }
        return set.frames.first.map { StackStore.shared.frameURL(set, $0) }
    }
}

struct StackSetDetail: View {
    @State var set: StackSet
    @State private var merged: UIImage?
    @State private var stacking = false
    @State private var errorText: String?

    private let service = StackingService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let merged {
                    Image(uiImage: merged)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if stacking {
                    ProgressView("Stacking…")
                } else {
                    Text("Not stacked yet").foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(set.frames) { frame in
                            FrameThumbnail(url: StackStore.shared.frameURL(set, frame))
                        }
                    }
                }

                Button(stacking ? "Stacking…" : "Re-stack") {
                    restack()
                }
                .buttonStyle(.borderedProminent)
                .disabled(stacking)

                if let merged {
                    Button("Save to Photos") {
                        service.saveToPhotos(merged)
                    }
                    .buttonStyle(.bordered)
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(set.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadMerged() }
    }

    private func loadMerged() {
        merged = service.mergedImage(for: set)
    }

    /// Same persistence path as the capture flow: the re-stacked result is written
    /// to disk and recorded in the manifest, not just displayed.
    private func restack() {
        stacking = true
        errorText = nil
        Task {
            do {
                let (updated, image) = try await service.stackAndPersist(set)
                set = updated
                merged = image
            } catch {
                errorText = error.localizedDescription
            }
            stacking = false
        }
    }
}
