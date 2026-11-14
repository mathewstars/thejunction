import SwiftUI

// MARK: - Light flowing into the tail

/// After an activity: a stream of small comets flows from the card that was
/// played up into Lanvi's tail, where the glow then rises.
struct HomeLightStream: View {
    var from: CGPoint
    var to: CGPoint
    var start: Date
    static let duration: Double = 1.05

    private static let colors = [Color(hex: 0x3EE6A8), Color(hex: 0x5CCBFF), Color(hex: 0x9B7BFF), Color(hex: 0xFF7FD0)]

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, _ in
                let age = context.date.timeIntervalSince(start)
                guard age >= 0, age < Self.duration + 0.5 else { return }
                // A gentle arc: up and over towards the tail.
                let control = CGPoint(x: (from.x + to.x) / 2 + (to.x > from.x ? -60 : 60),
                                      y: min(from.y, to.y) - 80)
                for i in 0..<16 {
                    let delay = Double(i) * 0.03
                    let p = (age - delay) / Self.duration
                    guard p > 0, p < 1 else { continue }
                    let e = easeInOut(p)
                    let wobble = CGFloat(sin(Double(i) * 1.7 + age * 9)) * 10 * CGFloat(1 - e)
                    let color = Self.colors[i % Self.colors.count]
                    // Comet: a head and a short fading tail behind it.
                    for k in 0..<5 {
                        let q = max(0, e - Double(k) * 0.025)
                        var pt = bezier(from, control, to, q)
                        pt.x += wobble
                        let r = CGFloat(5.5 - Double(k)) * (k == 0 ? 1.0 : 0.8)
                        let a = (1 - Double(k) * 0.2) * (p > 0.85 ? (1 - p) / 0.15 : 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 3, y: pt.y - r * 3, width: r * 6, height: r * 6)),
                                  with: .radialGradient(Gradient(colors: [color.opacity(0.55 * a), .clear]),
                                                        center: pt, startRadius: 0, endRadius: r * 3))
                        var core = ctx
                        core.blendMode = .plusLighter
                        core.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                                  with: .radialGradient(Gradient(colors: [.white.opacity(a), color.opacity(0.6 * a), .clear]),
                                                        center: pt, startRadius: 0, endRadius: r))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let t = CGFloat(t), u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private func easeInOut(_ p: Double) -> Double { p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 }
}

// MARK: - Growing up

/// A short celebration when Lanvi reaches a new stage. Growth never goes back.
struct HomeGrowUpMoment: View {
    var stage: API.Stage
    var onDone: () -> Void

    @State private var shown = false
    @State private var bounce = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fox: CGFloat = min(240, w * 0.6)
            ZStack {
                // A deep night of its own, so Home does not show through.
                LinearGradient(colors: [Color(hex: 0x0D1A4A), Theme.nightTop, Color(hex: 0x2A3F9E)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .opacity(shown ? 1 : 0)

                // Rays of northern light turning slowly behind the fox.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(start)
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height * 0.42)
                        var rays = ctx
                        rays.blendMode = .plusLighter
                        rays.addFilter(.blur(radius: 10))
                        let grow = min(1, t / 0.8)
                        let len = max(size.width, size.height) * 0.75 * grow
                        let colors = [Color(hex: 0x3EE6A8), Color(hex: 0x9B7BFF), Color(hex: 0x5CCBFF), Color(hex: 0xFF7FD0)]
                        for i in 0..<12 {
                            let a = Double(i) / 12 * 2 * .pi + t * 0.25
                            var p = Path()
                            p.move(to: c)
                            p.addLine(to: CGPoint(x: c.x + cos(a - 0.09) * len, y: c.y + sin(a - 0.09) * len))
                            p.addLine(to: CGPoint(x: c.x + cos(a + 0.09) * len, y: c.y + sin(a + 0.09) * len))
                            p.closeSubpath()
                            rays.fill(p, with: .radialGradient(Gradient(colors: [colors[i % 4].opacity(0.55), .clear]),
                                                               center: c, startRadius: 0, endRadius: len))
                        }
                        // Motes rising all around.
                        var motes = ctx
                        motes.blendMode = .plusLighter
                        for i in 0..<28 {
                            let seed = Double(i) * 7.31
                            let speed = 0.10 + 0.08 * frac(sin(seed) * 437.5)
                            let life = frac(t * speed + frac(sin(seed * 2.3) * 913.1))
                            let x = size.width * frac(sin(seed * 4.1) * 1531.7)
                            let y = size.height * (1 - life)
                            let r = 2 + 3 * frac(sin(seed * 5.9) * 3141.5)
                            let a = sin(life * .pi) * grow
                            let pt = CGPoint(x: x + 10 * sin(t + seed), y: y)
                            motes.fill(Path(ellipseIn: CGRect(x: pt.x - r * 3, y: pt.y - r * 3, width: r * 6, height: r * 6)),
                                       with: .radialGradient(Gradient(colors: [colors[i % 4].opacity(0.6 * a), .clear]),
                                                             center: pt, startRadius: 0, endRadius: r * 3))
                            motes.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                                       with: .color(.white.opacity(a)))
                        }
                    }
                }
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)

                VStack(spacing: 14) {
                    Spacer()
                    ZStack {
                        HomeTailGlow(pose: .cheer, glow: 1, foxSize: fox)
                        LanviView(pose: .cheer, size: fox, bounceTrigger: bounce)
                    }
                    .frame(width: w, height: fox * 1.3)
                    .scaleEffect(shown ? 1 : 0.4)
                    Text("Lanvi grew up!")
                        .font(Theme.rounded(36, .black))
                        .foregroundStyle(.white)
                        .shadow(color: Color(hex: 0x7CF5C4).opacity(0.6), radius: 12)
                    Text(HomeGrowthCard.name(stage))
                        .font(Theme.rounded(18, .heavy))
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                        .background(Capsule().fill(Theme.line).offset(y: 4))
                    Text(caption)
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                    Spacer()
                    Button("Yay!") { close() }
                        .buttonStyle(ChunkyButtonStyle())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 30)
            }
        }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear {
            start = Date()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { shown = true }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                bounce += 1
                try? await Task.sleep(for: .milliseconds(900))
                bounce += 1
                try? await Task.sleep(for: .seconds(3.4))
                close()
            }
        }
    }

    private var caption: String {
        stage == .grownFox ? "Now my tail can paint little northern lights." : "Thanks for coming to play with me."
    }

    private func close() {
        guard shown else { return }
        withAnimation(.easeOut(duration: 0.35)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            onDone()
        }
    }

    private func frac(_ v: Double) -> Double { v - floor(v) }
}

// MARK: - Zoom from the tapped card (iOS 18 and later; a normal slide on 17)

extension View {
    @ViewBuilder func homeZoomSource(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: ns) } else { self }
    }

    @ViewBuilder func homeZoomTarget(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}
