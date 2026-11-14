import SwiftUI

/// A screen to judge the puppet: the fox large on the night sky and a button per
/// reaction. Launch with `-screen puppet`.
/// For proof stills: `-puppetFreeze happy:0.32` holds a reaction at that second,
/// `-puppetFreeze blink:0.08` holds a blink, `-puppetFreeze rest:0` holds the rest pose.
/// `-puppetDemo YES` plays idle for 7 s, then happy, then surprised (for the video).
struct LanviPuppetPreview: View {
    @State private var trigger = 0
    @State private var mood: LanviMood = .happy
    @State private var bounce = 0
    @State private var look: UnitPoint?
    @State private var lookStep = 0
    @State private var taps = 0

    private let freeze: LanviDebugFreeze? = {
        guard let raw = UserDefaults.standard.string(forKey: "puppetFreeze") else { return nil }
        let bits = raw.split(separator: ":")
        let name = String(bits.first ?? "")
        let at = bits.count > 1 ? Double(bits[1]) ?? 0 : 0
        if name == "blink" { return LanviDebugFreeze(reaction: nil, at: 0, blink: at) }
        return LanviDebugFreeze(reaction: LanviMood(rawValue: name), at: at, blink: nil)
    }()
    private let demo = UserDefaults.standard.bool(forKey: "puppetDemo")

    private let buttons: [(String, LanviMood)] = [
        ("Happy", .happy), ("Curious", .curious), ("Surprised", .surprised),
        ("Sleepy", .sleepy), ("Listening", .listening),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let hill = h * 0.64
            let fox = min(w * 0.86, 350)
            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                VStack(spacing: 4) {
                    Text("Lanvi")
                        .font(Theme.rounded(30, .heavy))
                        .foregroundStyle(.white)
                    Text("Tap him, or try a reaction")
                        .font(Theme.rounded(15, .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 8)

                LanviView(pose: .curious, size: fox, bounceTrigger: bounce)
                    .lanviReaction(mood, trigger: trigger)
                    .lanviLookAt(look)
                    .environment(\.lanviDebugFreeze, freeze)
                    .onTapGesture { taps += 1 }
                    .position(x: w / 2, y: hill - fox / 2 + 26)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(buttons.prefix(3), id: \.0) { b in reactionButton(b.0, b.1) }
                    }
                    HStack(spacing: 12) {
                        ForEach(buttons.suffix(2), id: \.0) { b in reactionButton(b.0, b.1) }
                        Button("Look") { nextLook() }
                            .buttonStyle(ChunkyButtonStyle(fill: Theme.tint, edge: Color(hex: 0xC5D3F5), text: Theme.brand))
                    }
                    Button("Hop") { bounce += 1 }
                        .buttonStyle(ChunkyButtonStyle(fill: Theme.tint, edge: Color(hex: 0xC5D3F5), text: Theme.brand))
                }
                .padding(.horizontal, 20)
                .padding(.top, hill + 44)
            }
        }
        .task {
            guard demo else { return }
            try? await Task.sleep(for: .seconds(7))
            play(.happy)
            try? await Task.sleep(for: .seconds(2.6))
            play(.surprised)
        }
    }

    private func reactionButton(_ title: String, _ m: LanviMood) -> some View {
        Button(title) { play(m) }
            .buttonStyle(ChunkyButtonStyle())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func play(_ m: LanviMood) {
        mood = m
        trigger += 1
    }

    private func nextLook() {
        let spots: [UnitPoint?] = [UnitPoint(x: 1.1, y: -0.1), UnitPoint(x: -0.2, y: 0.1),
                                  UnitPoint(x: 0.5, y: -0.6), UnitPoint(x: 0.5, y: 1.4), nil]
        look = spots[lookStep % spots.count]
        lookStep += 1
    }
}
