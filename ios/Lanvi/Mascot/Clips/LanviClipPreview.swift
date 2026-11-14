import SwiftUI

/// A screen to judge the clip fox: Lanvi at Home size on the painted scene, a button
/// per clip, night/day, and the puppet laid over at half opacity to check that the
/// two sit in exactly the same place. Launch with `-screen clips` (add `-offline`).
/// `-clipsScene day` starts on the day scene, `-clipsCompare YES` with the overlay.
struct LanviClipPreview: View {
    @State private var request: FoxClipRequest?
    @State private var tick = 0
    @State private var scene: WorldScene =
        WorldScene(rawValue: UserDefaults.standard.string(forKey: "clipsScene") ?? "") ?? .night
    @State private var compare = UserDefaults.standard.bool(forKey: "clipsCompare")

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let fox = min(h * 0.46, w * 0.86)
            ZStack(alignment: .top) {
                PaintedWorld(scene: scene)
                ZStack {
                    LanviClipView(pose: .curious, size: fox, bounceTrigger: 0)
                        .environment(\.foxClipRequest, request)
                    if compare {
                        LanviPuppet(pose: .curious, size: fox, bounceTrigger: 0)
                            .opacity(0.45)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: fox, height: fox)
                .position(x: w / 2, y: h * 0.62 - fox / 2)

                VStack(spacing: 8) {
                    Spacer()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(FoxClip.allCases, id: \.self) { clip in
                            button(clip.rawValue.capitalized + (clip.isAvailable ? "" : "*")) {
                                tick += 1
                                request = FoxClipRequest(clip: clip, token: tick)
                            }
                            .accessibilityIdentifier("clips." + clip.rawValue)
                        }
                        button(scene == .night ? "Day" : "Night") { scene = scene == .night ? .day : .night }
                        button(compare ? "Puppet off" : "Puppet on") { compare.toggle() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(14, .bold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(.white.opacity(0.92)))
        }
        .buttonStyle(.plain)
    }
}

/// Test screens only: play one clip now (cross-faded in), each time `token` changes.
struct FoxClipRequest: Equatable {
    var clip: FoxClip
    var token: Int
}

private struct FoxClipRequestKey: EnvironmentKey { static let defaultValue: FoxClipRequest? = nil }

extension EnvironmentValues {
    var foxClipRequest: FoxClipRequest? {
        get { self[FoxClipRequestKey.self] }
        set { self[FoxClipRequestKey.self] = newValue }
    }
}
