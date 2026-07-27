import SwiftUI

/// Brightness and colour — a setup step, not a shooting control. In a fixed light box
/// these are dialled in once: EV biases the camera's metering, Lock then freezes it so
/// every frame in a bracket matches. ISO and shutter are chosen by the camera and
/// deliberately not surfaced; the live preview and the zebra overlay show the result.
///
/// Laid out as a numbered sequence, because the order is not arbitrary and getting it
/// wrong fails silently. Colour has to be measured off an *unclipped* backdrop — a blown
/// white reads as maximum in all three channels, so there is no colour left in it to
/// measure — and raising EV for the reel is exactly what blows the backdrop. Measure,
/// then EV, then lock. Each step reports whether it has been done, so "did I already
/// meter the white, before I raised EV and put the reel back?" is answerable by looking
/// instead of by remembering.
struct ExposurePanel: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // 1 — colour, on an empty unclipped backdrop.
            step(1, "Measure neutral", done: vm.neutralMeasured) {
                HStack(spacing: 8) {
                    Button(vm.neutralMeasured ? "Measure again" : "Measure neutral") {
                        vm.lockGrayCardWB()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(.mint)

                    if vm.neutralMeasured {
                        Text("\(Int(vm.kelvin)) K")
                            .font(.caption2).monospacedDigit().foregroundStyle(.mint)
                    }
                    Spacer()
                }
            }

            Text(vm.neutralMeasured
                 ? "Measured. Re-measure only if the lighting changes."
                 : "Empty backdrop filling the frame, zebra showing no red. A gray card works too.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            // The manual fallback, deliberately below the measurement rather than above:
            // measuring is the better path, and a slider offered first invites guessing.
            row("\(Int(vm.kelvin)) K") {
                Slider(value: $vm.kelvin, in: AppConfig.Exposure.kelvinRange, step: 50)
            }

            Divider().overlay(.white.opacity(0.2))

            // 2 — brightness for the reel, which is allowed to blow the backdrop.
            step(2, "Set EV for the reel", done: vm.evBias > 0) {
                // Disabled while locked, because the view model refuses to push a bias to
                // a locked device (doing so would switch metering back to continuous and
                // undo the lock). Left enabled, the slider moved and the label changed
                // while nothing happened — and worse, the value was not discarded: the
                // next resume or launch pushed it, so the exposure jumped later.
                row(String(format: "EV %+.1f", vm.evBias)) {
                    Slider(value: $vm.evBias,
                           in: AppConfig.Exposure.evBiasRange,
                           step: AppConfig.Exposure.evBiasStep)
                    .disabled(vm.exposureLocked)
                }
            }

            // The one out-of-order case worth catching, because it is silent: it ruins the
            // measurement rather than refusing it, and the result looks like a colour bug.
            if vm.evBias > 0 && !vm.neutralMeasured {
                Label("EV is raised, so the backdrop may be clipped. Drop it to 0, measure "
                      + "neutral, then bring it back.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            // 3 — freeze it, so every frame in the bracket matches.
            step(3, "Lock exposure", done: vm.exposureLocked) {
                Button(vm.exposureLocked ? "Unlock exposure" : "Lock exposure") {
                    vm.exposureLocked ? vm.unlockExposure() : vm.lockExposure()
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.exposureLocked ? .orange : .green)
                .frame(maxWidth: .infinity)
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    /// A numbered step with a done marker, so the panel reads as a sequence and each
    /// stage answers for itself whether it has happened.
    private func step(_ number: Int,
                      _ title: String,
                      done: Bool,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: done ? "\(number).circle.fill" : "\(number).circle")
                Text(title).font(.caption2)
                Spacer()
            }
            .foregroundStyle(done ? .green : .white.opacity(0.7))

            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(done ? "done" : "not done")")
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label).frame(width: 88, alignment: .leading).monospacedDigit()
            content()
        }
    }
}
