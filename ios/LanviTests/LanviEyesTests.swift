import XCTest
@testable import Lanvi

/// Lanvi's eyes stay on their white patches, wherever he looks, at any size.
/// Positions are in head pixels from the head's centre (`Rig.eyeOnPatch`, which the
/// puppet draws with), so they are the same share of the head at every fox size.
final class LanviEyesTests: XCTestCase {

    private let clock = 5_000.0

    private func motion(_ steps: [LookStep], at t: Double? = nil) -> LanviMotion {
        var m = LanviMotion(t: t ?? clock, seed: 0, held: .calm, heldFrom: .calm, heldSince: -100,
                            reaction: nil, reactionAt: -100, hopAt: -100, reduceMotion: false)
        m.appearAt = .infinity
        m.lookSteps = steps
        return m
    }

    /// Look targets in canvas units: on the face, around the fox, and far off screen.
    private var targets: [CGPoint?] {
        var out: [CGPoint?] = [nil]
        for x in stride(from: -4000.0, through: 6000.0, by: 500) {
            for y in stride(from: -4000.0, through: 6000.0, by: 500) {
                out.append(CGPoint(x: x, y: y))
            }
        }
        return out
    }

    /// An eye picture's box (head pixels) around its placed centre.
    private func eyeBox(_ shape: String, left: Bool, at c: CGPoint) -> CGRect {
        let name = shape + (left ? "-l" : "-r")
        let px = LanviArt.px(name)
        let centre = LanviArt.eyeCenter[name] ?? CGPoint(x: px.width / 2, y: px.height / 2)
        let s = Rig.eyeScale
        return CGRect(x: c.x - centre.x * s, y: c.y - centre.y * s, width: px.width * s, height: px.height * s)
    }

    /// The patch's box (head pixels) around its placed centre, with a strip of the white
    /// cheek under it (the art cuts the patch where it runs into the cheek; the white goes
    /// on about 125 head pixels further down, 45 are allowed).
    private func patchBox(left: Bool, at c: CGPoint) -> CGRect {
        let r = LanviArt.layer[left ? "face-patch-l" : "face-patch-r"]!
        let px = LanviArt.px("head")
        let w = r.width * px.width, h = r.height * px.height
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h + 45)
    }

    private func assertOnPatches(_ f: RigFrame, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let head = LanviArt.px("head").width
        for left in [true, false] {
            for (shape, drop) in [("eyes-open", EyeShape.open.dropY), ("eyes-wide", EyeShape.wide.dropY)] {
                let p = Rig.eyeOnPatch(left: left, dropY: drop, pose: f.pose)
                let eye = eyeBox(shape, left: left, at: p.eye)
                let patch = patchBox(left: left, at: p.patch)
                XCTAssertTrue(patch.contains(eye), "\(shape) \(left ? "left" : "right") eye off its patch for \(what): eye \(eye), patch \(patch)",
                              file: file, line: line)
            }
            // the face (patch) moves at most 0.06 of the head's width sideways, 0.04 up or down
            let rest = Rig.marking(left ? "face-patch-l" : "face-patch-r")
            let p = Rig.eyeOnPatch(left: left, dropY: 0, pose: f.pose).patch
            XCTAssertLessThanOrEqual(abs(p.x - rest.x) / head, 0.061, "face slid too far sideways for \(what)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(p.y - rest.y) / head, 0.041, "face slid too far up or down for \(what)", file: file, line: line)
        }
    }

    func testEyesStayOnTheirPatchesForAnyLook() {
        for target in targets {
            let f = motion([LookStep(at: -100, target: target)]).frame()
            assertOnPatches(f, "a look at \(String(describing: target))")
        }
    }

    func testEyesStayOnTheirPatchesWithTouchesAndMomentsOnTop() {
        let far = [CGPoint(x: -5000, y: 6000), CGPoint(x: 6000, y: -5000)]
        for target in far {
            for act in LanviTouchAct.allCases {
                for dt in stride(from: 0.0, through: act.duration, by: 0.2) {
                    var m = motion([LookStep(at: -100, target: target)], at: clock + dt)
                    m.touch = act
                    m.touchAt = clock
                    m.touchSide = target.x < 0 ? -1 : 1
                    assertOnPatches(m.frame(), "\(act) at \(dt) s looking at \(target)")
                }
            }
            for moment in LanviMoment.allCases {
                for dt in stride(from: 0.0, through: moment.duration, by: 0.2) {
                    var m = motion([LookStep(at: -100, target: target)], at: clock + dt)
                    m.moment = moment
                    m.momentAt = clock
                    assertOnPatches(m.frame(), "\(moment) at \(dt) s looking at \(target)")
                }
            }
        }
    }

    func testTheSameShareOfTheHeadAtEverySize() {
        // the puppet draws a head pixel at `Rig.head.scale * size / Rig.canvas.height`
        // points, so the eye's place as a share of the head's width cannot depend on size
        let f = motion([LookStep(at: -100, target: CGPoint(x: 3000, y: -2000))]).frame()
        let eye = Rig.eyeOnPatch(left: true, dropY: 0, pose: f.pose).eye
        var shares: [CGFloat] = []
        for size in [74.0, 336.0, 420.0] as [CGFloat] {
            let k = size / Rig.canvas.height
            let headWidth = Rig.head.size.width * k
            shares.append(eye.x * Rig.head.scale * k / headWidth)
        }
        XCTAssertEqual(shares[0], shares[1], accuracy: 1e-9)
        XCTAssertEqual(shares[1], shares[2], accuracy: 1e-9)
    }

    func testBackExactlyToRestAfterAFingerLifts() {
        // a finger dragged across for 1.5 s (a new target every 1/60 s), then lifted
        var steps = [LookStep(at: -100, target: nil)]
        for i in 0...90 {
            let u = Double(i) / 90
            steps.append(LookStep(at: clock + Double(i) / 60, target: CGPoint(x: -3000 + 8000 * u, y: 600 - 2000 * sin(u * .pi))))
        }
        steps.append(LookStep(at: clock + 1.6, target: nil))
        let after = motion(steps, at: clock + 4.5).frame().pose
        let rest = motion([LookStep(at: -100, target: nil)], at: clock + 4.5).frame().pose
        XCTAssertEqual(after.dirX, rest.dirX, accuracy: 1e-4)
        XCTAssertEqual(after.dirY, rest.dirY, accuracy: 1e-4)
        XCTAssertEqual(after.eyeX, rest.eyeX, accuracy: 1e-4)
        XCTAssertEqual(after.eyeY, rest.eyeY, accuracy: 1e-4)
        XCTAssertEqual(after.headTilt, rest.headTilt, accuracy: 1e-3)
    }

    // MARK: Eyes while a finger is dragged (the captain's "eyes fade in and out and close
    // and open while tracking")

    /// A finger path over and around the fox, a new place every 1/60 s.
    private func dragSteps(from start: Double, seconds: Double) -> [LookStep] {
        var steps = [LookStep(at: -100, target: nil)]
        for i in 0...Int(seconds * 60) {
            let t = Double(i) / 60
            let a = 2 * Double.pi * t / 3
            steps.append(LookStep(at: start + t, target: CGPoint(x: 1085 + 1400 * sin(a), y: 700 + 900 * sin(2 * a))))
        }
        return steps
    }

    /// Checks frames from `from` to `to` s: the eye is never see-through, the lid only
    /// comes down for single quick blinks, 2.5 s or more apart; no idle moment starts.
    private func assertOnlyQuickBlinks(_ make: (Double) -> LanviMotion, from: Double, to: Double, _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        var closings: [Double] = []
        var downSince: Double?
        var t = from
        while t <= to {
            let m = make(t)
            let lid = m.frame().eyeDraw
            XCTAssertEqual(lid.kind, .lidded, "\(what): eye picture swapped at \(t) s", file: file, line: line)
            if lid.down > 0.01 {
                if downSince == nil { downSince = t; closings.append(t) }
                XCTAssertLessThan(t - downSince!, 0.2, "\(what): lid down longer than a quick blink at \(t) s", file: file, line: line)
            } else {
                downSince = nil
            }
            XCTAssertNil(m.currentMoment(m.t), "\(what): an idle moment during the drag at \(t) s", file: file, line: line)
            t += 1.0 / 60
        }
        for (a, b) in zip(closings, closings.dropFirst()) {
            XCTAssertGreaterThan(b - a, 2.5, "\(what): two blinks close together at \(a) and \(b) s", file: file, line: line)
        }
    }

    func testADraggedFingerGetsOnlySingleQuickBlinks() {
        for seed in [0, 123, 380, 555, 909] {
            let steps = dragSteps(from: clock, seconds: 8)
            assertOnlyQuickBlinks({ t in
                var m = self.motion(Array(steps.prefix { $0.at <= self.clock + t }), at: self.clock + t)
                m.seed = seed
                m.appearAt = self.clock - 100          // idle moments on: none may start
                return m
            }, from: 0.4, to: 8, "seed \(seed)")
        }
    }

    func testDraggingAfterPettingOpensTheEyesAtOnce() {
        // the finger rests 1.1 s (petting from 0.5 s, the happy squint), then drags 6 s
        let steps = dragSteps(from: clock + 1.6, seconds: 6)
        let make: (Double) -> LanviMotion = { t in
            var m = self.motion(Array(steps.prefix { $0.at <= self.clock + t }), at: self.clock + t)
            m.seed = 909
            m.appearAt = self.clock - 100
            m.petting = t >= 0.5 && t < 1.6
            m.pettingFrom = t >= 0.5 ? self.clock + 0.5 : -100
            m.pettingSince = t < 0.5 ? -100 : self.clock + (t < 1.6 ? 0.5 : 1.6)
            m.pettingEndedByDrag = t >= 1.6
            return m
        }
        assertOnlyQuickBlinks(make, from: 2.0, to: 7.6, "after petting")
    }

    // MARK: The head turn

    func testTheHeadOutlineMovesAtMostThreePercentOfItsWidth() {
        for dirX in stride(from: -1.0, through: 1.0, by: 0.05) {
            let e = Rig.headEdges(dirX: dirX)
            XCTAssertLessThanOrEqual(abs(e.left), 0.031, "left edge at dirX \(dirX)")
            XCTAssertLessThanOrEqual(abs(e.right), 0.031, "right edge at dirX \(dirX)")
        }
        // and the turn is real: at a full turn the far edge tucks in by more than 2 %
        XCTAssertLessThan(Rig.headEdges(dirX: 1).right, -0.02)
        XCTAssertGreaterThan(Rig.headEdges(dirX: -1).left, 0.02)
    }

    func testADragNeverWobblesTheHead() {
        // a slow circle fed by touch events at uneven times (a real finger): the head's
        // turn speed changes smoothly, at most two small wobbles in 5 s
        var r: UInt64 = 12345
        func rnd() -> Double { r = r &* 6364136223846793005 &+ 1442695040888963407; return Double(r >> 11) / Double(1 << 53) }
        var steps = [LookStep(at: -100, target: nil)]
        var t = 0.0
        while t < 6 {
            let a = 2 * Double.pi * t / 6
            steps.append(LookStep(at: clock + t, target: CGPoint(x: 1085 + 900 * cos(a), y: 600 + 650 * sin(a))))
            t += (1.0 / 60) * (0.6 + 0.8 * rnd()) * (rnd() < 0.05 ? 2 : 1)
        }
        var xs: [Double] = []
        for i in 0..<(60 * 6) { xs.append(motion(steps, at: clock + Double(i) / 60).frame().pose.dirX) }
        var wobbles = 0
        for i in 60..<(xs.count - 2) {
            let a0 = (xs[i + 1] - xs[i]) - (xs[i] - xs[i - 1]), a1 = (xs[i + 2] - xs[i + 1]) - (xs[i + 1] - xs[i])
            if a0 * a1 < 0, abs(a0 - a1) > 0.0004 { wobbles += 1 }
        }
        XCTAssertLessThanOrEqual(wobbles, 2)
    }

    // MARK: Saying a line (`.lanviSays`)

    func testSayingALineFollowsItsWords() {
        for line in ["Hi! I kept a spot warm for you.", "That sounds like a long day. Want to break the ice with me?",
                     "Okay. I'm here, whenever you are.", "Mmm, maybe."] {
            let beats = LanviSpeech.beats(line)
            let letters = Double(line.filter { $0.isLetter }.count)
            let length = LanviSpeech.length(line)
            XCTAssertGreaterThan(letters / length, 8, "too slow: \(line)")
            XCTAssertLessThan(letters / length, 15, "too fast: \(line)")
            // one beat after another, no gaps, never ending on a pause
            for (a, b) in zip(beats, beats.dropFirst()) { XCTAssertEqual(a.end, b.at, accuracy: 1e-9, line) }
            XCTAssertNotEqual(beats.last?.shape, .smile, line)
            // a pause of at least 0.2 s after each comma or full stop inside the line
            let stops = line.dropLast().filter { ",.!?".contains($0) }.count
            XCTAssertEqual(beats.filter { $0.shape == .smile && $0.end - $0.at >= 0.2 }.count, stops, line)
        }
        // the lips meet on m, b and p
        XCTAssertEqual(LanviSpeech.beats("Mmm, maybe.").first?.shape, .flat)
    }

    func testSayingALineEndsBackAtRest() {
        let line = "That sounds like a long day. Want to break the ice with me?"
        let end = LanviSpeech.length(line)
        var said = motion([LookStep(at: -100, target: nil)], at: clock + end + 1)
        said.speech = LanviSpeech.beats(line)
        said.speechAt = clock
        let rest = motion([LookStep(at: -100, target: nil)], at: clock + end + 1)
        XCTAssertEqual(said.frame().pose.headY, rest.frame().pose.headY, accuracy: 1e-9)
        XCTAssertEqual(said.frame().pose.dirX, rest.frame().pose.dirX, accuracy: 1e-9)
        XCTAssertEqual(said.frame().face.mouth, rest.frame().face.mouth)
        // and while saying it, the mouth moves: more than 10 changes of shape
        var shapes: [MouthShape] = []
        for i in 0..<Int(end * 60) {
            var m = said
            m.t = clock + Double(i) / 60
            let mouth = m.frame().face.mouth
            if shapes.last != mouth { shapes.append(mouth) }
        }
        XCTAssertGreaterThan(shapes.count, 10)
    }

    // MARK: The captain's spam test: rapid taps all over him

    /// Plays taps through `LanviTapper` (the one owner of the touch reactions) and the eyes
    /// following the finger like the puppet does, frame by frame at 60 fps.
    private struct Spam {
        var tapper = LanviTapper()
        var steps = [LookStep(at: -100, target: nil)]
        var backAt = -100.0

        /// The taps of a burst: 25 in 4 s on the head, cheeks, nose, ears and belly.
        static func burst(from t0: Double) -> [(Double, CGPoint)] {
            let zones: [(LanviTouchZone, Double)] = [(.head, -1), (.cheek, 1), (.belly, -1), (.head, 1), (.cheek, -1),
                                                     (.nose, 1), (.belly, 1), (.ear, -1), (.head, -1), (.cheek, 1)]
            return (0..<25).map { i in
                let (z, side) = zones[i % zones.count]
                return (t0 + Double(i) * 0.16, LanviTouchZone.point(z, side: side))
            }
        }

        mutating func tap(_ t: Double, _ p: CGPoint) {
            let act = tapper.tap(at: p, time: t)
            if act == nil || !LanviTapper.aims.contains(act!) {
                steps.append(LookStep(at: t, target: p))
                backAt = t + max(1.1, (act?.duration ?? 1.2) - 0.5)
            }
        }

        func motion(at t: Double, seed: Int) -> LanviMotion {
            var m = LanviMotion(t: t, seed: seed, held: .calm, heldFrom: .calm, heldSince: -100,
                                reaction: nil, reactionAt: -100, hopAt: -100, reduceMotion: false)
            m.appearAt = .infinity
            var s = steps
            if t >= backAt { s.append(LookStep(at: backAt, target: nil)) }
            m.lookSteps = s
            m.touchTimeline = tapper.timeline
            m.touch = tapper.touch; m.touchAt = tapper.touchAt; m.touchSide = tapper.touchSide
            m.prevTouch = tapper.prevTouch; m.prevTouchAt = tapper.prevTouchAt
            m.hops = false
            return m
        }
    }

    func testRapidTapsNeverLeaveTheEyesBroken() {
        for seed in [0, 123, 909] {
            var spam = Spam()
            let first = Spam.burst(from: clock), second = Spam.burst(from: clock + 13)
            var taps = first + second
            var frames: [(Double, EyeDraw)] = []
            for i in 0..<(60 * 22) {
                let t = clock + Double(i) / 60
                while let next = taps.first, next.0 <= t { spam.tap(next.0, next.1); taps.removeFirst() }
                frames.append((t - clock, spam.motion(at: t, seed: seed).frame().eyeDraw))
            }
            // never two eye sets, ever (by construction one kind per frame); wide and happy
            // only while a reaction plays; after each burst settles (0.6 s after its last
            // tap): the normal open eyes, lids open except single blinks of 0.12 to 0.3 s
            for (start, end) in [(4.0 + 0.6, 13.0), (17.0 + 0.6, 22.0)] {
                var closing: Double?
                for (t, e) in frames where t >= start && t < end {
                    XCTAssertEqual(e.kind, .lidded, "seed \(seed): not the normal eye set at \(t) s")
                    if e.down > 0.001 {
                        if closing == nil { closing = t }
                    } else if let c = closing {
                        let length = t - c
                        XCTAssertGreaterThanOrEqual(length, 0.12, "seed \(seed): a blink of \(length) s at \(c) s")
                        XCTAssertLessThanOrEqual(length, 0.3, "seed \(seed): the lid stayed down \(length) s from \(c) s")
                        closing = nil
                    } else {
                        XCTAssertEqual(e.eyeOpacity, 1, accuracy: 1e-9, "seed \(seed): eye faded at \(t) s")
                        XCTAssertEqual(e.lashOpacity, 0, accuracy: 1e-9, "seed \(seed): lashes on an open eye at \(t) s")
                    }
                }
                if let c = closing { XCTAssertGreaterThan(c, end - 0.3, "seed \(seed): the lid never opened again after \(c) s") }
            }
        }
    }
}

