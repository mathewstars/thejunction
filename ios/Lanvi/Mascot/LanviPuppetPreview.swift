import SwiftUI

/// A screen to judge the puppet: the fox large on the painted night and a button for
/// every idle moment, reaction and held mood. Launch with `-screen puppet`.
///
/// - `-plain YES`: the fox alone on flat pure green (for measuring: track the pupils).
/// - `-puppetDemo idle|reactions|moments|touch|touch4|say|follow`: plays a fixed script with a caption and no
///   buttons, for recordings. `reactions` plays each reaction once, `moments` each idle
///   moment once, `idle` nothing (the idle picks its own moments). `-puppetDemo YES`
///   is the old script: idle, then happy, then surprised.
/// - `-snow YES`: the painted world's falling snow (off by default, so recordings
///   measure the fox alone).
/// - Proof stills: `-puppetFreeze happy:0.32` holds a reaction at that second,
///   `-puppetFreeze moment:glance:0.6` an idle moment, `-puppetFreeze blink:0.08` a
///   blink, `-puppetFreeze look:0.95:-0.1` a head turn toward that point, `rest:0` rest.
struct LanviPuppetPreview: View {
    @State private var trigger = 0
    @State private var mood: LanviMood = .happy
    @State private var momentTrigger = 0
    @State private var moment: LanviMoment = .glance
    @State private var heldMood: LanviMood?
    @State private var talking = false
    @State private var bounce = 0
    @State private var look: UnitPoint?
    @State private var lookStep = 0
    @State private var caption = ""
    @State private var sayText = ""
    @State private var sayTrigger = 0
    @State private var sayLine = 0
    @State private var touchZone: LanviTouchZone = .head
    @State private var touchSide: Double = 1
    @State private var touchHold: Double?
    @State private var touchTrigger = 0
    @State private var followPath = 0
    @State private var followTrigger = 0

    private let freeze: LanviDebugFreeze? = {
        guard let raw = UserDefaults.standard.string(forKey: "puppetFreeze") else { return nil }
        let bits = raw.split(separator: ":").map(String.init)
        let name = bits.first ?? ""
        let num = { (i: Int) -> Double in bits.count > i ? Double(bits[i]) ?? 0 : 0 }
        switch name {
        case "blink": return LanviDebugFreeze(reaction: nil, at: 0, blink: num(1))
        case "moment": return LanviDebugFreeze(reaction: nil, at: num(2), blink: nil, moment: LanviMoment(rawValue: bits.count > 1 ? bits[1] : ""))
        case "look": return LanviDebugFreeze(reaction: nil, at: 0, blink: nil, look: UnitPoint(x: num(1), y: num(2)))
        default: return LanviDebugFreeze(reaction: LanviMood(rawValue: name), at: num(1), blink: nil)
        }
    }()
    private let demo = UserDefaults.standard.string(forKey: "puppetDemo")
    private let plain = UserDefaults.standard.bool(forKey: "plain")
    private let snow = UserDefaults.standard.bool(forKey: "snow")
    /// `-puppetHops NO`: on the snow like Home (no hops; reactions stay in place).
    private let hopsOn = UserDefaults.standard.object(forKey: "puppetHops") == nil || UserDefaults.standard.bool(forKey: "puppetHops")
    /// `-puppetBounds YES` (or the Bounds button): outline the eyes and their patches.
    @State private var bounds = UserDefaults.standard.bool(forKey: "puppetBounds")

    private let reactions: [(String, LanviMood)] = [
        ("Hello", .greeting), ("Happy", .happy), ("Proud", .proud), ("Okay", .okay),
        ("Surprised", .surprised), ("Curious", .curious), ("Yawn", .sleepy), ("Listen", .listening),
        ("Think", .thinking),
    ]
    private let moments: [(String, LanviMoment)] = [
        ("Glance", .glance), ("Look up", .glanceUp), ("Tilt", .tilt), ("Ears", .ears),
        ("Tail curl", .tailCurl), ("Sniff", .sniff), ("Slow blink", .slowBlink), ("Invite", .invite),
        ("Evening", .yawn),
    ]
    private let touches: [(String, LanviTouchZone)] = [
        ("Head", .head), ("Nose", .nose), ("Ear", .ear), ("Cheek", .cheek), ("Belly", .belly),
        ("Tail", .tail), ("Paw", .paw), ("Near him", .near),
    ]
    private let held: [(String, LanviMood)] = [
        ("Listening", .listening), ("Thinking", .thinking), ("Sleepy", .sleepy),
    ]

    var body: some View {
        Group {
            if plain { plainBody } else { worldBody }
        }
        .task { await runDemo() }
    }

    private func fox(size: CGFloat) -> some View {
        LanviView(pose: .curious, size: size, bounceTrigger: bounce)
            .lanviReaction(mood, trigger: trigger)
            .lanviMoment(moment, trigger: momentTrigger)
            .lanviMood(heldMood)
            .lanviHops(hopsOn)
            .lanviTalking(talking)
            .lanviSays(sayText, trigger: sayTrigger)
            .lanviLookAt(look)
            .lanviTouch(touchZone, side: touchSide, hold: touchHold, trigger: touchTrigger)
            .environment(\.lanviFollowRequest, followTrigger == 0 ? nil : LanviFollowRequest(path: followPath, token: followTrigger))
            .environment(\.lanviDebugFreeze, freeze)
            .environment(\.lanviDebugBounds, bounds)
    }

    /// `-plain YES`: the fox alone on flat pure green, for measuring the motion frame by
    /// frame (track the dark pupils on green). The caption sits far above the fox.
    private var plainBody: some View {
        ZStack(alignment: .top) {
            Color(red: 0, green: 1, blue: 0).ignoresSafeArea()
            fox(size: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(Theme.rounded(15, .heavy))
                .foregroundStyle(.black.opacity(0.6))
                .padding(.top, 6)
        }
    }

    private var worldBody: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let recording = demo != nil
            let size = min(h * (recording ? 0.46 : 0.4), w * 0.86)
            let feet = recording ? h * 0.80 : h * 0.55
            ZStack(alignment: .top) {
                PaintedWorld(scene: .night, snow: snow)

                VStack(spacing: 2) {
                    Text("Lanvi")
                        .font(Theme.rounded(28, .heavy))
                        .foregroundStyle(.white)
                    Text(caption.isEmpty ? (recording ? " " : "Tap him, or try a moment") : caption)
                        .font(Theme.rounded(17, .heavy))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 8)

                fox(size: size)
                    .position(x: w / 2, y: feet - size / 2)

                if !recording { controls.padding(.top, feet + 22) }
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section("Touch (or touch him yourself: by place, hold to pet, drag)")
                grid(touches.map { t in (t.0, false, { touchIt(t.1, t.0) }) }
                     + [("Pet (hold)", false, { touchIt(.head, "Petting", hold: 2) }),
                        ("Quick taps", false, { quickTaps() })])
                section("Reactions")
                grid(reactions.map { r in (r.0, false, { play(r.1, r.0) }) })
                section("Idle moments")
                grid(moments.map { m in (m.0, false, { playMoment(m.1, m.0) }) })
                section("Held")
                grid(held.map { m in (m.0, heldMood == m.1, { toggle(m.1, m.0) }) }
                     + [("Talking", talking, { talking.toggle(); caption = talking ? "Talking" : "" }),
                        ("Say", false, { say(Self.lines[sayLine % Self.lines.count]); sayLine += 1 }),
                        ("Look", look != nil, { nextLook() }),
                        ("Hop", false, { bounce += 1; caption = "Hop" }),
                        ("Follow", false, { followIt(followTrigger % 2) }),
                        ("Bounds", bounds, { bounds.toggle() })])
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.rounded(12, .heavy))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.7))
    }

    private func grid(_ items: [(String, Bool, () -> Void)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                Button(items[i].0, action: items[i].2)
                    .buttonStyle(PillStyle(on: items[i].1))
            }
        }
    }

    private func play(_ m: LanviMood, _ label: String) {
        mood = m
        trigger += 1
        caption = label
    }

    private func playMoment(_ m: LanviMoment, _ label: String) {
        moment = m
        momentTrigger += 1
        caption = label
    }

    /// A scripted finger for the eyes to follow: 0 a slow circle (6 s), 1 a figure of eight (8 s).
    private func followIt(_ path: Int) {
        followPath = path
        followTrigger += 1
        caption = path == 0 ? "Follow: a slow circle" : "Follow: a figure of eight"
    }

    /// Lines for the Say button and the `say` demo (in Lanvi's voice).
    private static let lines = [
        "Hi! I kept a spot warm for you.",
        "That sounds like a long day. Want to break the ice with me?",
        "Okay. I'm here, whenever you are.",
    ]

    /// Lanvi says a line; the caption shows its words at the pace he says them (what a
    /// chat bubble would do with `LanviView.sayingTime`).
    private func say(_ line: String) {
        sayText = line
        sayTrigger += 1
        let token = sayTrigger
        let words = line.split(separator: " ")
        let total = LanviView.sayingTime(line)
        Task { @MainActor in
            let start = Date()
            while token == sayTrigger {
                let p = min(Date().timeIntervalSince(start) / max(total, 0.1), 1)
                caption = words.prefix(max(1, Int((p * Double(words.count)).rounded(.up)))).joined(separator: " ")
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// Touch a place (the side alternates, so ears, cheeks and paws take turns).
    private func touchIt(_ zone: LanviTouchZone, _ label: String, hold: Double? = nil) {
        touchZone = zone
        touchSide = -touchSide
        touchHold = hold
        touchTrigger += 1
        caption = label
    }

    /// Four quick taps: they build up (a look, a giggle, a wriggle, a sigh) instead of repeating.
    private func quickTaps() {
        Task { @MainActor in
            for (i, z) in [LanviTouchZone.cheek, .belly, .belly, .head].enumerated() {
                touchIt(z, ["Quick tap: giggle", "Quick taps: giggle", "Quick taps: wriggle", "Quick taps: sigh"][i])
                try? await Task.sleep(for: .seconds(0.45))
            }
        }
    }

    private func toggle(_ m: LanviMood, _ label: String) {
        heldMood = heldMood == m ? nil : m
        caption = heldMood == nil ? "" : label
    }

    private func nextLook() {
        let spots: [UnitPoint?] = [UnitPoint(x: 1.1, y: -0.1), UnitPoint(x: -0.2, y: 0.1),
                                  UnitPoint(x: 0.5, y: -0.6), UnitPoint(x: 0.5, y: 1.4), nil]
        look = spots[lookStep % spots.count]
        lookStep += 1
        caption = look == nil ? "" : "Look"
    }

    // MARK: Scripts for recordings

    private func runDemo() async {
        guard let demo else { return }
        let start = Date()
        func at(_ s: Double) async {
            let wait = s - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        switch demo {
        case "reactions":
            var time = 1.2
            for (label, m) in reactions where m != .thinking {
                await at(time)
                play(m, label)
                time += m.reactionLength + 0.9
            }
            for (label, m) in [("Listening (typing)", LanviMood.listening), ("Thinking", .thinking)] {
                await at(time)
                heldMood = m
                caption = label
                time += 4.2
                await at(time - 0.6)
                heldMood = nil
            }
            await at(time)
            talking = true
            caption = "Talking"
            await at(time + 3)
            talking = false
            await at(time + 3.8)
            bounce += 1
            caption = "Hop"
        case "moments":
            var time = 3.2
            for (label, m) in moments {
                await at(time)
                playMoment(m, label)
                time += m.duration + 0.8
            }
            await at(time)
            caption = ""
        case "idle":
            caption = "Idle"
        case "follow":
            await at(1.0)
            followIt(0)
            await at(8.0)
            followIt(1)
            await at(17.0)
            caption = ""
        case "say":
            // Three lines; the mouth follows the words as they appear.
            var t = 1.0
            for line in Self.lines {
                await at(t)
                say(line)
                t += LanviView.sayingTime(line) + 1.6
            }
            await at(t)
            caption = ""
        case "touch":
            // Nine different touch reactions in about 20 s.
            let script: [(Double, LanviTouchZone, String, Double?)] = [
                (1.0, .head, "Pet his head", nil), (3.0, .nose, "Boop the nose", nil),
                (4.9, .ear, "Touch an ear", nil), (6.6, .cheek, "Touch a cheek", nil),
                (8.3, .belly, "Tickle the belly", nil), (10.2, .tail, "Touch the tail", nil),
                (12.6, .paw, "Touch a paw", nil), (14.6, .near, "Tap near him", nil),
                (16.0, .head, "Hold to pet", 1.8),
            ]
            for (at_, zone, label, hold) in script {
                await at(at_)
                touchIt(zone, label, hold: hold)
            }
            await at(17.8)
            caption = "Let go: a slow blink"
        case "touch4":
            // The four reactions that are not a hop: a nod, a shy look away, a curious
            // tilt, a happy wiggle (each place takes its turns, so the order matters).
            let script: [(Double, LanviTouchZone, String)] = [
                (1.0, .head, "Pet his head"), (4.2, .head, "Pat his head again: a nod"),
                (6.4, .cheek, "Touch a cheek: a giggle"), (8.6, .cheek, "Again: shy, he looks away"),
                (11.2, .near, "Tap beside him: a curious tilt"), (13.4, .head, "Pet his head"),
                (15.0, .head, "Pet again: a happy wiggle"),
            ]
            for (at_, zone, label) in script {
                await at(at_)
                touchIt(zone, label)
            }
            await at(17.5)
            caption = ""
        default:
            let wait = UserDefaults.standard.double(forKey: "puppetDemoDelay")
            await at(wait > 0 ? wait : 7)
            play(.happy, "Happy")
            await at((wait > 0 ? wait : 7) + 2.6)
            play(.surprised, "Surprised")
        }
    }
}

/// A small chunky pill for the preview's many buttons.
private struct PillStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.rounded(14, .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(on ? .white : Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Theme.brand : Theme.tint))
            .offset(y: pressed ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? Theme.brandEdge : Color(hex: 0xC5D3F5)).offset(y: 3))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}
