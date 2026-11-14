import SwiftUI

/// The first-run Apple Health screen, in Lanvi's voice: what is read and what is not,
/// then the system sheet. "Not now" is always there; the app works without it.
struct HealthAskView: View {
    var onAllow: () async -> Int?
    var onSkip: () -> Void
    var onFinished: () -> Void

    @State private var pose: LanviPose = .curious
    @State private var line = "I only look at how much you move and sleep. Never your messages, photos or location."
    @State private var bounce = 0
    @State private var busy = false
    @State private var thanked = false

    var body: some View {
        SenseScene(pose: pose, line: line, bounce: bounce) {
            if !thanked {
                Button(busy ? "One moment" : "Show Lanvi my steps") { allow() }
                    .buttonStyle(ChunkyButtonStyle())
                    .disabled(busy)
                SenseQuietLink(title: "Not now") {
                    onSkip()
                    onFinished()
                }
                .disabled(busy)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            bounce += 1
        }
    }

    private func allow() {
        busy = true
        Task {
            let days = await onAllow()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                thanked = true
                pose = .love
                line = (days ?? 0) > 0
                    ? "Thank you. Now I know how you usually move."
                    : "Thank you. I'll look again when there is something new."
            }
            bounce += 1
            try? await Task.sleep(for: .seconds(2.2))
            onFinished()
        }
    }
}

/// Hooks the two sensors into the app with one line in `LanviApp`:
/// the first-run Health screen over Home, and the daily upload on every open.
struct LanviSense: ViewModifier {
    var store: AppStore

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lanvi.welcomed") private var welcomed = false
    @State private var asking = false
    /// `-senseScreen face | help`: show one sense screen straight away (screenshots).
    private let preview = UserDefaults.standard.string(forKey: "senseScreen")

    func body(content: Content) -> some View {
        content
            .overlay {
                switch preview {
                case "face": FaceAskView { _ in }
                case "help": HomeHelpScreen(crisis: DemoBackend.crisis) {}
                default: EmptyView()
                }
            }
            .overlay {
                if asking {
                    HealthAskView(onAllow: { await HealthSync.shared.allow(store) },
                                  onSkip: { HealthSync.shared.skip() },
                                  onFinished: {
                                      withAnimation(.easeInOut(duration: 0.4)) { asking = false }
                                  })
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .task {
                await store.start()
                await HealthSync.shared.sync(store)
            }
            .task(id: welcomed) {
                guard welcomed || ProcessInfo.processInfo.arguments.contains("-healthAsk") else { return }
                guard preview == nil, HealthSync.shared.shouldAsk else { return }
                // Let Home arrive first, then ask.
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeInOut(duration: 0.4)) { asking = true }
            }
            .onChange(of: scenePhase) { old, phase in
                guard phase == .active, old == .background else { return }
                Task { await HealthSync.shared.sync(store) }
            }
    }
}

extension View {
    /// Apple Health and the face summary: see `ios/Lanvi/Sense/`.
    func lanviSense(_ store: AppStore) -> some View { modifier(LanviSense(store: store)) }
}
