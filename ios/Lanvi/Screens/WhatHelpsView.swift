import SwiftUI

/// First run, after Welcome: "What usually helps you?" Up to four, in the
/// order tapped; sent with `PUT /v1/preferences` and Lanvi answers with the
/// returned line. Skippable.
struct WhatHelpsView: View {
    var demo: Bool
    var onDone: () -> Void

    @Environment(AppStore.self) private var store
    @State private var chosen: [String] = []
    @State private var say = "What usually helps you? Pick as many as you like."
    /// One reaction at a time; never the same one twice in a row.
    @State private var reaction: LanviMood = .listening
    @State private var reactTick = 0
    @State private var proud = false
    @State private var sending = false

    private struct Choice: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
    }

    private let choices = [
        Choice(id: "music", title: "Music", icon: "music.note", tint: Color(hex: 0xFF7FD0)),
        Choice(id: "moving", title: "Moving", icon: "figure.walk", tint: Color(hex: 0x3EE6A8)),
        Choice(id: "people", title: "People", icon: "person.2.fill", tint: Color(hex: 0xFFB45C)),
        Choice(id: "quiet", title: "Quiet", icon: "leaf.fill", tint: Color(hex: 0x9B7BFF)),
    ]

    var body: some View {
        GeometryReader { geo in
            let chipsHeight: CGFloat = 66 * 2 + 12
            // The shared fox layout, raised just enough for the chips in front of him.
            let stage = FoxStage(size: geo.size, insets: geo.safeAreaInsets, controls: chipsHeight)
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                GroundedFox(stage: stage, scene: store.worldScene) {
                    LanviView(pose: .curious, size: stage.fox)
                        .lanviReaction(reaction, trigger: reactTick)
                        .lanviMood(proud ? .happy : nil)
                        .lanviHops(false)
                }

                VStack {
                    Spacer(minLength: 0)
                    HomeSpeechBubble(text: say)
                }
                .frame(width: geo.size.width - 48, height: max(stage.foxTop - (stage.compact ? 40 : 56), 60))
                .padding(.top, stage.compact ? 28 : 44)

                // Chips on the snow in front of Lanvi; they never animate their place.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(choices) { c in
                        chip(c)
                    }
                }
                .frame(height: chipsHeight)
                .padding(.horizontal, 24)
                .position(x: geo.size.width / 2, y: stage.buttonY - 30 - 16 - chipsHeight / 2)

                // The button in the same place as on every first-run page and Home.
                Button(chosen.isEmpty ? "Skip for now" : "That's it") { finish() }
                    .buttonStyle(HomePrimaryStyle(fill: chosen.isEmpty ? .white : Theme.brand,
                                                  edge: chosen.isEmpty ? Theme.line : Theme.brandEdge,
                                                  text: chosen.isEmpty ? Theme.brand : .white))
                    .disabled(sending)
                    .frame(width: geo.size.width - 48)
                    .position(x: geo.size.width / 2, y: stage.buttonY)
                    .animation(LanviTiming.swap, value: chosen.isEmpty)
            }
        }
        .task {
            // Arriving: ears up and a small nod, "I'm listening".
            try? await Task.sleep(for: .milliseconds(450))
            reactTick += 1
            await runDemo()
        }
    }

    private func chip(_ c: Choice) -> some View {
        let order = chosen.firstIndex(of: c.id).map { $0 + 1 }
        let on = order != nil
        return Button { toggle(c.id) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(RadialGradient(colors: [c.tint.opacity(on ? 0.9 : 0.35), c.tint.opacity(on ? 0.45 : 0.12)],
                                                 center: .topLeading, startRadius: 2, endRadius: 40))
                    Circle().stroke(.white.opacity(0.8), lineWidth: 2).padding(2)
                    Image(systemName: c.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(on ? .white : Theme.brand)
                }
                .frame(width: 42, height: 42)
                // One line, always: a selected chip must keep exactly the same size.
                Text(c.title)
                    .font(Theme.rounded(18, .heavy))
                    .foregroundStyle(on ? .white : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                // The order badge's place is always reserved; it only fades and pops.
                Text("\(order ?? 0)")
                    .font(Theme.rounded(14, .black))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white))
                    .scaleEffect(on ? 1 : 0.4)
                    .opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
        }
        .buttonStyle(HelpsChipStyle(on: on))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        // Only the chips' own colour and badge change (each chip animates itself);
        // nothing is wrapped in a transaction, so no chip can travel to a new place.
        if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else if chosen.count < 4 { chosen.append(id) }
        // A happy squint for a choice, a head tilt for the next one, and so on.
        react(reaction == .happy ? .curious : .happy)
    }

    private func finish() {
        guard !sending else { return }
        if chosen.isEmpty { onDone(); return }
        sending = true
        react(.listening)          // a nod: thank you, noted
        Task {
            let line = await store.setPreferences(chosen)
            say = line ?? "Got it. Thank you for telling me."
            proud = true
            try? await Task.sleep(for: .seconds(demo ? 2.6 : 1.9))
            onDone()
        }
    }

    private func react(_ mood: LanviMood) {
        reaction = mood
        reactTick += 1
    }

    private func runDemo() async {
        guard demo else { return }
        try? await Task.sleep(for: .seconds(1.6))
        toggle("quiet")
        try? await Task.sleep(for: .seconds(0.9))
        toggle("moving")
        try? await Task.sleep(for: .seconds(1.3))
        finish()
    }
}

private struct HelpsChipStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        configuration.label
            .background(shape.fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x5A7CF0), Theme.brand],
                                                                     startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Color.white)))
            .overlay(shape.stroke(on ? .white.opacity(0.25) : Theme.line, lineWidth: 2))
            .offset(y: pressed ? 4 : 0)
            .background(shape.fill(on ? Theme.brandEdge : Theme.line).offset(y: 4))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
