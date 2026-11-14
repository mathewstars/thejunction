import SwiftUI

// MARK: - Help

/// The help text from the server, with its phone numbers as big call buttons.
/// One tap from Home, always.
struct HomeHelpScreen: View {
    var crisis: API.CrisisBlock
    var onClose: () -> Void

    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let hill = geo.size.height * (compact ? 0.55 : 0.62)
            let fox: CGFloat = compact ? 160 : 220
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                LanviView(pose: .love, size: fox)
                    .lanviHops(false)
                    .position(x: geo.size.width / 2, y: hill - fox / 2 + 12)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Lanvi")
                    .accessibilityIdentifier("help.fox")

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Help is here")
                                .font(Theme.rounded(28, .black))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if !crisis.reviewedByClinician {
                                Text("Draft wording")
                                    .font(Theme.rounded(12, .heavy))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.tint))
                            }
                        }
                        Text(crisis.text)
                            .font(Theme.rounded(18, .semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(crisis.contacts, id: \.phone) { c in
                            if let url = URL(string: "tel:\(c.phone.filter { $0.isNumber || $0 == "+" })") {
                                Link(destination: url) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "phone.fill")
                                        Text("Call \(c.phone)")
                                    }
                                }
                                .buttonStyle(ChunkyButtonStyle())
                                Text(c.label)
                                    .font(Theme.rounded(14, .bold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, -6)
                            }
                        }
                        FaceSenseSwitch()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, hill + 22)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)

                HStack {
                    HomeCloseButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
    }
}
