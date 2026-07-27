import SwiftUI

/// Manual focus slider with the 3× loupe toggle and the Near/Far anchor buttons that
/// define the bracket range (inclusive endpoints).
struct FocusPanel: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("NEAR").font(.caption2)
                Button {
                    vm.lensPosition = (vm.lensPosition - 0.005).clamped(to: 0...1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .font(.title3)
                .buttonRepeatBehavior(.enabled)

                Slider(value: $vm.lensPosition, in: 0...1)

                Button {
                    vm.lensPosition = (vm.lensPosition + 0.005).clamped(to: 0...1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .font(.title3)
                .buttonRepeatBehavior(.enabled)

                Text("FAR").font(.caption2)
            }

            HStack {
                Spacer()
                Toggle(isOn: .init(get: { vm.loupeVisible },
                                   set: { vm.setLoupe(visible: $0) })) {
                    // Not "3x loupe": magnification is adjustable from the loupe itself,
                    // so a fixed number in the label goes stale the moment it is changed.
                    Label("Loupe", systemImage: "magnifyingglass.circle")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(.yellow)

                Toggle(isOn: $vm.peakingEnabled) {
                    Label("Peaking", systemImage: "eye")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(.green)
            }

            HStack(spacing: 12) {
                anchorButton(title: "Set Near",
                             value: vm.nearAnchor,
                             action: vm.markNear)
                anchorButton(title: "Set Far",
                             value: vm.farAnchor,
                             action: vm.markFar)
            }

            if vm.nearAnchor != nil || vm.farAnchor != nil {
                plannedStepsStrip(near: vm.nearAnchor, far: vm.farAnchor)
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
    ///
    /// Renders as soon as either anchor is set, so there's feedback while placing the
    /// first one (the most delicate part of the workflow) — not just once both exist.
    /// Step dots require both endpoints (spacing is undefined with only one), so a lone
    /// anchor shows its own marker plus a hollow placeholder for the still-missing end.
    private func plannedStepsStrip(near: Float?, far: Float?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)

                if let near, let far {
                    let plan = FocusBracketController.Plan(near: near, far: far, stepCount: vm.stepCount)
                    ForEach(Array(plan.positions.enumerated()), id: \.offset) { _, pos in
                        Circle()
                            .fill(.yellow)
                            .frame(width: 8, height: 8)
                            .offset(x: CGFloat(pos) * (width - 8))
                    }
                } else if let near {
                    stripMarker(.green, x: CGFloat(near) * (width - 8))
                    pendingMarker(x: CGFloat(near) < (width - 8) / 2 ? width - 8 : 0)
                } else if let far {
                    stripMarker(.green, x: CGFloat(far) * (width - 8))
                    pendingMarker(x: CGFloat(far) < (width - 8) / 2 ? width - 8 : 0)
                }

                // Current focus position marker
                Rectangle()
                    .fill(.cyan)
                    .frame(width: 2, height: 14)
                    .offset(x: CGFloat(vm.lensPosition) * (width - 2))
            }
        }
        .frame(height: 16)
    }

    /// A placed anchor's marker on the strip.
    private func stripMarker(_ color: Color, x: CGFloat) -> some View {
        Circle().fill(color).frame(width: 8, height: 8).offset(x: x)
    }

    /// Hollow stand-in for the anchor that hasn't been set yet — no real position to
    /// show, just a cue that a second tap is still needed.
    private func pendingMarker(x: CGFloat) -> some View {
        Circle()
            .strokeBorder(.white.opacity(0.4), lineWidth: 1.5)
            .frame(width: 8, height: 8)
            .offset(x: x)
    }
}
