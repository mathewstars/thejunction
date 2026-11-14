import SwiftUI

/// The one screen: what is being recorded, the heart right now, the latest HRV with its
/// time, whether the iPhone is there, how long, and Start or Stop. Plain, readable on a
/// small wrist. Nothing here guesses a value: an empty reading shows as a dash.
struct WatchHome: View {
    var recorder: WorkoutRecorder
    var phone: PhoneLink

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    heart
                    hrv
                    footer(now: timeline.date)
                    button
                        .padding(.top, 4)
                }
                .padding(.horizontal, 4)
            }
        }
        .navigationTitle("Lanvi")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(recorder.isRecording ? .green : .gray)
                .frame(width: 8, height: 8)
            Text(statusLine)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
        }
    }

    private var heart: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.red)
                .font(.title3)
            Text(recorder.heartRate.map { String(Int($0.rounded())) } ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text("bpm")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var hrv: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("HRV")
                    .font(.footnote.weight(.semibold))
                Text(recorder.hrv.map { String(format: "%.0f ms", $0) } ?? "none yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let at = recorder.hrvAt {
                Text("at \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("The watch writes HRV now and then, not every game.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func footer(now: Date) -> some View {
        HStack {
            Label(phone.reachable ? "iPhone connected" : "iPhone away",
                  systemImage: phone.reachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.caption2)
                .foregroundStyle(phone.reachable ? .primary : .secondary)
            Spacer()
            if recorder.isRecording, let start = recorder.startedAt {
                Text(Self.clock(now.timeIntervalSince(start)))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    @ViewBuilder private var button: some View {
        switch recorder.state {
        case .recording:
            Button("Stop") { Task { await stop() } }
                .tint(.red)
        case .starting, .stopping:
            Button("One moment") {}
                .disabled(true)
        case .idle, .failed:
            Button("Start recording") { Task { await start() } }
                .tint(.green)
                .disabled(phone.context == nil || phone.context?.state == .ended)
        }
    }

    // MARK: Words

    private var statusLine: String {
        if case .failed(let why) = recorder.state { return why }
        if recorder.isRecording { return "Recording for \(gameName)" }
        guard let c = phone.context else { return "Start a game on your iPhone first." }
        switch c.state {
        case .waiting: return "\(gameName) is waiting on your iPhone."
        case .playing: return "\(gameName) is playing."
        case .ended: return "The game is over."
        }
    }

    private var gameName: String {
        switch phone.context?.activity {
        case "focus": "Sparks and snow"
        case "breathing": "Breathe with Lanvi"
        case "checkin": "the evening check-in"
        default: "the game"
        }
    }

    private static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Actions

    private func start() async {
        guard let c = phone.context else { return }
        await recorder.start(sessionId: c.sessionId)
        if recorder.state == .recording, let at = recorder.startedAt {
            phone.started(sessionId: c.sessionId, at: at)
        }
    }

    private func stop() async {
        let id = recorder.sessionId
        await recorder.stop()
        if let id { phone.stopped(sessionId: id, at: Date()) }
    }
}
