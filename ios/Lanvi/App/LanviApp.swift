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
        // `-demoLevelUp`: the demo starts 5 XP short of level 7 (unless -demoXP says
        // otherwise) and Home sends one activity, so a level up shows on demand.
        var args = ProcessInfo.processInfo.arguments
        if args.contains("-demoLevelUp"), !args.contains("-demoXP") {
            args += ["-demoXP", String(LanviLevel.start(of: 7) - 5)]
        }
        let store = AppStore(arguments: args)
        _store = State(initialValue: store)
        // Decode today's painted world (and the night of the first run) off the main
        // thread now, so no screen decodes it while it opens.
        var worlds = [store.worldScene]
        if !UserDefaults.standard.bool(forKey: "lanvi.welcomed") { worlds.append(.night) }
        WorldPictures.shared.preload(worlds)
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
///   moment, growing up, done for today, a word with Lanvi. Always uses the offline demo data.
/// - `-screen <name>`: open one screen straight away: `home`, `whathelps`,
///   `focus`, `breathe`, `checkin`, `checkin-plan`, `puppet`.
/// - `-flow`: the first run and a short tour of Home (chat, more, growth, Help) play
///   by themselves, at a person's pace, with nothing attached: for smooth recordings.
///   Use it with `-offline`.
/// - `-offline`: use the offline demo data even when a server is configured.
/// - Screenshot moments on Home: see `DemoBackend` and `HomeView.runDemo`.
struct RootView: View {
    private enum Step { case welcome, helps, home }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    /// `-flow`: the first run and a short tour of Home play by themselves (for recordings).
    private let flow = ProcessInfo.processInfo.arguments.contains("-flow")
    @State private var step: Step = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") || args.contains("-flow") { return .welcome }
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
            case "revontulet": RevontuletDirect()
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
                    // The opening is the rescue: a kit alone in the snow, warmed by holding him.
                    RescueView(auto: demo || flow) { go(demo ? .home : .helps) }
                        .transition(LanviTiming.arrive)
                case .helps:
                    WhatHelpsView(demo: demo || flow) { go(.home) }
                        .transition(LanviTiming.arrive)
                case .home:
                    HomeView(demo: demo)
                        .transition(LanviTiming.arrive)
                }
            }
        }
        #if DEBUG
        .onAppear {
            PerfProbe.shared.rootShown(screen.map { "screen \($0)" } ?? "step \(step)")
            FrameMeter.shared.start()
        }
        .onChange(of: step) { _, s in FrameMeter.mark("step \(s)") }
        #endif
        .task {
            // Pair and load while the welcome is showing.
            await store.start()
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
