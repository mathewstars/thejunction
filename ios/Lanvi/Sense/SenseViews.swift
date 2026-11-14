import SwiftUI

// The two permission moments and the small pieces around face tracking.
// Same art direction as Home: the scene is the screen, Lanvi large on the snow,
// one line of large type above, the action pinned above the home bar. No cards.

/// A full-screen scene with Lanvi saying one line, and the actions at the bottom.
struct SenseScene<Actions: View>: View {
    var pose: LanviPose
    var line: String
    var night = false
    var bounce = 0
    @ViewBuilder var actions: () -> Actions

    @State private var arrived = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let compact = h < 700
            let buttonY = h - (compact ? 16 : 8) - 30
            let actionsHeight: CGFloat = 60 + 44            // the button and a quiet line under it
            let fox = min(h * (compact ? 0.36 : 0.40), w * 0.80)
            // Lanvi sits in the painting's hollow, as on Home, but always clear of the actions.
            let insets = geo.safeAreaInsets
            let world = WorldFrame(screen: CGSize(width: w, height: h + insets.top + insets.bottom))
            let hollow = world.point(WorldFrame.hollow.x, WorldFrame.hollow.y)
            let actionsTop = buttonY + 30 - actionsHeight
            let feet = min(hollow.y - insets.top + fox * 0.03, actionsTop - 16)
            let foxCenter = CGPoint(x: w / 2, y: feet - fox / 2)
            let top: CGFloat = compact ? 56 : 76

            ZStack(alignment: .top) {
                PaintedWorld(scene: night ? .night : .at(hour: Calendar.current.component(.hour, from: Date())))

                LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    .frame(width: fox * 2, height: fox * 2)
                    .position(foxCenter)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                VStack {
                    Spacer(minLength: 0)
                    Text(line)
                        .font(Theme.rounded(compact ? 23 : 26, .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.8)
                        .shadow(color: Theme.nightTop.opacity(0.45), radius: 10, y: 2)
                        .frame(maxWidth: .infinity)
                        .id(line)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                }
                .padding(.horizontal, 24)
                .frame(height: max(foxCenter.y - fox / 2 - 40 - top, 90))
                .padding(.top, top)
                .opacity(arrived ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: line)

                VStack(spacing: 0) {
                    actions()
                }
                .frame(width: w - 48, height: actionsHeight, alignment: .top)
                .position(x: w / 2, y: buttonY - actionsHeight / 2 + 30)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) { arrived = true }
        }
    }
}

/// A quiet text button under the main one ("Not now").
struct SenseQuietLink: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(17, .heavy))
                .foregroundStyle(Theme.brand)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The face question

/// Asked once, before the first game: "May I watch your face while we play?"
/// Yes and Not now are the same size: both are fine answers.
struct FaceAskView: View {
    var onAnswer: (Bool) -> Void

    @State private var bounce = 0
    @State private var answered = false

    var body: some View {
        SenseScene(pose: .peek,
                   line: "May I watch your face while we play? I keep only a few numbers, never a picture.",
                   night: true, bounce: bounce) {
            HStack(spacing: 16) {
                Button("Not now") { answer(false) }
                    .buttonStyle(ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand))
                Button("Yes, you may") { answer(true) }
                    .buttonStyle(ChunkyButtonStyle())
            }
            .disabled(answered)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            bounce += 1
        }
    }

    private func answer(_ yes: Bool) {
        answered = true
        onAnswer(yes)
    }
}

/// Wraps Sparks and snow or Breathe with Lanvi: asks the face question once, runs
/// the tracker quietly while the game is up, and shows a tiny indicator while it is on.
/// The game itself is never changed or slowed: with no yes, no camera or no
/// TrueDepth, this shows the game exactly as it was.
struct FaceSenseHost<Game: View>: View {
    @ViewBuilder var game: () -> Game

    @State private var face = FaceSense.shared
    @State private var asking = FaceSense.shared.shouldAsk

    var body: some View {
        ZStack {
            if asking {
                FaceAskView { yes in
                    Task {
                        await face.setAllowed(yes)
                        withAnimation(.easeInOut(duration: 0.35)) { asking = false }
                    }
                }
                .transition(.opacity)
            } else {
                game()
                    .overlay(alignment: .top) {
                        if face.isOn {
                            FaceIndicator()
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                    }
                    .onAppear { face.begin() }
                    .transition(.opacity)
            }
        }
        .onDisappear { face.end() }
    }
}

/// The tiny sign that the camera is quietly on: a small eye and a soft dot.
struct FaceIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: 0x3EE6A8)).frame(width: 6, height: 6)
            Image(systemName: "eye.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(.black.opacity(0.18)))
        .padding(.top, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lanvi is watching your face for this game. Only numbers, never a picture.")
    }
}

/// The off switch on the Help screen. Plain on the snow, no box around it.
struct FaceSenseSwitch: View {
    @State private var face = FaceSense.shared

    var body: some View {
        if face.canRun || face.answer != nil || ProcessInfo.processInfo.arguments.contains("-faceAsk") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { face.isAllowed },
                                     set: { on in Task { await face.setAllowed(on) } })) {
                    Text("Lanvi watches my face in games")
                        .font(Theme.rounded(17, .bold))
                        .foregroundStyle(Theme.ink)
                }
                .tint(Theme.brand)
                if face.isAllowed && face.cameraDenied {
                    Text("The camera is off for Lanvi in Settings.")
                        .font(Theme.rounded(14, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }
}
