import SwiftUI

struct ViewfinderScreen: View {
    @EnvironmentObject var vm: CameraViewModel
    @State private var showExposurePanel = false
    @State private var showFocusPanel = true
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live feed with peaking baked in by PreviewFrameProcessor.
            if let image = vm.viewfinderImage {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            guard vm.loupeVisible else { return }
                            vm.moveLoupe(to: normalizedPoint(tap: location,
                                                             in: geo.size,
                                                             imageSize: image.size))
                        }
                    if vm.squareGuideEnabled {
                        SquareCropGuide(viewSize: geo.size, imageSize: image.size)
                            .allowsHitTesting(false)
                    }
                    if vm.loupeVisible {
                        LoupeReticle(normalizedPoint: vm.loupeCenter,
                                    viewSize: geo.size, imageSize: image.size)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ProgressView().tint(.white)
            }

            if vm.loupeVisible, let loupe = vm.loupeImage {
                LoupeView(image: loupe)
            }

            VStack {
                topBar
                if vm.isPreviewMode {
                    PreviewModeBadge()
                }
                Spacer()
                if case .idle = vm.phase {
                    controls
                } else {
                    CaptureProgressView()
                }
            }
            .padding()
        }
        .alert("Error", isPresented: .init(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: .init(
            get: { vm.phase == .done },
            set: { if !$0 { vm.dismissReview() } })) {
            ReviewSheet()
        }
    }

    /// Maps a tap on the aspect-fit viewfinder to normalized (0–1) image coordinates,
    /// accounting for letterbox bars.
    private func normalizedPoint(tap: CGPoint, in viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        let fitted = CGRect.aspectFit(imageSize, in: viewSize)
        return CGPoint(x: ((tap.x - fitted.minX) / fitted.width).clamped(to: 0...1),
                       y: ((tap.y - fitted.minY) / fitted.height).clamped(to: 0...1))
    }

    /// Only the bottom panel used to be gated on `.idle`, which left this whole row live
    /// during a bracket. Switching lenses mid-sweep tears down the input the in-flight
    /// capture depends on, and toggling the torch changes the illumination between frames
    /// of a bracket whose entire premise is that every frame shares one exposure.
    private var isBusy: Bool {
        if case .idle = vm.phase { return false }
        return true
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // One button cycling the available back cameras, rather than a chip each.
            Button(vm.currentLensName) { vm.cycleLens() }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .disabled(vm.lenses.count < 2 || isBusy)

            Label(vm.exposureLocked ? "Locked" : "Live",
                  systemImage: vm.exposureLocked ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(vm.exposureLocked ? .green : .orange)

            Spacer()

            // Occasional tools live here as icons: checked when the lighting or the
            // reel's finish changes, ignored the rest of the time.
            Button {
                vm.zebraEnabled.toggle()
            } label: {
                Image(systemName: "exclamationmark.triangle")
            }
            .tint(vm.zebraEnabled ? .red : .white)
            .accessibilityLabel("Highlight clipping warning")

            Button {
                vm.setTorch(!vm.torchEnabled)
            } label: {
                Image(systemName: vm.torchEnabled ? "bolt.fill" : "bolt.slash")
            }
            .tint(vm.torchEnabled ? .orange : .white)
            .disabled(isBusy)
            .accessibilityLabel("Torch")

            // Navigating away mid-bracket would hide the progress view and the Cancel
            // button while the capture kept running.
            NavigationLink {
                LibraryScreen()
            } label: {
                Image(systemName: "photo.stack")
            }
            .tint(.white)
            .disabled(isBusy)

            // A Settings sheet still open when stacking finishes would swallow the
            // review sheet: two presentations from one hosting controller, one wins.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .tint(.white)
            .disabled(isBusy)
            .sheet(isPresented: $showSettings) { SettingsSheet() }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if showExposurePanel { ExposurePanel() }
            if showFocusPanel { FocusPanel() }

            HStack(spacing: 24) {
                Button {
                    showExposurePanel.toggle()
                    showFocusPanel = !showExposurePanel
                } label: {
                    // Names the panel a tap would switch TO, not the one showing now.
                    VStack(spacing: 2) {
                        // Icon must point at the same panel as the label beneath it:
                        // a viewfinder for Focus, plus/minus for EV compensation.
                        Image(systemName: showExposurePanel ? "viewfinder" : "plusminus.circle")
                            .font(.title3)
                        Text(showExposurePanel ? "Focus" : "Exposure")
                            .font(.caption2)
                    }
                    .frame(width: 56)
                }
                .accessibilityLabel(showExposurePanel ? "Switch to focus panel" : "Switch to exposure panel")

                CaptureButton()

                Stepper(value: $vm.stepCount, in: AppConfig.Bracket.stepRange) {
                    Text("\(vm.stepCount) frames")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()
            }
            .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 1:1 crop guide: dims the parts of the (aspect-fit) camera image that a square
/// crop would discard — eBay renders square listing thumbnails, so framing inside
/// the bright square avoids discovering a bad crop after a multi-minute stack.
struct SquareCropGuide: View {
    let viewSize: CGSize
    let imageSize: CGSize

    var body: some View {
        let fitted = CGRect.aspectFit(imageSize, in: viewSize)
        let side = min(fitted.width, fitted.height)
        let square = CGRect(x: fitted.minX + (fitted.width - side) / 2,
                            y: fitted.minY + (fitted.height - side) / 2,
                            width: side, height: side)

        ZStack {
            // Dim everything the square crop would discard.
            Path { path in
                path.addRect(fitted)
                path.addRect(square)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(.white.opacity(0.8), lineWidth: 1)
                .frame(width: square.width, height: square.height)
                .position(x: square.midX, y: square.midY)
        }
    }
}

/// Marks the point the loupe is currently magnifying, so there's some indication on
/// the preview itself of what region is being shown after a tap moves the sample point.
struct LoupeReticle: View {
    let normalizedPoint: CGPoint
    let viewSize: CGSize
    let imageSize: CGSize

    private let size: CGFloat = 28

    var body: some View {
        let fitted = CGRect.aspectFit(imageSize, in: viewSize)
        let center = CGPoint(x: fitted.minX + normalizedPoint.x * fitted.width,
                             y: fitted.minY + normalizedPoint.y * fitted.height)

        ZStack {
            Circle()
                .stroke(.yellow, lineWidth: 1.5)
                .frame(width: size, height: size)
            Path { path in
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
            }
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: size, height: size)
        }
        .position(center)
    }
}

struct CaptureButton: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 4) {
            Button(action: vm.captureStack) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    Circle()
                        .fill(vm.canCapture ? .white : .gray)
                        .frame(width: 60, height: 60)
                }
            }
            .disabled(!vm.canCapture)
            .accessibilityLabel("Capture focus stack")

            if let hint = vm.captureBlockedReason {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 150)
            }
        }
    }

}

/// Unmissable flag that the viewfinder is showing synthetic frames rather than a real
/// camera feed — only true on Simulator, where a good-looking frame could otherwise be
/// mistaken for real capture output.
struct PreviewModeBadge: View {
    var body: some View {
        Text("PREVIEW · no camera")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.red, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct LoupeView: View {
    let image: UIImage
    @EnvironmentObject var vm: CameraViewModel

    /// Sits on the side opposite the sample point, so it never covers the region it's
    /// magnifying. The dodge is horizontal only: the bottom of the screen belongs to
    /// the control panel, so dodging downward would trade one occlusion for a worse one.
    private var dodgeAlignment: Alignment {
        vm.loupeCenter.x >= 0.5 ? .topLeading : .topTrailing
    }

    var body: some View {
        let side = AppConfig.Loupe.diameter
        let alignment = dodgeAlignment
        VStack(spacing: 4) {
            Image(uiImage: image)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(Circle())
                .overlay(Circle().stroke(.yellow, lineWidth: 2))
            Text(String(format: "%.1f×", vm.loupeMagnification))
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { vm.scaleLoupe(by: $0) }
                .onEnded { _ in vm.commitLoupeScale() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.top, 60)
        .padding(.leading, alignment == .topLeading ? 12 : 0)
        .padding(.trailing, alignment == .topTrailing ? 12 : 0)
    }
}

struct CaptureProgressView: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 10) {
            switch vm.phase {
            case .countdown(let s):
                Text("Starting in \(s)s…").font(.title3)
            case .capturing(let f, let n):
                Text("Frame \(f) / \(n)").font(.title3).monospacedDigit()
                ProgressView(value: Double(f), total: Double(n))
            case .stacking(let p):
                Text("Stacking…").font(.title3)
                ProgressView(value: p)
            default:
                EmptyView()
            }
            if case .capturing = vm.phase {
                Button("Cancel", role: .destructive) { vm.cancelCapture() }
            }
        }
        .padding()
        .foregroundStyle(.white)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }
}
