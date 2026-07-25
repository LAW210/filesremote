import SwiftUI

/// Output settings: stacked-image format and whether RAW source frames are kept.
struct SettingsSheet: View {
    @EnvironmentObject var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Stacked image format", selection: $vm.outputFormat) {
                        ForEach(AppConfig.Stacking.OutputFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Stacked image format")
                } footer: {
                    Text("JPEG (quality 95) uploads directly to listing sites — eBay " +
                         "accepts JPEG but not HEIC. HEIC halves the file size for " +
                         "personal archiving.")
                }

                Section {
                    Toggle("Auto-save stacked image to Photos", isOn: $vm.autoSaveToPhotos)
                    Toggle("Show 1:1 crop guide", isOn: $vm.squareGuideEnabled)
                } footer: {
                    Text("Auto-save adds the finished JPEG to your photo library the " +
                         "moment stacking completes. The crop guide dims what a square " +
                         "(eBay-thumbnail) crop would discard so you can frame for it.")
                }

                Section {
                    Label("Source RAW frames are deleted automatically once the stacked " +
                          "image is safely saved — only the final image is kept.",
                          systemImage: "trash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
