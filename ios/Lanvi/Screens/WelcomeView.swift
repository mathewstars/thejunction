import SwiftUI

struct WelcomeView: View {
    var demo: Bool
    var onStart: () -> Void

    @Environment(AppStore.self) private var store

    /// One greeting when the screen arrives (a happy squint and a tail wag, no hop).
    @State private var greet = 0

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.56
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                LanviView(pose: .curious, size: 250)
                    .lanviReaction(.happy, trigger: greet)
                    .lanviHops(false)
                    .position(x: geo.size.width / 2, y: hill - 125 + 16)

                VStack(spacing: 6) {
                    Spacer().frame(height: hill + 40)
                    Text("lanvi")
                        .font(Theme.rounded(56, .black))
                        .foregroundStyle(Theme.brand)
                    Text("You did the hard part.\nLanvi helps it last.")
                        .font(Theme.rounded(18, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                    Button("Get started", action: onStart)
                        .buttonStyle(ChunkyButtonStyle())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                .frame(width: geo.size.width)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(demo ? 1200 : 600))
            greet += 1
        }
    }
}
