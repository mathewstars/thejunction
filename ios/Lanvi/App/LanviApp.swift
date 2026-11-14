import SwiftUI

@main
struct LanviApp: App {
    @State private var store: AppStore

    init() {
        // `-firstRun`: start as a new person (welcome, what helps, the sensor questions).
        // Used by the UI test; must run before anything reads these answers.
        if ProcessInfo.processInfo.arguments.contains("-firstRun") {
            let d = UserDefaults.standard
            for k in d.dictionaryRepresentation().keys where k.hasPrefix("lanvi.") { d.removeObject(forKey: k) }
        }
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .lanviSense(store)
        }
    }
}

/// First run: Welcome, then "What usually helps you?", then Home. Later opens go
/// straight to Home.
///
/// Launch arguments:
/// - `-demo`: the whole story by itself for the pitch video (under a minute):
///   Welcome, Home with today's one thing, Breathe with Lanvi, the XP and glow
///   moment, growing up, done for today, a wandering and its story, a word with
///   Lanvi. Always uses the offline demo data.
/// - `-screen <name>`: open one screen straight away: `home`, `whathelps`,
///   `focus`, `breathe`, `checkin`, `checkin-plan`, `puppet`.
/// - `-offline`: use the offline demo data even when a server is configured.
/// - Screenshot moments on Home: see `DemoBackend` and `HomeView.runDemo`.
struct RootView: View {
    private enum Step { case welcome, helps, home }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    @State private var step: Step = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") { return .welcome }
        return UserDefaults.standard.bool(forKey: "lanvi.welcomed") ? .home : .welcome
    }()
    /// `-screen <name>` (UserDefaults reads launch arguments of this form).
    private let screen = UserDefaults.standard.string(forKey: "screen")

    var body: some View {
        ZStack {
            switch screen {
            case "home":
                HomeView(demo: demo)
            case "whathelps":
                WhatHelpsView(demo: demo) {}
            case "focus":
                FocusGameView { print("focus: done \(String(describing: $0))") }
            case "breathe":
                BreatheView { _ in }
            case "puppet":
                LanviPuppetPreview()   // judge the living fox on its own
            case let s? where s.hasPrefix("checkin"):
                CheckinView.preview(s)
            default:
                switch step {
                // Every first-run step arrives the same calm way: it rises a little and fades in.
                case .welcome:
                    WelcomeView(demo: demo) { go(demo ? .home : .helps) }
                        .transition(LanviTiming.arrive)
                case .helps:
                    WhatHelpsView(demo: demo) { go(.home) }
                        .transition(LanviTiming.arrive)
                case .home:
                    HomeView(demo: demo)
                        .transition(LanviTiming.arrive)
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
            go(.home)
        }
        .onChange(of: scenePhase) { old, phase in
            if phase == .active, old == .background { Task { await store.resume() } }
        }
    }

    private func go(_ next: Step) {
        if next == .home { UserDefaults.standard.set(true, forKey: "lanvi.welcomed") }
        withAnimation(LanviTiming.screen) { step = next }
    }
}
