import SwiftUI

struct ViewfinderScreen: View {
    @EnvironmentObject var vm: CameraViewModel
    @State private var showExposurePanel = false
    @State private var showFocusPanel = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live feed with peaking baked in by FocusPeakingProcessor.
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
                }
            } else {
                ProgressView().tint(.white)
            }

            if vm.loupeVisible, let loupe = vm.loupeImage {
                LoupeView(image: loupe)
            }

            VStack {
                topBar
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
            set: { if !$0 { vm.resetForNextStack() } })) {
            ReviewSheet()
        }
    }

    /// Maps a tap on the aspect-fit viewfinder to normalized (0–1) image coordinates,
    /// accounting for letterbox bars.
    private func normalizedPoint(tap: CGPoint, in viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - fitted.width) / 2,
                             y: (viewSize.height - fitted.height) / 2)
        let x = (tap.x - origin.x) / fitted.width
        let y = (tap.y - origin.y) / fitted.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private var topBar: some View {
        HStack {
            // Lens picker chips
            ForEach(vm.lenses) { lens in
                Button(lens.name) { vm.selectLens(id: lens.id) }
                    .buttonStyle(.bordered)
                    .tint(vm.selectedLensID == lens.id ? .yellow : .white)
            }
            Spacer()
            Label(vm.exposureLocked ? "AE-L \(Int(vm.kelvin))K" : "Exposure unlocked",
                  systemImage: vm.exposureLocked ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(vm.exposureLocked ? .green : .orange)
            NavigationLink {
                LibraryScreen()
            } label: {
                Image(systemName: "photo.stack")
            }
            .tint(.white)
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
                    Image(systemName: "plusminus.circle")
                        .font(.title)
                }

                CaptureButton()

                Stepper(value: $vm.stepCount, in: 3...20) {
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

struct CaptureButton: View {
    @EnvironmentObject var vm: CameraViewModel

    var body: some View {
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
    }
}

struct LoupeView: View {
    let image: UIImage
    @EnvironmentObject var vm: CameraViewModel
    @State private var magnification: CGFloat = 3
    @State private var gestureBase: CGFloat = 3

    var body: some View {
        VStack(spacing: 4) {
            Image(uiImage: image)
                .resizable()
                .frame(width: 240, height: 240)
                .clipShape(Circle())
                .overlay(Circle().stroke(.yellow, lineWidth: 2))
            Text(String(format: "%.1f×", magnification))
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    magnification = min(max(gestureBase * value, 2), 6)
                    vm.setLoupeMagnification(magnification)
                }
                .onEnded { _ in gestureBase = magnification }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 60)
        .padding(.trailing, 12)
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
