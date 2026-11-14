import SwiftUI

// MARK: - The reward's beat

/// When everything in the reward happens, counted from the moment it starts.
/// A handful of sparks bursts out of "+10 XP", hangs for a breath, then each one
/// flies in an arc into Lanvi; the bar fills one tick as every second spark lands.
/// On a level up the sparks still in the air wait while the bar fills, flashes
/// and starts the new level.
struct RewardPlan {
    static let sparks = 10
    static let burstAt = 0.45      // the "+10 XP" has popped
    static let burstOut = 0.28
    static let flight = 0.5
    static let stagger = 0.05
    /// The extra wait for the level up (bar full, flash, reset).
    static let levelPause = 0.45

    /// The XP shown after each tick (at most five ticks).
    let values: [Int]
    /// The tick (1-based) on which a new level begins, if one does.
    let levelStep: Int?

    init(from: Int, gained: Int) {
        let steps = max(0, min(5, gained))
        values = steps == 0 ? [] : (1...steps).map { k in
            from + Int((Double(gained) * Double(k) / Double(steps)).rounded())
        }
        var crossed: Int?
        var before = LanviLevel(xp: from).level
        for (i, v) in values.enumerated() {
            let now = LanviLevel(xp: v).level
            if now > before, crossed == nil { crossed = i + 1 }
            before = now
        }
        levelStep = crossed
    }

    /// The spark that lands on tick `k`.
    func sparkIndex(_ k: Int) -> Int { max(0, k * Self.sparks / max(values.count, 1) - 1) }

    /// From this spark on, the sparks wait for the level up.
    var pauseFrom: Int? { levelStep.map { sparkIndex($0) + 1 } }
    var pause: Double { levelStep == nil ? 0 : Self.levelPause }

    /// When spark `i` lands in Lanvi.
    func land(_ i: Int) -> Double { RewardPlanTimes(self).land(i) }

    /// When tick `k` happens.
    func stepTime(_ k: Int) -> Double { land(sparkIndex(k)) }
}

// MARK: - Sparks

/// One reward's sparks: where they burst from and where they land.
struct SparkFlight: Equatable {
    var start: Date
    var origin: CGPoint
    var target: CGPoint
    var spread: CGFloat
    var plan: RewardPlanTimes
}

/// The landing times of a plan, kept as plain numbers (so the flight is Equatable).
struct RewardPlanTimes: Equatable {
    var pauseFrom: Int?
    var pause: Double

    init(_ plan: RewardPlan) {
        pauseFrom = plan.pauseFrom
        pause = plan.pause
    }

    func land(_ i: Int) -> Double {
        RewardPlan.burstAt + RewardPlan.burstOut + RewardPlan.flight + Double(i) * RewardPlan.stagger
            + ((pauseFrom.map { i >= $0 } ?? false) ? pause : 0)
    }
}

/// The bigger burst on a level up: sparks flying out from the title and fading.
struct SparkPop: Equatable {
    var start: Date
    var center: CGPoint
    var radius: CGFloat
}

/// Every spark of the reward, drawn in one canvas (no view per spark, no blur):
/// soft radial glows with a white core, added as light. Draws only while a reward
/// has sparks; otherwise it is not there at all.
struct HomeSparks: View {
    var flight: SparkFlight?
    var pop: SparkPop?

    private static let colors = [Color(hex: 0x7CF5C4), Color(hex: 0xA8E3FF), Color(hex: 0xC9B8FF),
                                 Color(hex: 0xFFF3C4)]

    var body: some View {
        if flight != nil || pop != nil {
            TimelineView(.animation) { context in
                Canvas { ctx, _ in
                    var g = ctx
                    g.blendMode = .plusLighter
                    if let flight { draw(flight, at: context.date.timeIntervalSince(flight.start), in: &g) }
                    if let pop { draw(pop, at: context.date.timeIntervalSince(pop.start), in: &g) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(_ f: SparkFlight, at t: Double, in g: inout GraphicsContext) {
        guard t >= RewardPlan.burstAt else { return }
        let n = RewardPlan.sparks
        for i in 0..<n {
            let d = Double(i)
            let color = Self.colors[i % Self.colors.count]
            // Out of "+10 XP" in a fan over the top, each a little further than the last.
            let angle = Double.pi + Double.pi * (d + 0.5) / Double(n)
            let reach = f.spread * CGFloat(0.55 + 0.3 * frac(d * 0.618))
            let u1 = min((t - RewardPlan.burstAt) / RewardPlan.burstOut, 1)
            let out = 1 - pow(1 - u1, 3)
            let b = CGPoint(x: f.origin.x + CGFloat(cos(angle)) * reach,
                            y: f.origin.y + CGFloat(sin(angle)) * reach * 0.8)
            let land = f.plan.land(i)
            let launch = land - RewardPlan.flight
            // Each lands at its own spot on Lanvi's chest.
            let to = CGPoint(x: f.target.x + (CGFloat(d) / CGFloat(n - 1) - 0.5) * f.spread * 0.45,
                             y: f.target.y + CGFloat(frac(d * 0.37) - 0.5) * f.spread * 0.2)
            // The arc swings out past the burst point, then curves in.
            let c = CGPoint(x: b.x + (b.x - f.origin.x) * 0.9, y: (b.y + to.y) / 2 - f.spread * 0.15)

            if t < launch {
                let drift = u1 < 1 ? 0 : CGFloat(sin(t * 4 + d)) * 2
                let p = CGPoint(x: f.origin.x + (b.x - f.origin.x) * CGFloat(out) + drift,
                                y: f.origin.y + (b.y - f.origin.y) * CGFloat(out) - drift)
                spark(at: p, size: CGFloat(0.5 + 0.5 * out), alpha: out, color: color, in: &g)
            } else if t < land {
                let u = (t - launch) / RewardPlan.flight
                // A short tail of two fainter points behind it.
                for (lag, a) in [(0.12, 0.25), (0.06, 0.5), (0.0, 1.0)] {
                    let e = max(u - lag, 0) * max(u - lag, 0)
                    spark(at: bezier(b, c, to, CGFloat(e)), size: CGFloat(1 - lag * 3), alpha: a, color: color, in: &g)
                }
            } else if t < land + 0.25 {
                // A small glint where it lands.
                let u = (t - land) / 0.25
                let r = CGFloat(6 + 14 * u)
                g.fill(Path(ellipseIn: CGRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.7 * (1 - u)), .clear]),
                                             center: to, startRadius: 0, endRadius: r))
            }
        }
    }

    private func draw(_ p: SparkPop, at t: Double, in g: inout GraphicsContext) {
        let dur = 0.9
        guard t >= 0, t < dur else { return }
        let u = t / dur
        let out = CGFloat(1 - pow(1 - u, 3))
        let fade = 1 - u * u
        // A soft ring opening out.
        let rr = p.radius * out
        g.stroke(Path(ellipseIn: CGRect(x: p.center.x - rr, y: p.center.y - rr * 0.7, width: rr * 2, height: rr * 1.4)),
                 with: .color(Color(hex: 0xA8E3FF).opacity(0.35 * fade)), lineWidth: 2)
        for i in 0..<12 {
            let d = Double(i)
            let angle = d / 12 * 2 * .pi + 0.2
            let dist = p.radius * out * CGFloat(0.8 + 0.3 * frac(d * 0.618))
            let at = CGPoint(x: p.center.x + CGFloat(cos(angle)) * dist,
                             y: p.center.y + CGFloat(sin(angle)) * dist * 0.7)
            spark(at: at, size: 1.35, alpha: fade, color: Self.colors[i % Self.colors.count], in: &g)
        }
    }

    private func spark(at p: CGPoint, size s: CGFloat, alpha a: Double, color: Color, in g: inout GraphicsContext) {
        guard a > 0.01, s > 0.05 else { return }
        let glow = 13 * s, core = 2.6 * s
        g.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
               with: .radialGradient(Gradient(colors: [color.opacity(0.6 * a), color.opacity(0.18 * a), .clear]),
                                     center: p, startRadius: 0, endRadius: glow))
        g.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
               with: .color(.white.opacity(a)))
    }

    private func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(x: m * m * a.x + 2 * m * t * c.x + t * t * b.x,
                       y: m * m * a.y + 2 * m * t * c.y + t * t * b.y)
    }

    private func frac(_ v: Double) -> Double { v - floor(v) }
}

// MARK: - Level up title

/// "Level 7", rising over the snow where "+10 XP" was. Under Reduce Motion it fades in.
struct HomeLevelTitle: View {
    var level: Int
    var night: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(Color(hex: 0x3FD9A0))
            Text("Level \(level)")
                .font(Theme.rounded(40, .black))
                .foregroundStyle(night ? Color.white : Theme.ink)
        }
        .shadow(color: night ? Color(hex: 0x7CF5C4).opacity(0.55) : .white.opacity(0.9), radius: 12)
        .scaleEffect(shown || reduceMotion ? 1 : 0.7)
        .offset(y: shown || reduceMotion ? 0 : 26)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.35) : .spring(response: 0.45, dampingFraction: 0.62)) {
                shown = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level)")
    }
}

// MARK: - Level on Home

/// The quiet level chip beside the Day pill: a thin ring of this level's progress
/// and "Lv 6". The same white pill look as the Day pill.
struct HomeLevelChip: View {
    var level: LanviLevel

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(Theme.tint, lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(level.progress, 0.04))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            Text("Lv \(level.level)")
                .font(Theme.rounded(17, .heavy))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: Double(level.level)))
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Capsule().fill(Color(hex: 0xFFFEFB)).shadow(color: Theme.ink.opacity(0.12), radius: 8, y: 3))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: level)
    }
}

/// The reward's strip on the snow: the level, the stage beside it, the XP counting
/// up, one bar that fills in ticks (full, a flash and a fresh start on a level up),
/// and then one line: how close the next level is. Type and one bar, no box.
struct HomeLevelStrip: View {
    var level: Int
    var stage: API.Stage
    var xp: Int
    var progress: Double
    var flash: Bool
    var nextLine: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Level \(level)")
                    .contentTransition(.numericText(value: Double(level)))
                Text("· \(TodayCopy.stageName(stage))")
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("\(xp) XP")
                    .contentTransition(.numericText(value: Double(xp)))
            }
            .font(Theme.rounded(17, .heavy))
            .foregroundStyle(Theme.ink)
            HomeProgressBar(progress: progress, height: 12)
                .overlay(Capsule().fill(.white).opacity(flash ? 0.85 : 0))
            Text(nextLine ?? " ")
                .font(Theme.rounded(15, .bold))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .opacity(nextLine == nil ? 0 : 1)
        }
    }
}
