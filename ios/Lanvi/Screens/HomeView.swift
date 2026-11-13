import SwiftUI

struct HomeView: View {
    var demo: Bool

    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    private let cycle: [LanviPose] = [.curious, .love, .surprised, .cheer, .meh, .grumpy, .peek]

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.40
            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                LanviView(pose: pose, size: 200, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - 100 + 14)
                    .onTapGesture { next() }

                HStack {
                    Chip(icon: "lifepreserver.fill", text: "Help")
                    Spacer()
                    GlowChip(progress: 0.65)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Want to breathe with me for a minute?")
                        .font(Theme.rounded(28, .heavy))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Breathe with Lanvi") { react(.love) }
                        .buttonStyle(ChunkyButtonStyle())
                    Text("More for today")
                        .font(Theme.rounded(17, .heavy))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 6)
                    HStack(alignment: .top, spacing: 12) {
                        Tile(icon: "sparkles", title: "Sparks and snow", caption: "45 seconds") { react(.surprised) }
                        Tile(icon: "moon.stars.fill", title: "Check-in", caption: "This evening, 1 minute") { react(.meh) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, hill + 20)

                VStack {
                    Spacer()
                    TabBar()
                }
            }
        }
        .task {
            guard demo else { return }
            try? await Task.sleep(for: .seconds(1.0))
            for _ in 0..<14 {
                next()
                try? await Task.sleep(for: .seconds(1.8))
            }
        }
    }

    private func next() {
        let i = cycle.firstIndex(of: pose) ?? 0
        react(cycle[(i + 1) % cycle.count])
    }

    private func react(_ newPose: LanviPose) {
        bounce &+= 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = newPose }
    }
}

private struct Chip: View {
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(Theme.rounded(16, .heavy))
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Capsule().fill(.white.opacity(0.18)))
    }
}

private struct GlowChip: View {
    var progress: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.glow)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 64, height: 10)
                Capsule().fill(Theme.glow).frame(width: 64 * progress, height: 10)
            }
        }
        .font(Theme.rounded(16, .heavy))
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Capsule().fill(.white.opacity(0.18)))
    }
}

private struct Tile: View {
    var icon: String
    var title: String
    var caption: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle().fill(Theme.tint)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.brand)
                }
                .frame(width: 44, height: 44)
                Text(title)
                    .font(Theme.rounded(17, .heavy))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChunkyCardStyle())
    }
}

private struct TabBar: View {
    var body: some View {
        HStack {
            item("house.fill", "Today", active: true)
            item("pawprint.fill", "Lanvi", active: false)
            item("person.fill", "You", active: false)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(Color.white.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 2) }
    }

    private func item(_ icon: String, _ label: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold))
            Text(label).font(Theme.rounded(12, .heavy))
        }
        .foregroundStyle(active ? Theme.brand : Theme.inkSecondary)
        .frame(maxWidth: .infinity)
    }
}
