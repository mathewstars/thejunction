import SwiftUI

@main
struct LanviApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

/// Welcome first, then Home.
///
/// Launch arguments:
/// - `-demo`: automatic walk-through for the pitch video (welcome, Home, a
///   breathing minute finishing with the XP gain and the glow rising).
/// - `-screen <name>`: open one screen straight away. `home` is Home.
/// - `-offline`: use the offline demo data even when a server is configured.
/// - Offline demo data and screenshot moments: see `DemoBackend` and `HomeView.runDemo`.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    @State private var onHome = !ProcessInfo.processInfo.arguments.contains("-demo")
        && UserDefaults.standard.bool(forKey: "lanvi.welcomed")
    private let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    var body: some View {
        ZStack {
            switch screen {
            case "home":
                HomeView(demo: demo)
            default:
                if onHome {
                    HomeView(demo: demo)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    WelcomeView(demo: demo) { goHome() }
                        .transition(.opacity)
                }
            }
        }
        .task {
            // Pair and load while the welcome is showing.
            await store.start()
        }
        .task {
            guard demo else { return }
            try? await Task.sleep(for: .seconds(4.2))
            goHome()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.resume() } }
        }
    }

    private func goHome() {
        UserDefaults.standard.set(true, forKey: "lanvi.welcomed")
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { onHome = true }
    }
}
