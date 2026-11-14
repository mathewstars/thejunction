import SwiftUI

/// Lanvi on the Apple Watch: one screen that records heart rate (and HRV when the watch
/// produces it) during a game on the iPhone and sends every sample over. Nothing else.
/// See `ios/WATCH.md`.
@main
struct LanviWatchApp: App {
    @State private var recorder = WorkoutRecorder()
    @State private var phone = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            WatchHome(recorder: recorder, phone: phone)
                .task {
                    phone.activate()
                    phone.onSessionEnded = { id in
                        // The game is over: stop and flush, if we were recording for it.
                        guard recorder.sessionId == id, recorder.isRecording else { return }
                        await recorder.stop()
                        phone.stopped(sessionId: id, at: Date())
                    }
                    recorder.onSamples = { samples in phone.queue(samples) }
                }
        }
    }
}
