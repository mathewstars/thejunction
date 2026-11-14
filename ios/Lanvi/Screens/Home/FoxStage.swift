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

/// Lanvi on his place in the clearing. Nothing is drawn under or in front of
/// the paws (no shadow, no drift): the captain wants the painting as it is.
/// He is a little cooler and dimmer at night. Place it in a full-screen ZStack
/// (top-left origin).
struct GroundedFox<Fox: View>: View {
    var stage: FoxStage
    var scene: WorldScene
    @ViewBuilder var fox: () -> Fox

    /// How far the paws sit into the snow.
    private var sink: CGFloat { stage.fox * 0.025 }

    var body: some View {
        let w = stage.fox
        fox()
            .colorMultiply(scene == .night ? Color(red: 0.86, green: 0.88, blue: 0.97) : .white)
            .frame(width: w, height: w)
            .position(x: stage.foxCenter.x, y: stage.foxCenter.y + sink)
            .frame(width: stage.size.width, height: stage.size.height, alignment: .topLeading)
    }
}
