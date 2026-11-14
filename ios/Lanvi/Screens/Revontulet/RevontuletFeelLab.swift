import SwiftUI
import QuartzCore

/// `-revontuletFeelLab` (with `-screen revontulet`): a plain developer screen with one button
/// per haptic, so each can be felt alone on a real phone and retuned in `RevontuletTune`.
struct RevontuletFeelLab: View {
    @State private var feel = RevontuletFeel()
    @State private var pull = 0.0
    @State private var stroke = 300.0

    var body: some View {
        NavigationStack {
            List {
                Section("Choosing and tracing") {
                    row("Choose the crack") { feel.choose(hard: false) }
                    row("Choose the vein") { feel.choose(hard: true) }
                    row("Trace: twelve beads") {
                        for k in 1...12 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.11) { feel.traceStep(k) }
                        }
                    }
                    row("Charged") { feel.charged() }
                }
                Section("The sling") {
                    VStack(alignment: .leading) {
                        Text("Pull \(Int(pull * 100)) % (drag: tension, clicks, tremble)")
                        Slider(value: $pull, in: 0...1) { editing in
                            if !editing { feel.pullEnded() }
                        }
                        .onChange(of: pull) { _, v in feel.pull(v) }
                    }
                    row("Let go (short pull)") { feel.snap(0.3) }
                    row("Let go (full pull)") { feel.snap(1) }
                }
                Section("The flight and the hit") {
                    row("Easy shot and hit") { shot(kind: 0, hard: false, hits: 0) }
                    row("Hard shot, no embers") { shot(kind: 1, hard: true, hits: 0) }
                    row("Hard shot, both embers (and the ribbon)") { shot(kind: 1, hard: true, hits: 2, ribbon: true) }
                    row("Ember lit") { feel.emberHit() }
                    row("The fox's own spark") { shot(kind: 2, hard: false, hits: 0) }
                }
                Section("The burst and after") {
                    row("Breaking hit and burst") {
                        let now = CACurrentMediaTime()
                        feel.landing(at: now + 0.2, hard: true, embersHit: 2, ribbon: false, burstAt: now + 0.75)
                        feel.shardTicks(at: now + 0.75, times: [0.55, 0.72, 0.9, 1.05, 1.24, 1.4, 1.62, 1.85, 2.1])
                    }
                    row("Celebrate") { feel.celebrate() }
                    row("Coach appears") { feel.coachTick() }
                }
                Section("Warmth and sleep") {
                    VStack(alignment: .leading) {
                        Text("Stroke speed \(Int(stroke)) pt/s (slow is warmer); drag to purr")
                        Slider(value: $stroke, in: 60...900) { editing in
                            if !editing { feel.purrEnded() }
                        }
                        .onChange(of: stroke) { _, v in feel.purr(speed: v) }
                    }
                    row("Fur ticks") {
                        for k in 0..<8 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.12) { feel.furTick() }
                        }
                    }
                    row("Snow off the fur") { feel.snowOff() }
                    row("Falling asleep") { feel.sleep() }
                }
            }
            .navigationTitle("Revontulet feel lab")
        }
        .onAppear { feel.start() }
        .onDisappear { feel.stop() }
    }

    private func row(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
    }

    private func shot(kind: Int, hard: Bool, hits: Int, ribbon: Bool = false) {
        let now = CACurrentMediaTime()
        let flight = [RevontuletEngine.easyFlight, RevontuletEngine.hardFlight, RevontuletEngine.foxFlight][kind]
        if kind != 2 { feel.snap(0.8) }
        feel.flight(kind: kind, launch: now, emberShows: hard ? RevontuletEngine.emberT.map { now + $0 - RevontuletFlight.emberLead } : [])
        if hits > 0 {
            for (i, t) in RevontuletEngine.emberT.prefix(hits).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t - RevontuletFlight.emberLead + 0.35 + 0.01 * Double(i)) { feel.emberHit() }
            }
        }
        feel.landing(at: now + flight, hard: hard, embersHit: hits, ribbon: ribbon, burstAt: nil)
    }
}
