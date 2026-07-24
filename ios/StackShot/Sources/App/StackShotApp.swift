import SwiftUI

@main
struct StackShotApp: App {
    @StateObject private var camera = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var camera: CameraViewModel

    var body: some View {
        NavigationStack {
            ViewfinderScreen()
        }
        .task { await camera.start() }
    }
}
