import SwiftUI

/// Manual focus slider with the 3× loupe toggle and the Near/Far anchor buttons that
/// define the bracket range (inclusive endpoints).
struct FocusPanel: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("NEAR").font(.caption2)
                Slider(value: $vm.lensPosition, in: 0...1)
                Text("FAR").font(.caption2)
            }

            HStack {
                Text(String(format: "lens %.3f", vm.lensPosition))
                    .font(.caption).monospacedDigit()
                Spacer()
                Toggle(isOn: .init(get: { vm.loupeVisible },
                                   set: { vm.setLoupe(visible: $0) })) {
                    Label("3× loupe", systemImage: "magnifyingglass.circle")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(.yellow)
            }

            HStack(spacing: 12) {
                anchorButton(title: "Set Near",
                             value: vm.nearAnchor,
                             action: vm.markNear)
                anchorButton(title: "Set Far",
                             value: vm.farAnchor,
                             action: vm.markFar)
            }

            if let near = vm.nearAnchor, let far = vm.farAnchor {
                plannedStepsStrip(near: near, far: far)
            }
        }
        .foregroundStyle(.white)
    }

    private func anchorButton(title: String, value: Float?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.caption)
                Text(value.map { String(format: "%.3f", $0) } ?? "—")
                    .font(.caption2).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(value == nil ? .white : .green)
    }

    /// Visualizes the planned focus planes: frame 1 = near anchor, frame N = far anchor.
    private func plannedStepsStrip(near: Float, far: Float) -> some View {
        let plan = FocusBracketController.Plan(near: near, far: far, stepCount: vm.stepCount)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                ForEach(Array(plan.positions.enumerated()), id: \.offset) { _, pos in
                    Circle()
                        .fill(.yellow)
                        .frame(width: 8, height: 8)
                        .offset(x: CGFloat(pos) * (geo.size.width - 8))
                }
                // Current focus position marker
                Rectangle()
                    .fill(.cyan)
                    .frame(width: 2, height: 14)
                    .offset(x: CGFloat(vm.lensPosition) * (geo.size.width - 2))
            }
        }
        .frame(height: 16)
    }
}
