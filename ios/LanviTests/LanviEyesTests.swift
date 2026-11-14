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
}
