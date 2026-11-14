import SwiftUI

// Shared by the three activities (Sparks and snow, Breathe with Lanvi, Evening check-in):
// the world behind them, where Lanvi sits, the text colours that read on it, and the one
// close button. Change the world here and all three games follow.

/// Which world the games are drawn in.
enum GameWorldStyle {
    /// The hand-painted scenes Home uses (`PaintedWorld`).
    case painted
    /// A clean drawn sky in blue and white (`SkyScene`), no painting.
    case cleanSky
}

enum GameWorld {
    /// THE switch. Flip it and all three games restyle.
    static let style: GameWorldStyle = .painted
}

/// Where things sit on the whole screen, safe areas included (points from the very top).
/// Every game draws in these full-screen points so they line up with the painting.
struct GameStage {
    let size: CGSize
    let insets: EdgeInsets
    let world: WorldFrame

    /// From a `GeometryReader` that respects the safe area.
    init(_ geo: GeometryProxy) {
        insets = geo.safeAreaInsets
        size = CGSize(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
        world = WorldFrame(screen: size)
    }

    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    /// The iPhone SE and other short screens.
    var compact: Bool { size.height < 700 }

    /// The hollow in the painted clearing where Lanvi sits.
    var hollow: CGPoint { world.point(WorldFrame.hollow.x, WorldFrame.hollow.y) }
    /// Roughly where the far hills meet the sky.
    var horizon: CGFloat { world.point(0.5, 0.56).y }

    /// The first point below the status bar.
    var top: CGFloat { insets.top }
    /// The last point above the home indicator, with a little air.
    var bottom: CGFloat { size.height - max(insets.bottom, 14) - (compact ? 4 : 0) }

    /// Where the top bar (close button) sits: its vertical centre.
    var barY: CGFloat { top + 8 + 22 }
    /// Just below the top bar.
    var belowBar: CGFloat { top + 62 }

    /// Lanvi's feet: in the painted hollow, but never so low that `reserve` points
    /// (buttons, words) no longer fit underneath.
    func feet(fox: CGFloat, reserve: CGFloat) -> CGFloat {
        min(hollow.y + fox * 0.03, bottom - reserve)
    }

    /// The bottom primary button's centre.
    var buttonY: CGFloat { bottom - 27 }
}

/// The sky and ground behind a game. One place decides what it looks like (`GameWorld.style`).
struct GameBackdrop: View {
    var scene: WorldScene
    var stage: GameStage
    var snow: Bool = true

    var body: some View {
        switch GameWorld.style {
        case .painted:
            PaintedWorld(scene: scene, snow: snow)
        case .cleanSky:
            let colours = Self.cleanColours(scene)
            SkyScene(top: colours.0, bottom: colours.1, hillTop: stage.hollow.y - stage.height * 0.13)
                .animation(.easeInOut(duration: 1.6), value: scene)
                .allowsHitTesting(false)
        }
    }

    private static func cleanColours(_ scene: WorldScene) -> (Color, Color) {
        switch scene {
        case .night: (Theme.nightTop, Theme.nightBottom)
        case .day: (Theme.skyTop, Theme.skyBottom)
        case .dawn: (Color(hex: 0x2B3A9C), Color(hex: 0x9E9BEA))
        }
    }

    /// The scene for right now: the app's (it knows `-hour`), else the clock's.
    static func current(_ store: AppStore?) -> WorldScene {
        store?.worldScene ?? .at(hour: Calendar.current.component(.hour, from: Date()))
    }
}

/// Text colours that read on the sky of a scene, and on the snow.
struct GameInk {
    var title: Color
    var body: Color
    var shadow: Color

    /// Words on the sky.
    static func sky(_ scene: WorldScene) -> GameInk {
        let darkSky = GameWorld.style == .cleanSky || scene == .night
        return darkSky
            ? GameInk(title: .white, body: Color(hex: 0xD3DEFF), shadow: Color(hex: 0x0A1442).opacity(0.45))
            : GameInk(title: Theme.ink, body: Theme.inkSecondary, shadow: .white.opacity(0.6))
    }

    /// Words on the snow at the bottom.
    static let snow = GameInk(title: Theme.ink, body: Theme.inkSecondary, shadow: .white.opacity(0.7))
}

extension View {
    /// A soft halo so words stay readable over the painting without a box behind them.
    func gameLegible(_ ink: GameInk) -> some View {
        shadow(color: ink.shadow, radius: 10).shadow(color: ink.shadow.opacity(0.6), radius: 2, y: 1)
    }
}

/// A very soft pool of night behind words that sit over bright aurora: no edge, no box,
/// only enough shade to keep white words crisp.
struct GameShade: View {
    var body: some View {
        Ellipse()
            .fill(Color(hex: 0x0A1442).opacity(0.3))
            .padding(.horizontal, -10)
            .padding(.vertical, -6)
            .blur(radius: 28)
            .allowsHitTesting(false)
    }
}

/// The one close button every game uses: chunky, round, blue, top-left.
struct GameCloseButton: View {
    var label = "Close"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
        }
        .buttonStyle(Style())
        .accessibilityLabel(label)
    }

    private struct Style: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            configuration.label
                .frame(width: 44, height: 44)
                .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x5277EC), Theme.brand],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(alignment: .top) {
                    Capsule().fill(.white.opacity(0.3)).frame(width: 18, height: 5).padding(.top, 6)
                }
                .offset(y: pressed ? 4 : 0)
                .background(Circle().fill(Theme.brandEdge).offset(y: 4))
                .contentShape(Circle())
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.spring(response: 0.18, dampingFraction: 0.62), value: pressed)
                .sensoryFeedback(.impact(weight: .light), trigger: pressed)
        }
    }
}

/// One line of words at a time: the old line fades out completely, then the new one
/// fades in with a small rise. Never two lines on top of each other.
struct GameLine: View {
    var text: String
    var font: Font
    var color: Color
    var out: Double = 0.2
    var into: Double = 0.38

    @State private var shown: String?
    @State private var visible = false
    @State private var generation = 0

    var body: some View {
        Text(shown ?? text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 7)
            .scaleEffect(visible ? 1 : 0.97)
            .onAppear {
                shown = text
                withAnimation(.easeOut(duration: into)) { visible = true }
            }
            .onChange(of: text) { _, _ in swap() }
            .accessibilityLabel(text)
    }

    private func swap() {
        generation += 1
        let mine = generation
        withAnimation(.easeIn(duration: out)) {
            visible = false
        } completion: {
            guard mine == generation else { return }
            shown = text
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: into)) { visible = true }
        }
    }
}

/// Small easing helpers for drawing code (Canvas), so nothing moves linearly.
enum GameEase {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smooth(_ x: Double) -> Double { let v = clamp(x); return v * v * (3 - 2 * v) }
    static func outCubic(_ x: Double) -> Double { let v = clamp(x); return 1 - pow(1 - v, 3) }
    static func inOutSine(_ x: Double) -> Double { let v = clamp(x); return 0.5 - 0.5 * cos(v * .pi) }
    /// 0 below `a`, 1 above `b`, smooth in between.
    static func step(_ a: Double, _ b: Double, _ x: Double) -> Double { smooth((x - a) / (b - a)) }
    static func fract(_ x: Double) -> Double { x - floor(x) }
}
