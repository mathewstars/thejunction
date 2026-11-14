import SwiftUI

struct WelcomeView: View {
    var demo: Bool
    var onStart: () -> Void

    @Environment(AppStore.self) private var store

    @State private var bounce = 0

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.56
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                LanviView(pose: .cheer, size: 250, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - 125 + 16)
                    .onTapGesture { bounce += 1 }

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
            guard demo else { return }
            try? await Task.sleep(for: .seconds(1.2))
            bounce += 1
            try? await Task.sleep(for: .seconds(1.4))
            bounce += 1
        }
    }
}
