import SwiftUI

@main
struct LanviApp: App {
    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.string(forKey: "screen") == "puppet" {
                LanviPuppetPreview()   // `-screen puppet`: judge the living fox
            } else {
                RootView()
            }
        }
    }
}

/// Welcome first, then Home. Launch with the argument `-demo` to play an automatic
/// walk-through (useful for recording the pitch video).
struct RootView: View {
    @State private var onHome = false
    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    var body: some View {
        ZStack {
            if onHome {
                HomeView(demo: demo)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                WelcomeView(demo: demo) { goHome() }
                    .transition(.opacity)
            }
        }
        .task {
            guard demo else { return }
            try? await Task.sleep(for: .seconds(4.2))
            goHome()
        }
    }

    private func goHome() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { onHome = true }
    }
}
