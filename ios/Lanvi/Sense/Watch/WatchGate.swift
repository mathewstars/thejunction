import SwiftUI

/// Wraps an activity (`ActivityRouter`): opens the sensor session with one id before the
/// game, waits for the Apple Watch when there is one, runs the game, and at the end puts
/// the watch data and the game moments on the record next to the face frames.
///
/// Without a paired watch with Lanvi on it, this shows the game straight away. With one,
/// it first shows "Open Lanvi on your Apple Watch" and moves on the moment the watch says
/// it is recording; "Play without my watch" is always there.
///
/// Launch argument `-watchAsk` shows the waiting screen even without a watch (screenshots).
struct SensorSessionHost<Game: View>: View {
    var kind: ActivityKind
    /// The person closed the waiting screen: nothing was played.
    var onClose: () -> Void
    /// The game, given the session so the result can be stamped with it.
    @ViewBuilder var game: (SensorSession) -> Game

    @State private var session: SensorSession
    @State private var waiting: Bool

    init(kind: ActivityKind, onClose: @escaping () -> Void,
         @ViewBuilder game: @escaping (SensorSession) -> Game) {
        self.kind = kind
        self.onClose = onClose
        self.game = game
        _session = State(initialValue: SensorSession(kind: kind))
        let args = ProcessInfo.processInfo.arguments
        let wait = (WatchLink.shared.canTrack && !args.contains("-demo")) || args.contains("-watchAsk")
        _waiting = State(initialValue: wait)
    }

    var body: some View {
        ZStack {
            if waiting {
                WatchGateView(kind: kind, onSkip: { go() }, onClose: onClose)
                    .transition(.opacity)
            } else {
                game(session)
                    .transition(.opacity)
            }
        }
        .onAppear {
            session.begin { go() }
        }
        .onDisappear {
            // Closed through the game's own buttons: the router already ended the session.
            // Anything else (a swipe, a parent change) lands here with nothing to send.
            session.cancel()
        }
    }

    private func go() {
        guard waiting else { return }
        withAnimation(.easeInOut(duration: 0.35)) { waiting = false }
    }
}

/// "Open Lanvi on your Apple Watch to start tracking." Lanvi's scene, one line, the state
/// of the link in a small pill, and the two ways out.
struct WatchGateView: View {
    var kind: ActivityKind
    var onSkip: () -> Void
    var onClose: () -> Void

    @State private var bounce = 0
    @State private var link = WatchLink.shared

    var body: some View {
        SenseScene(pose: .curious, line: line, night: true, bounce: bounce) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    Text(status)
                        .font(Theme.rounded(15, .heavy))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(.black.opacity(0.18)))
                .animation(.easeInOut(duration: 0.3), value: status)
                SenseQuietLink(title: "Play without my watch", action: onSkip)
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(hex: 0x3A5BC7)))
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            .padding(.top, 6)
            .accessibilityLabel("Close")
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            bounce += 1
        }
    }

    private var line: String {
        "Open Lanvi on your Apple Watch and tap Start, and I'll listen to your heartbeat while we play."
    }

    private var dotColor: Color {
        if link.recordingSession != nil { return Color(hex: 0x3EE6A8) }
        return link.reachable ? Theme.aurora : .white.opacity(0.5)
    }

    private var status: String {
        switch link.status {
        case .unsupported, .noWatch: return "No Apple Watch paired"
        case .noApp: return "Lanvi is not on your watch yet"
        case .ready:
            if link.recordingSession != nil { return "Your watch is recording" }
            return link.reachable ? "Your watch is listening" : "Waiting for your watch"
        }
    }
}
