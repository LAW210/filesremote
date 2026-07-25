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
                    Toggle("Keep RAW frames after stacking", isOn: $vm.keepFrames)
                } footer: {
                    Text(vm.keepFrames
                         ? "The source RAW (DNG) frames stay in the library so you can " +
                           "re-stack later with different settings."
                         : "The source frames are deleted once the stacked image is " +
                           "safely saved — only the final image remains, and that " +
                           "stack can no longer be re-processed.")
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
