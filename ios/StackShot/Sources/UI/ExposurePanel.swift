import SwiftUI

/// Brightness and colour. The camera meters continuously and the EV slider biases it;
/// ISO and shutter are shown as a readout because the camera chooses them. Locking
/// freezes both exposure and white balance so every frame in a bracket matches.
struct ExposurePanel: View {
    @EnvironmentObject var vm: CameraViewModel

    private let wbPresets = AppConfig.Exposure.whiteBalancePresets

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistogramView(bins: vm.histogram)
                .frame(height: 40)

            row(String(format: "EV %+.1f", vm.evBias)) {
                Slider(value: $vm.evBias,
                       in: AppConfig.Exposure.evBiasRange,
                       step: AppConfig.Exposure.evBiasStep)
            }

            // What the camera settled on — informational, not adjustable.
            HStack {
                Text(vm.meteringSummary ?? "metering…")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.evBias != 0 {
                    Button("Reset EV") { vm.evBias = 0 }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
            }

            row("\(Int(vm.kelvin)) K") {
                Slider(value: $vm.kelvin, in: AppConfig.Exposure.kelvinRange, step: 50)
            }

            HStack {
                ForEach(wbPresets, id: \.kelvin) { preset in
                    Button("\(preset.name) \(Int(preset.kelvin))K") { vm.kelvin = preset.kelvin }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
                Button("Gray card") { vm.lockGrayCardWB() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(.mint)
                Spacer()
            }

            Text("Gray card: fill the frame with a neutral card, then tap")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            row(String(format: "Tint %+.0f", vm.tint)) {
                Slider(value: $vm.tint, in: AppConfig.Exposure.tintRange, step: 1)
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

/// Live luminance histogram (64 bins, shadows left, highlights right).
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(bins.count, 1)
            let barWidth = geo.size.width / CGFloat(count)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(bins.indices, id: \.self) { i in
                    Rectangle()
                        .fill(.white.opacity(0.85))
                        .frame(width: barWidth,
                               height: max(1, CGFloat(bins[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}
