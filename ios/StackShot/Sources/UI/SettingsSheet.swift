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
                    Text("JPEG (quality 90) uploads directly to listing sites — eBay " +
                         "accepts JPEG but not HEIC. HEIC halves the file size for " +
                         "personal archiving.")
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
