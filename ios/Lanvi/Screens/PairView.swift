import SwiftUI

/// First run: the code from the clinic. The painted scene, Lanvi big and
/// listening, one line in the bubble, one large code field made for
/// `XXXX-XXXX-XXXX` (letters and digits, dashes added by themselves, paste
/// works), and one chunky "Connect" button in the same place as the other
/// first-run buttons. Never shows raw error text.
struct PairView: View {
    var onDone: () -> Void

    @Environment(AppStore.self) private var store
    @State private var code = ""
    @State private var say = "Your clinic gave you a code. Type it here and I'll remember you."
    @State private var busy = false
    @State private var paired = false
    @State private var pose: LanviPose = .curious
    @State private var reactTick = 0
    @State private var look: UnitPoint?
    @FocusState private var focused: Bool

    private var complete: Bool { code.count == 14 }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // The keyboard shrinks the space; Lanvi shrinks with it so the field and button stay visible.
            let fox = min(geo.size.width * 0.62, max(h * 0.30, 110))
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                VStack(spacing: 0) {
                    HomeSpeechBubble(text: say, pointAt: 0.5)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    LanviView(pose: pose, size: fox)
                        .lanviMood(busy ? .listening : nil)
                        .lanviReaction(.happy, trigger: reactTick)
                        .lanviLookAt(look)
                        .frame(height: fox)
                        .padding(.top, 4)
                        .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    codeField
                        .padding(.horizontal, 24)

                    Button(busy ? "Connecting…" : (paired ? "Connected" : "Connect")) { connect() }
                        .buttonStyle(ChunkyButtonStyle())
                        .disabled(!complete || busy || paired)
                        .opacity(complete || busy || paired ? 1 : 0.55)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .animation(LanviTiming.swap, value: complete)
                }
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                focused = true
            }
        }
        .task { await debugTry() }
    }

    private var codeField: some View {
        TextField("", text: $code, prompt: Text("XXXX-XXXX-XXXX").foregroundStyle(Theme.inkSecondary.opacity(0.45)))
            .font(Theme.rounded(28, .heavy))
            .tracking(2)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.ink)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .textContentType(.oneTimeCode)
            .submitLabel(.go)
            .focused($focused)
            .onSubmit { if complete { connect() } }
            .onChange(of: code) { _, new in
                let formatted = Self.format(new)
                if formatted != new { code = formatted }
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? Theme.brand.opacity(0.6) : LanviBubbleBackground.outline, lineWidth: 2))
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LanviBubbleBackground.edge).offset(y: 3))
            .accessibilityLabel("Pairing code from your clinic")
    }

    /// Uppercase letters and digits only, a dash after every four, twelve at most.
    static func format(_ raw: String) -> String {
        let clean = raw.uppercased().filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        var out = ""
        for (i, ch) in clean.prefix(12).enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(ch)
        }
        return out
    }

    private func connect() {
        guard complete, !busy else { return }
        busy = true
        look = UnitPoint(x: 0.5, y: -0.3)        // hopeful: eyes up
        Task {
            let result = await store.pair(code: code)
            busy = false
            look = nil
            switch result {
            case .ok:
                paired = true
                focused = false
                pose = .cheer
                reactTick += 1
                say = "There you are. I'll remember you."
                try? await Task.sleep(for: .seconds(1.6))
                onDone()
            case .badCode:
                say = "That code didn't work. Codes work once. Ask your clinic for a fresh one."
            case .offline:
                say = "I can't reach the clinic right now. Check the internet, then try again."
            case .busy:
                say = "Lots of tries just now. Wait a minute, then try again."
            case .failed:
                say = "Something went wrong on my side. Please try again in a moment."
            }
        }
    }

    /// Debug only, `-pairTry CODE[,CODE]`: type each code and press Connect, a few
    /// seconds apart (to test the screen against a local engine without a keyboard).
    private func debugTry() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-pairTry"), i + 1 < args.count else { return }
        for c in args[i + 1].split(separator: ",") {
            try? await Task.sleep(for: .seconds(2.5))
            code = Self.format(String(c))
            try? await Task.sleep(for: .seconds(1.2))
            connect()
            while busy { try? await Task.sleep(for: .milliseconds(100)) }
            if paired { return }
            try? await Task.sleep(for: .seconds(2.5))
        }
        #endif
    }
}
