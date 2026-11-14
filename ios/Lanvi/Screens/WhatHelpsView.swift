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
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
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
                    LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                }
                .frame(width: fox * 2, height: fox * 2)
                .position(x: geo.size.width / 2, y: hill - fox / 2 + 14)
                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: chosen.count)

                VStack {
                    Spacer(minLength: 0)
                    HomeSpeechBubble(text: say)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: say)
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
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: chosen.isEmpty)
                }
                .padding(.horizontal, 24)   // the same margins as Welcome, so the button never moves
                .padding(.top, hill + (compact ? 26 : 36))
                .padding(.bottom, 12)
            }
        }
        .task { await runDemo() }
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
                Text(c.title)
                    .font(Theme.rounded(18, .heavy))
                    .foregroundStyle(on ? .white : Theme.ink)
                Spacer(minLength: 0)
                if let order {
                    Text("\(order)")
                        .font(Theme.rounded(14, .black))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 66)
        }
        .buttonStyle(HelpsChipStyle(on: on))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ id: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else if chosen.count < 4 { chosen.append(id) }
            pose = chosen.isEmpty ? .curious : .love
        }
        bounce += 1
    }

    private func finish() {
        guard !sending else { return }
        if chosen.isEmpty { onDone(); return }
        sending = true
        Task {
            let line = await store.setPreferences(chosen)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                say = line ?? "Got it. Thank you for telling me."
                pose = .cheer
            }
            bounce += 1
            try? await Task.sleep(for: .seconds(demo ? 2.6 : 1.9))
            onDone()
        }
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
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
