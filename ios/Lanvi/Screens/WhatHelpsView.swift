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
            let compact = geo.size.height < 700
            let hill = geo.size.height * (compact ? 0.54 : 0.60)
            let fox: CGFloat = compact ? 150 : 190
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                ZStack {
                    LanviView(pose: .curious, size: fox)
                        .lanviReaction(reaction, trigger: reactTick)
                        .lanviMood(proud ? .happy : nil)
                        .lanviHops(false)
                }
                .frame(width: fox * 2, height: fox * 2)
                .position(x: geo.size.width / 2, y: hill - fox / 2 + 14)

                VStack {
                    Spacer(minLength: 0)
                    HomeSpeechBubble(text: say)
                }
                .frame(width: geo.size.width - 40, height: max(hill + 14 - fox - 30, 60))
                .padding(.top, 20)

                VStack(spacing: compact ? 12 : 16) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(choices) { c in
                            chip(c)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(chosen.isEmpty ? "Skip for now" : "That's it") { finish() }
                        .buttonStyle(chosen.isEmpty
                                     ? ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand)
                                     : ChunkyButtonStyle())
                        .overlay {
                            if chosen.isEmpty {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Theme.line, lineWidth: 2).allowsHitTesting(false)
                            }
                        }
                        .disabled(sending)
                        .animation(LanviTiming.swap, value: chosen.isEmpty)
                }
                .padding(.horizontal, 24)   // the same margins as Welcome, so the button never moves
                .padding(.top, hill + (compact ? 26 : 36))
                .padding(.bottom, 12)
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
                // One line, always, at one weight: a selected chip keeps exactly its size.
                Text(c.title)
                    .font(Theme.rounded(18, .heavy))
                    .foregroundStyle(on ? .white : Theme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                // The order badge's place is always reserved; it only fades in and pops.
                Text("\(order ?? 1)")
                    .font(Theme.rounded(14, .black))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white))
                    .scaleEffect(on ? 1 : 0.4)
                    .opacity(on ? 1 : 0)
                    .animation(LanviTiming.pop, value: on)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
        }
        .buttonStyle(HelpsChipStyle(on: on))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        // No transaction around the change: only each chip's own colour and badge
        // animate, so no chip can ever travel to a new place.
        if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else if chosen.count < 4 { chosen.append(id) }
        // A happy squint for a choice, a head tilt for the next one, and so on.
        react(reaction == .happy ? .curious : .happy)
    }

    private func finish() {
        guard !sending else { return }
        if chosen.isEmpty { onDone(); return }
        sending = true
        react(.listening)          // a nod: thank you, noted
        // Never wait for the server: Lanvi answers at once, the choice is sent in the
        // background (and again on the next open if it does not get through).
        store.sendPreferences(chosen)
        say = "Got it. Thank you for telling me."
        proud = true
        Task {
            try? await Task.sleep(for: .seconds(demo ? 2.0 : 1.1))
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
