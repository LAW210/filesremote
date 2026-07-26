import SwiftUI

struct ViewfinderScreen: View {
    @EnvironmentObject var vm: CameraViewModel
    @State private var showExposurePanel = false
    @State private var showFocusPanel = true
    @State private var showSettings = false
    @State private var confirmLensSwitch = false

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
        // A tripod session is minutes of deliberately not touching the phone, so iOS
        // auto-lock (30 s by default) fires mid-shoot. Locking backgrounds the app, which
        // stops the session, fails the pending capture, and makes the bracket delete its
        // own directory — the whole capture, silently. Held only while this screen is up,
        // so the Library and Settings don't keep the display awake.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Switch lens?",
                            isPresented: $confirmLensSwitch,
                            titleVisibility: .visible) {
            Button("Switch and clear", role: .destructive) { vm.cycleLens() }
            Button("Keep this lens", role: .cancel) {}
        } message: {
            Text("Near and Far are positions on this lens, so switching clears them and "
                 + "unlocks exposure. You'll need to set them again.")
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
            Button(vm.currentLensName) {
                // Only asks when there is something to lose; otherwise switching is free
                // and a dialog every time would be noise.
                if vm.nearAnchor != nil || vm.farAnchor != nil || vm.exposureLocked {
                    confirmLensSwitch = true
                } else {
                    vm.cycleLens()
                }
            }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .disabled(vm.lenses.count < 2 || isBusy)

            // Status, not a control — which is exactly why it has to name what it is
            // reporting. "Locked" alone left the owner asking whether it meant focus, the
            // lens, or exposure; an earlier "AE-L 5000K" was worse, implying the Kelvin
            // value was the thing frozen. Every frame in a bracket must share one
            // exposure or the merge bands, so this is the app's most consequential state
            // and it should read unambiguously from across a light box.
            Label(vm.exposureLocked ? "Exposure locked" : "Exposure live",
                  systemImage: vm.exposureLocked ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(vm.exposureLocked ? .green : .orange)
                .accessibilityLabel(vm.exposureLocked
                                    ? "Exposure locked for the stack"
                                    : "Exposure still metering — lock it before capturing")

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
            // Buttons rather than a pinch. A two-finger gesture on a phone clamped over a
            // light box is the surest way to shift the rig, and the framing has to survive
            // until the bracket finishes — so zoom is one small tap at a time, well inside
            // the loupe's own footprint.
            HStack(spacing: 10) {
                Button { vm.stepLoupeMagnification(by: -0.5) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(vm.loupeMagnification <= AppConfig.Loupe.magnificationRange.lowerBound)
                .accessibilityLabel("Reduce loupe magnification")

                Text(String(format: "%.1f\u{00D7}", vm.loupeMagnification))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.yellow)

                Button { vm.stepLoupeMagnification(by: 0.5) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(vm.loupeMagnification >= AppConfig.Loupe.magnificationRange.upperBound)
                .accessibilityLabel("Increase loupe magnification")
            }
            .font(.footnote)
            .tint(.yellow)
        }
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
                // A bare bar on a multi-minute wait reads as a hang. The percentage is
                // what distinguishes "slow" from "stuck" while you stand over the box.
                Text("Stacking…").font(.title3)
                Text("\(Int(p * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                ProgressView(value: p)
                Text("Keep the app open — this can take a few minutes.")
                    .font(.caption2).foregroundStyle(.secondary)
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
