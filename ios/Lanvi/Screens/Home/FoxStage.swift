import SwiftUI

/// ONE layout for Lanvi on every full-screen page (first run, permission pages,
/// Home, the reward): the same size, exactly on the horizontal centre, standing in
/// the painted clearing on the same ground line, with the primary button in the
/// same place. Taken from Home, which the captain likes.
///
/// A page with extra controls between Lanvi and the button (What helps' chips)
/// passes their height: Lanvi then stands that much higher, never behind them,
/// and shrinks only if the page is too short to keep clear air for the bubble.
struct FoxStage {
    let size: CGSize
    let compact: Bool
    let fox: CGFloat            // Lanvi's square size
    let feetY: CGFloat          // where the paws meet the snow
    let buttonY: CGFloat        // centre of the primary button
    let foxCenter: CGPoint

    var foxTop: CGFloat { feetY - fox }
    /// Where Lanvi's speech bubble points: just above and right of the face, as on Home.
    var speechTarget: CGPoint { CGPoint(x: foxCenter.x + fox * 0.10, y: foxTop + fox * 0.04) }

    init(size: CGSize, insets: EdgeInsets, controls: CGFloat = 0) {
        self.size = size
        compact = size.height < 700
        let bottomGap: CGFloat = compact ? 16 : 8
        buttonY = size.height - bottomGap - 30
        // Where the painting's hollow lands on this screen: Lanvi sits in it.
        let screen = CGSize(width: size.width, height: size.height + insets.top + insets.bottom)
        let world = WorldFrame(screen: screen)
        let hollow = world.point(WorldFrame.hollow.x, WorldFrame.hollow.y)
        let big = min(size.height * 0.46, size.width * 0.86)
        let gap: CGFloat = controls > 0 ? 16 : 0
        feetY = min(hollow.y - insets.top + big * 0.03, buttonY - 30 - 24 - controls - gap)
        // Keep clear air above the ears for the speech bubble.
        let minTop: CGFloat = compact ? 120 : 160
        fox = max(min(big, feetY - minTop), 120)
        foxCenter = CGPoint(x: size.width / 2, y: feetY - fox / 2)
    }
}

/// Lanvi settled into the snow: a soft contact shadow tinted to the scene's
/// light, the paws a few points into the snow behind a small drift drawn in the
/// scene's own snow colour, and a little cooler and dimmer at night. Place it in
/// a full-screen ZStack (top-left origin).
struct GroundedFox<Fox: View>: View {
    var stage: FoxStage
    var scene: WorldScene
    @ViewBuilder var fox: () -> Fox

    /// How far the paws sink into the snow.
    private var sink: CGFloat { stage.fox * 0.025 }

    var body: some View {
        let w = stage.fox
        let feet = stage.feetY
        ZStack(alignment: .topLeading) {
            // Contact shadow on the snow, matched to the scene's light.
            Ellipse()
                .fill(RadialGradient(colors: [shadowColor.opacity(shadowStrength), shadowColor.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: w * 0.36))
                .frame(width: w * 0.78, height: w * 0.12)
                .position(x: stage.foxCenter.x, y: feet + sink * 0.4)

            fox()
                .colorMultiply(scene == .night ? Color(red: 0.86, green: 0.88, blue: 0.97) : .white)
                .frame(width: w, height: w)
                .position(x: stage.foxCenter.x, y: stage.foxCenter.y + sink)

            // A small drift of snow in front of the paws, so he sits in it, not on it.
            Ellipse()
                .fill(LinearGradient(colors: [snow.opacity(0), snow.opacity(0.95), snow],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.46, height: w * 0.075)
                .blur(radius: 1.5)
                .position(x: stage.foxCenter.x, y: feet + sink * 0.6)
                .allowsHitTesting(false)
        }
        .frame(width: stage.size.width, height: stage.size.height, alignment: .topLeading)
    }

    private var snow: Color {
        switch scene {
        case .dawn: return Color(hex: 0xFBF3F2)
        case .day: return Color(hex: 0xF3F7FF)
        case .night: return Color(hex: 0xC9D3F0)
        }
    }

    private var shadowColor: Color {
        scene == .night ? Color(hex: 0x0D1B52) : Color(hex: 0x4E66A8)
    }

    private var shadowStrength: Double { scene == .night ? 0.45 : 0.28 }
}
