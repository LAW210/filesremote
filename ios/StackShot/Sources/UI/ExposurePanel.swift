import SwiftUI

/// Brightness and colour — a setup step, not a shooting control. In a fixed light box
/// these are dialled in once: EV biases the camera's metering, Lock then freezes it so
/// every frame in a bracket matches. ISO and shutter are chosen by the camera and
/// deliberately not surfaced; the live preview and the zebra overlay show the result.
struct ExposurePanel: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Disabled while locked, because the view model refuses to push a bias to a
            // locked device (doing so would switch metering back to continuous and undo
            // the lock). Left enabled, the slider moved and the label changed while
            // nothing happened — and worse, the value was not discarded: the next resume
            // or launch pushed it, so the exposure jumped later, long after the drag.
            row(String(format: "EV %+.1f", vm.evBias)) {
                Slider(value: $vm.evBias,
                       in: AppConfig.Exposure.evBiasRange,
                       step: AppConfig.Exposure.evBiasStep)
                .disabled(vm.exposureLocked)
            }

            row("\(Int(vm.kelvin)) K") {
                Slider(value: $vm.kelvin, in: AppConfig.Exposure.kelvinRange, step: 50)
            }

            // One way to set colour, not three. The preset buttons duplicated what the
            // Kelvin slider already does, for a light box whose source never changes —
            // and the gray card measures the real thing instead of guessing at a label.
            HStack {
                Button("Measure off gray card") { vm.lockGrayCardWB() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(.mint)
                Spacer()
            }

            Button(vm.exposureLocked ? "Unlock exposure" : "Lock exposure") {
                vm.exposureLocked ? vm.unlockExposure() : vm.lockExposure()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.exposureLocked ? .orange : .green)
            .frame(maxWidth: .infinity)
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label).frame(width: 88, alignment: .leading).monospacedDigit()
            content()
        }
    }
}
