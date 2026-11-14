import SwiftUI

/// `-screen revontulet` (one line in `App/LanviApp.swift`): the game straight away, through
/// the same router Home uses, then Home with the result handed over, exactly as if the game
/// had been opened from Home. Never a dead end.
struct RevontuletDirect: View {
    @Environment(AppStore.self) private var store
    @State private var playing = true

    var body: some View {
        ZStack {
            if playing {
                ActivityRouter(kind: .focus) { record in
                    print("revontulet: router onDone with \(record == nil ? "no record" : "a focus record")")
                    if let record { Task { await store.finish(record, kind: .focus) } }
                    withAnimation(LanviTiming.screen) { playing = false }
                }
                .transition(.opacity)
            } else {
                HomeView(demo: false)
                    .transition(LanviTiming.arrive)
            }
        }
    }
}
