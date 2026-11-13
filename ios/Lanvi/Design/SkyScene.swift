import SwiftUI

/// Full-bleed winter sky: gradient, slowly drifting aurora, a few stars, snowy hills.
/// `hillTop` is where the white snow starts, in points from the top.
struct SkyScene: View {
    var top: Color
    var bottom: Color
    var hillTop: CGFloat

    private let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.10, 0.18, 3), (0.24, 0.42, 2), (0.84, 0.22, 3), (0.72, 0.50, 2), (0.15, 0.66, 2),
        (0.90, 0.68, 3), (0.44, 0.12, 2), (0.58, 0.34, 2), (0.05, 0.86, 2), (0.95, 0.90, 2),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let drift = CGFloat(sin(t * 2 * .pi / 14))
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

                    Capsule()
                        .fill(Theme.aurora.opacity(0.38))
                        .frame(width: w * 1.5, height: 74)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -w * 0.25 + drift * 18, y: hillTop * 0.26)
                        .blur(radius: 18)
                    Capsule()
                        .fill(Theme.auroraViolet.opacity(0.30))
                        .frame(width: w * 1.4, height: 52)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -w * 0.15 - drift * 14, y: hillTop * 0.26 + 74)
                        .blur(radius: 16)

                    ForEach(stars.indices, id: \.self) { i in
                        let s = stars[i]
                        let twinkle = 0.55 + 0.45 * sin(t * 1.7 + Double(i))
                        Circle()
                            .fill(.white.opacity(twinkle))
                            .frame(width: s.2, height: s.2)
                            .offset(x: w * s.0, y: max(hillTop - 50, 1) * s.1)
                    }

                    Ellipse()
                        .fill(Color(hex: 0xDCE6FA))
                        .frame(width: w * 2.4, height: 760)
                        .offset(x: -w * 0.95, y: hillTop - 30)
                    Ellipse()
                        .fill(.white)
                        .frame(width: w * 2.6, height: 860)
                        .offset(x: -w * 0.55, y: hillTop)
                }
            }
        }
        .ignoresSafeArea()
    }
}
