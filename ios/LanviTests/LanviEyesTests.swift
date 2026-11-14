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
            let lid = m.frame().lid
            XCTAssertEqual(lid.weight, 1, accuracy: 1e-9, "\(what): eye picture swapped at \(t) s", file: file, line: line)
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
}

