import SwiftUI

// Every helper here is prefixed with `Checkin` so it never clashes with the other screens' helpers.

/// Evening colours for words and tiles on the night sky.
enum CheckinEvening {
    static let skyText = Color(hex: 0xD3DEFF)   // secondary text on the sky
    /// A tile at rest: night glass, a little lighter than the sky so it stands out.
    static let tileFill = LinearGradient(colors: [Color(hex: 0x3A58B4), Color(hex: 0x2A4497)],
                                         startPoint: .top, endPoint: .bottom)
    /// The tile's 3D edge underneath.
    static let tileEdge = Color(hex: 0x15245F)
    /// A picked tile: Lanvi blue, lit from within.
    static let pickedFill = LinearGradient(colors: [Color(hex: 0x6A8CF5), Theme.brand],
                                           startPoint: .top, endPoint: .bottom)
}

/// One point of light: a wide faint halo, a brighter glow and a white-hot core. Draw it on a
/// canvas that is blended with `plusLighter`.
enum CheckinLight {
    static func draw(_ ctx: GraphicsContext, at p: CGPoint, radius r: CGFloat, color: Color, alpha: Double) {
        guard alpha > 0.01 else { return }
        func disc(_ radius: CGFloat) -> Path { Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)) }
        ctx.fill(disc(r * 1.6), with: .radialGradient(
            Gradient(colors: [color.opacity(0.5 * alpha), color.opacity(0.14 * alpha), color.opacity(0)]),
            center: p, startRadius: 0, endRadius: r * 1.6))
        ctx.fill(disc(r * 0.5), with: .radialGradient(
            Gradient(colors: [.white.opacity(alpha), color.opacity(0.8 * alpha), color.opacity(0)]),
            center: p, startRadius: 0, endRadius: r * 0.5))
    }
}

/// One mote of light as a view (used in the little tray of three lights).
struct CheckinMote: View {
    var size: CGFloat
    var color: Color = Theme.aurora

    var body: some View {
        Canvas { ctx, s in
            CheckinLight.draw(ctx, at: CGPoint(x: s.width / 2, y: s.height / 2), radius: size, color: color, alpha: 1)
        }
        .frame(width: size * 3.4, height: size * 3.4)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// The round icon at the start of a tile. Lit: a white bubble with a blue icon and a soft
/// aurora glow behind it. Not lit: a faint see-through bubble.
struct CheckinIconBubble: View {
    var symbol: String
    var lit: Bool
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            if lit {
                CheckinMote(size: size * 0.62, color: GameAurora.mint)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            Circle()
                .fill(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.13)))
                .overlay(Circle().strokeBorder(.white.opacity(lit ? 0 : 0.12), lineWidth: 1))
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(lit ? Theme.brand : .white.opacity(0.92))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: lit)
    }
}

/// What goes inside a tile: the icon bubble and the words.
struct CheckinTileLabel: View {
    var text: String
    var symbol: String
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            CheckinIconBubble(symbol: selected && symbol != "pencil" ? "checkmark" : symbol, lit: selected)
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A chunky Duolingo-style tile on the night sky. At rest it stands on a 3D edge; pressing
/// pushes it down onto the edge; picked, it stays pressed in, turns Lanvi blue and glows
/// with an aurora rim. `dashed` is the see-through "Write my own" tile.
struct CheckinTileStyle: ButtonStyle {
    var selected: Bool
    var dimmed: Bool = false
    var dashed: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let edge: CGFloat = 5
        let down: CGFloat = pressed ? edge : (selected ? 3 : 0)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .font(Theme.rounded(compact ? 14.5 : 16, .heavy))
            .foregroundStyle(.white)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            // Every tile the same height, so rows line up even when a label takes two lines.
            .frame(maxWidth: .infinity, minHeight: compact ? 54 : 62, maxHeight: compact ? 54 : 62, alignment: .leading)
            .background {
                if dashed {
                    shape.fill(.white.opacity(pressed ? 0.16 : 0.07))
                } else {
                    shape.fill(selected ? CheckinEvening.pickedFill : CheckinEvening.tileFill)
                }
            }
            .overlay(alignment: .top) {
                // A soft gloss along the top edge, so it reads as a raised, rounded tile.
                if !dashed {
                    shape.fill(LinearGradient(colors: [.white.opacity(selected ? 0.22 : 0.12), .clear],
                                              startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if dashed {
                    shape.strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                } else if selected {
                    shape.strokeBorder(LinearGradient(colors: [GameAurora.mint, Theme.aurora],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.5)
                } else {
                    shape.strokeBorder(.white.opacity(0.14), lineWidth: 1.5)
                }
            }
            .shadow(color: GameAurora.mint.opacity(selected ? 0.4 : 0), radius: 12)
            .offset(y: down)
            .background {
                shape.fill(dashed ? Color.white.opacity(0.08) : (selected ? Theme.brandEdge : CheckinEvening.tileEdge))
                    .offset(y: edge)
            }
            .padding(.bottom, edge)
            .opacity(dimmed ? 0.5 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: selected)
            .animation(.easeInOut(duration: 0.25), value: dimmed)
    }
}

/// Secondary chunky button on the night: see-through night glass with white words, same 3D press.
struct CheckinQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .font(Theme.rounded(16, .heavy))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(shape.fill(CheckinEvening.tileFill))
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1.5))
            .offset(y: pressed ? 5 : 0)
            .background(shape.fill(CheckinEvening.tileEdge).offset(y: 5))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// A small glass pill for corner actions on the sky (Help).
struct CheckinGlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(Capsule().fill(CheckinEvening.tileFill))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1.5))
            .offset(y: pressed ? 3 : 0)
            .background(Capsule().fill(CheckinEvening.tileEdge).offset(y: 3))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}

/// Three slots in a little night-sky tray. Each good thing lights one with a breathing mote.
struct CheckinSparkTray: View {
    var count: Int
    var total: Int = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ForEach(0..<total, id: \.self) { i in
                    let lit = i < count
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                                 center: .center, startRadius: 0, endRadius: 5))
                            .frame(width: 9, height: 9)
                        if lit {
                            CheckinMote(size: 9, color: i == 1 ? GameAurora.violet : GameAurora.mint)
                                .scaleEffect(1 + 0.08 * sin(t * 2.4 + Double(i)))
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(hex: 0x081039), Color(hex: 0x182C78)],
                                              startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: count)
        .accessibilityElement()
        .accessibilityLabel("\(count) of \(total) picked")
    }
}

/// Chunky progress bar for the steps: a sunk track and a glowing aurora fill with a gloss line.
struct CheckinProgress: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0x07103A).opacity(0.55))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1.5))
                Capsule()
                    .fill(LinearGradient(colors: [GameAurora.mint, Theme.aurora, Theme.auroraViolet],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.55)).frame(height: 4).padding(.horizontal, 7).padding(.top, 3)
                    }
                    .frame(width: max(18, geo.size.width * progress))
                    .shadow(color: GameAurora.mint.opacity(0.6), radius: 8)
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: progress)
    }
}
