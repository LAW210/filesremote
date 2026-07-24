import SwiftUI

/// Manual exposure: brightness (ISO + shutter) and color (Kelvin white balance + tint),
/// locked together for the whole stack.
struct ExposurePanel: View {
    @EnvironmentObject var vm: CameraViewModel

    private let shutterStops: [Double] = [4, 8, 15, 30, 60, 125, 250, 500, 1000]
    private let wbPresets: [(String, Float)] = [("Tungsten", 3200), ("LED", 5000), ("Daylight", 5600)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistogramView(bins: vm.histogram)
                .frame(height: 40)

            row("ISO \(Int(vm.iso))") {
                Slider(value: $vm.iso, in: 25...1600, step: 25)
            }

            row("1/\(Int(vm.shutterDenominator)) s") {
                Picker("Shutter", selection: $vm.shutterDenominator) {
                    ForEach(shutterStops, id: \.self) { d in
                        Text("1/\(Int(d))").tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }

            row("\(Int(vm.kelvin)) K") {
                Slider(value: $vm.kelvin, in: 2500...8000, step: 50)
            }

            HStack {
                ForEach(wbPresets, id: \.1) { preset in
                    Button("\(preset.0) \(Int(preset.1))K") { vm.kelvin = preset.1 }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }

            row(String(format: "Tint %+.0f", vm.tint)) {
                Slider(value: $vm.tint, in: -50...50, step: 1)
            }

            Button(vm.exposureLocked ? "Unlock exposure" : "Apply & lock exposure") {
                vm.exposureLocked ? vm.unlockExposure() : vm.applyAndLockExposure()
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
