import CoreMotion
import SwiftUI

/// Drives device attitude updates for `LevelIndicatorView`.
///
/// For a flat-lay macro rig, the phone rests face-up over the subject, so
/// `attitude.roll` and `attitude.pitch` directly measure tilt away from
/// horizontal — no reference-frame gymnastics needed.
final class LevelMotionModel: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isAvailable: Bool = false

    private let motionManager = CMMotionManager()

    init() {
        isAvailable = motionManager.isDeviceMotionAvailable
        guard isAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.roll = motion.attitude.roll
            self.pitch = motion.attitude.pitch
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}

/// A bubble-level overlay that keeps the phone parallel to a flat-lay subject
/// so the focus plane aligns with the reel.
struct LevelIndicatorView: View {
    @StateObject private var model = LevelMotionModel()

    private let ringDiameter: CGFloat = 36
    private let dotDiameter: CGFloat = 10
    private let levelThreshold: Double = 0.026 // ~1.5 degrees, in radians
    private let fullScaleAngle: Double = 0.26 // ~15 degrees, in radians
    private let fullScaleOffset: CGFloat = 18

    var body: some View {
        if model.isAvailable {
            let isLevel = abs(model.roll) < levelThreshold && abs(model.pitch) < levelThreshold
            let color: Color = isLevel ? .green : .orange

            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: ringDiameter, height: ringDiameter)

                Path { path in
                    path.move(to: CGPoint(x: -ringDiameter / 2, y: 0))
                    path.addLine(to: CGPoint(x: ringDiameter / 2, y: 0))
                    path.move(to: CGPoint(x: 0, y: -ringDiameter / 2))
                    path.addLine(to: CGPoint(x: 0, y: ringDiameter / 2))
                }
                .stroke(color.opacity(0.6), lineWidth: 1)
                .frame(width: ringDiameter, height: ringDiameter)

                Circle()
                    .fill(color)
                    .frame(width: dotDiameter, height: dotDiameter)
                    .offset(dotOffset)
            }
            .frame(width: ringDiameter, height: ringDiameter)
        } else {
            EmptyView()
        }
    }

    private var dotOffset: CGSize {
        let radius = ringDiameter / 2
        let rawX = CGFloat(model.roll / fullScaleAngle) * fullScaleOffset
        let rawY = CGFloat(model.pitch / fullScaleAngle) * fullScaleOffset
        let magnitude = sqrt(rawX * rawX + rawY * rawY)
        guard magnitude > radius else { return CGSize(width: rawX, height: rawY) }
        let scale = radius / magnitude
        return CGSize(width: rawX * scale, height: rawY * scale)
    }
}
