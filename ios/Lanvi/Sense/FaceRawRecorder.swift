import Foundation
import simd

/// Collects the raw face numbers of one game for `face_raw` (see `docs/face-raw.md`).
/// The phone computes nothing from the face: one row per frame of the 52 ARKit blend
/// shapes plus three head angles, and the server works out every measure.
///
/// Names follow Peter's FaceMetrics recorder and harness: ARKit's own identifiers
/// (`ARFaceAnchor.BlendShapeLocation.rawValue`, e.g. "eyeBlink_L") turned into the
/// readable form the server and the harness use ("eyeBlinkLeft"), as in his
/// `BlendShapeCatalog.friendlyName` (`facemetrics/FaceMetrics/Tracking/BlendShapeCatalog.swift`).
///
/// Rows are kept at a steady `rateHz` on ARKit's own clock: a frame lands in the slot
/// nearest its time, a second frame in the same slot is dropped (ARKit at 60 Hz keeps
/// every second frame), and a gap is filled with untracked rows so time stays true.
struct FaceRawRecorder {
    /// The 52 blend shapes in `docs/face-raw.md` order, then the head angles.
    static let blendShapes = [
        "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff",
        "cheekSquintLeft", "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
        "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight",
        "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight",
        "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel",
        "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
        "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft",
        "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
        "noseSneerLeft", "noseSneerRight", "tongueOut",
    ]
    static let angles = ["headPitch", "headYaw", "headRoll"]
    static let channels = blendShapes + angles
    private static let index: [String: Int] =
        Dictionary(uniqueKeysWithValues: blendShapes.enumerated().map { ($1, $0) })

    /// Server limits: 12,000 samples and 20 moments; the body may be up to 4 MiB.
    /// 9,000 rows (5 minutes at 30 Hz) stays near 3 MB with all 55 channels.
    static let maxSamples = 9_000
    static let maxMoments = 20
    /// A gap longer than this many rows (10 seconds at 30 Hz) is not filled; the
    /// clock moves on instead.
    static let maxGapSlots = 300

    let rateHz: Int
    private(set) var rows: [[Double]] = []
    private(set) var tracked: [Int] = []
    private var firstTime: Double?
    private var moments: [Double] = []   // ARKit clock seconds

    init(rateHz: Int = 30) {
        self.rateHz = min(max(rateHz, 5), 60)
    }

    /// "eyeBlink_L" -> "eyeBlinkLeft" (Peter's `BlendShapeCatalog.friendlyName`).
    static func friendlyName(_ raw: String) -> String {
        if raw.hasSuffix("_L") { return String(raw.dropLast(2)) + "Left" }
        if raw.hasSuffix("_R") { return String(raw.dropLast(2)) + "Right" }
        return raw
    }

    var isFull: Bool { rows.count >= Self.maxSamples }
    var trackedCount: Int { tracked.reduce(0, +) }

    /// One ARKit frame. `shapes` keyed by ARKit's raw identifiers (either form is fine);
    /// angles in degrees, pitch positive when looking down. An untracked frame has no shapes.
    mutating func add(time: Double, tracked isTracked: Bool, shapes: [String: Float],
                      pitch: Double, yaw: Double, roll: Double) {
        guard time.isFinite, !isFull else { return }
        if firstTime == nil { firstTime = time }
        guard let t0 = firstTime, time >= t0 else { return }
        let slot = Int(((time - t0) * Double(rateHz)).rounded())
        guard slot >= rows.count else { return }   // same slot again: keep the first

        // A gap: untracked rows, so the time between rows stays 1 / rateHz.
        let missing = slot - rows.count
        if missing > 0 {
            for _ in 0..<min(missing, Self.maxGapSlots) where !isFull { appendEmpty() }
            if missing > Self.maxGapSlots {
                // A long stop (the app was in the background): shift the clock instead.
                firstTime = time - Double(rows.count) / Double(rateHz)
            }
        }
        guard !isFull else { return }

        guard isTracked, !shapes.isEmpty else { appendEmpty(); return }
        var row = [Double](repeating: 0, count: Self.channels.count)
        for (key, value) in shapes {
            guard let i = Self.index[Self.friendlyName(key)], value.isFinite else { continue }
            row[i] = Self.round3(min(max(Double(value), 0), 1))
        }
        let base = Self.blendShapes.count
        row[base] = Self.angle(pitch)
        row[base + 1] = Self.angle(yaw)
        row[base + 2] = Self.angle(roll)
        rows.append(row)
        tracked.append(1)
    }

    /// A pleasant moment in the game, on the same clock as the frames.
    mutating func mark(at time: Double) {
        guard time.isFinite, moments.count < 200 else { return }
        moments.append(time)
    }

    /// The `face_raw` object, or nil when not one frame was tracked.
    /// `lastSeconds` keeps only the end of the recording (the server refuses frames
    /// lasting much longer than the activity's `duration_s`).
    func faceRaw(lastSeconds: Double? = nil) -> API.FaceRaw? {
        guard let t0 = firstTime, !rows.isEmpty else { return nil }
        var start = 0
        if let keep = lastSeconds, keep.isFinite, keep > 0 {
            start = max(0, rows.count - Int((keep * Double(rateHz)).rounded(.up)))
        }
        let keptRows = Array(rows[start...])
        let keptTracked = Array(tracked[start...])
        guard keptTracked.contains(1) else { return nil }

        let firstKept = t0 + Double(start) / Double(rateHz)
        let lastKept = t0 + Double(rows.count - 1) / Double(rateHz)
        let momentsMs = moments
            .filter { $0 >= firstKept && $0 <= lastKept }
            .map { Int((($0 - firstKept) * 1000).rounded()) }
            .prefix(Self.maxMoments)
        return API.FaceRaw(rateHz: rateHz, channels: Self.channels, samples: keptRows,
                           tracked: keptTracked.allSatisfy { $0 == 1 } ? nil : keptTracked,
                           momentsMs: momentsMs.isEmpty ? nil : Array(momentsMs))
    }

    private mutating func appendEmpty() {
        rows.append([Double](repeating: 0, count: Self.channels.count))
        tracked.append(0)
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Degrees, two decimals, wrapped into -180...180.
    static func angle(_ deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        var a = deg.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return (a * 100).rounded() / 100
    }
}

// MARK: - Fine facial movement
// Kept in this file (not its own) so the generated Xcode project needs no change.

/// Fine facial movement for `face_fine` (see `docs/face-fine.md`): research only.
///
/// The ARKit face mesh is the shape of a face, so it never leaves the phone and is
/// never stored. This is the one place where the phone computes from the face before
/// it sends: for a few named regions and for every frame, ONE number, how far the
/// region is from this person's own resting shape, in millimetres. The mesh is already
/// in the face anchor's own coordinates, so the head's movement is out.
///
/// How it works:
/// - The resting shape (per vertex, the median position) comes from the first QUIET
///   stretch of `restFrames` tracked frames, not simply from the first frames: at the
///   start ARKit is still fitting the face and the person is still settling, and a rest
///   learned there put every later number 1 to 3 mm off on the first real games. Up to
///   `maxRestWindows` stretches are tried; if none is quiet the quietest is taken.
///   The shape stays in memory for this one game and is then forgotten.
/// - Regions are found on that resting shape by where they lie on the face, as
///   fractions of its width and height (`boxes`), not by fixed vertex numbers.
/// - Each later frame: per region, the mean distance of its vertices from rest.
/// - `noiseMm`: how much those numbers jump from frame to frame over the resting
///   frames (their standard deviation, averaged over the regions).
/// - After tracking was lost, the first `regainFrames` frames are sent as untracked:
///   the mesh jumps while ARKit finds the face again, and that is not a movement.
///
/// The region boxes are a first guess and have not been checked on a device. In a
/// DEBUG build `FaceSense` prints how many vertices each region caught.
///
/// Rows keep a steady `rateHz` on ARKit's clock exactly as `FaceRawRecorder` does, so
/// the two streams of one game line up row by row.
struct FaceFineRecorder {

    /// A region as a box on the resting face: `u` runs from the person's right (0) to
    /// their left (1), `v` from the chin (0) to the top of the mesh (1).
    struct Box {
        let name: String
        let u: ClosedRange<Float>
        let v: ClosedRange<Float>
    }

    /// The names are the server's fixed list (`docs/face-fine.md`).
    static let boxes: [Box] = [
        Box(name: "mouth_left", u: 0.52...0.68, v: 0.22...0.34),
        Box(name: "mouth_right", u: 0.32...0.48, v: 0.22...0.34),
        Box(name: "lip_upper", u: 0.42...0.58, v: 0.30...0.36),
        Box(name: "lip_lower", u: 0.42...0.58, v: 0.20...0.27),
        Box(name: "cheek_left", u: 0.65...0.85, v: 0.35...0.55),
        Box(name: "cheek_right", u: 0.15...0.35, v: 0.35...0.55),
        Box(name: "brow_left", u: 0.55...0.80, v: 0.72...0.82),
        Box(name: "brow_right", u: 0.20...0.45, v: 0.72...0.82),
        Box(name: "eyelid_left", u: 0.57...0.75, v: 0.60...0.69),
        Box(name: "eyelid_right", u: 0.25...0.43, v: 0.60...0.69),
        Box(name: "jaw", u: 0.38...0.62, v: 0.02...0.14),
        Box(name: "nose", u: 0.44...0.56, v: 0.42...0.56),
        // The corners themselves: the outer end of each half of the mouth, a small patch,
        // so a brief pull at one corner is not averaged away over the half.
        Box(name: "mouth_corner_left", u: 0.61...0.70, v: 0.24...0.32),
        Box(name: "mouth_corner_right", u: 0.30...0.39, v: 0.24...0.32),
    ]
    static let required = ["mouth_left", "mouth_right"]

    /// 1.5 seconds at 30 Hz to learn the resting shape.
    static let restFrames = 45
    /// A stretch is quiet when no region's number spreads more than this over it
    /// (standard deviation, mm). A first guess, not set on recordings.
    static let quietMm = 0.15
    /// Stretches tried before the quietest is taken anyway (9 seconds).
    static let maxRestWindows = 6
    /// Frames left out after tracking comes back (a third of a second at 30 Hz).
    static let regainFrames = 10
    /// A hole in time at least this long counts as tracking lost (0.2 s at 30 Hz).
    static let lostSlots = 6
    /// A region needs at least this many vertices to be sent.
    static let minVertices = 3
    /// Same limits as the raw frames (`FaceRawRecorder`).
    static let maxSamples = 9_000
    static let maxGapSlots = 300
    /// The server takes 0 to 50 mm.
    static let maxMm = 50.0

    /// Off with the launch argument `-noFaceFine` (the raw frames are still sent).
    static var isEnabled: Bool { !ProcessInfo.processInfo.arguments.contains("-noFaceFine") }

    let rateHz: Int
    private var rows: [[Double]] = []          // one value per box, in `boxes` order
    private var tracked: [Int] = []
    private var firstTime: Double?
    private var early: [(slot: Int, vertices: [SIMD3<Float>])] = []
    private var rest: [SIMD3<Float>]?
    private var windowsTried = 0
    private var best: (shape: [SIMD3<Float>], members: [[Int]], noise: Double?, worst: Double)?
    private var skipLeft = 0
    private var members: [[Int]] = []          // per box: vertex indices
    private(set) var noiseMm: Double?

    init(rateHz: Int = 30) {
        self.rateHz = min(max(rateHz, 5), 60)
    }

    var isFull: Bool { rows.count >= Self.maxSamples }
    var count: Int { rows.count }
    /// Vertices each region caught, once the resting shape is known (for the log).
    var regionSizes: [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(Self.boxes.map(\.name), members.map(\.count)))
    }

    /// One ARKit frame. `vertices` (metres, face anchor space) is asked for only when the
    /// frame is kept, so a dropped frame costs nothing.
    mutating func add(time: Double, tracked isTracked: Bool, vertices: () -> [SIMD3<Float>]) {
        guard time.isFinite, !isFull else { return }
        if firstTime == nil { firstTime = time }
        guard let t0 = firstTime, time >= t0 else { return }
        let slot = Int(((time - t0) * Double(rateHz)).rounded())
        guard slot >= rows.count else { return }   // same slot again: keep the first

        let missing = slot - rows.count
        if missing > 0 {
            for _ in 0..<min(missing, Self.maxGapSlots) where !isFull { appendEmpty() }
            if missing > Self.maxGapSlots {
                firstTime = time - Double(rows.count) / Double(rateHz)
            }
            if missing >= Self.lostSlots { skipLeft = Self.regainFrames }
        }
        guard !isFull else { return }
        guard isTracked else { skipLeft = Self.regainFrames; appendEmpty(); return }
        if skipLeft > 0 { skipLeft -= 1; appendEmpty(); return }
        let v = vertices()
        guard !v.isEmpty else { appendEmpty(); return }

        if let rest {
            guard v.count == rest.count else { appendEmpty(); return }
            rows.append(Self.measure(v, against: rest, members: members))
            tracked.append(1)
        } else {
            // Not yet known where the face rests: keep the frame until it is.
            early.append((rows.count, v))
            rows.append([Double](repeating: 0, count: Self.boxes.count))
            tracked.append(1)
            if early.count % Self.restFrames == 0 { tryWindow() }
        }
    }

    /// The `face_fine` object, or nil when the resting shape was never learned (too few
    /// tracked frames) or the mouth regions caught no vertices.
    /// `lastSeconds` keeps only the end, as for the raw frames.
    func faceFine(lastSeconds: Double? = nil) -> API.FaceFine? {
        if rest == nil, best != nil {
            // The game ended while a quieter stretch was still looked for: take the best.
            var done = self
            done.settle()
            return done.faceFine(lastSeconds: lastSeconds)
        }
        guard rest != nil, !rows.isEmpty else { return nil }
        let active = Self.boxes.indices.filter { members[$0].count >= Self.minVertices }
        let names = active.map { Self.boxes[$0].name }
        guard Self.required.allSatisfy(names.contains) else { return nil }

        var start = 0
        if let keep = lastSeconds, keep.isFinite, keep > 0 {
            start = max(0, rows.count - Int((keep * Double(rateHz)).rounded(.up)))
        }
        let keptTracked = Array(tracked[start...])
        guard keptTracked.contains(1) else { return nil }
        let keptRows = rows[start...].map { row in active.map { row[$0] } }
        return API.FaceFine(source: "mesh", rateHz: rateHz, regions: names, samples: keptRows,
                            tracked: keptTracked.allSatisfy { $0 == 1 } ? nil : keptTracked,
                            noiseMm: noiseMm)
    }

    // MARK: The resting shape

    /// A full stretch of frames is waiting: learn a resting shape from it and see how
    /// quiet it was. Quiet enough, or enough stretches tried: settle on the best so far.
    private mutating func tryWindow() {
        let frames = Array(early.suffix(Self.restFrames))
        guard let n = frames.first?.vertices.count, n > 0,
              frames.allSatisfy({ $0.vertices.count == n }) else { early = []; best = nil; return }
        var shape = [SIMD3<Float>](repeating: .zero, count: n)
        var xs = [Float](repeating: 0, count: frames.count)
        var ys = xs, zs = xs
        for i in 0..<n {
            for (k, f) in frames.enumerated() {
                xs[k] = f.vertices[i].x; ys[k] = f.vertices[i].y; zs[k] = f.vertices[i].z
            }
            shape[i] = SIMD3(Self.median(xs), Self.median(ys), Self.median(zs))
        }
        let members = Self.assign(shape)
        var columns = [[Double]](repeating: [], count: Self.boxes.count)
        for f in frames {
            for (j, value) in Self.measure(f.vertices, against: shape, members: members).enumerated() {
                columns[j].append(value)
            }
        }
        // The spread of each region's number over the stretch (standard deviation). Its
        // average over the regions sent is the noise; its largest decides how quiet the
        // stretch was, so one moving region is not averaged away. Not the level: the rule
        // on the server compares a movement with how much the number jumps.
        let spreads = columns.enumerated().compactMap { j, v -> Double? in
            guard members[j].count >= Self.minVertices, v.count > 1 else { return nil }
            let mean = v.reduce(0, +) / Double(v.count)
            return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1)).squareRoot()
        }
        let noise = spreads.isEmpty ? nil : Self.round2(min(spreads.reduce(0, +) / Double(spreads.count), 5))
        let worst = spreads.max() ?? .infinity
        if best == nil || worst < best!.worst { best = (shape, members, noise, worst) }
        windowsTried += 1
        if worst <= Self.quietMm || windowsTried >= Self.maxRestWindows { settle() }
    }

    /// Take the best resting shape found and measure the frames that were waiting.
    /// The waiting vertices are then let go.
    private mutating func settle() {
        guard let b = best else { return }
        rest = b.shape
        members = b.members
        noiseMm = b.noise
        for f in early where f.vertices.count == b.shape.count {
            rows[f.slot] = Self.measure(f.vertices, against: b.shape, members: b.members)
        }
        early = []
        best = nil
    }

    /// Which vertices lie in which box of the resting face.
    static func assign(_ shape: [SIMD3<Float>]) -> [[Int]] {
        guard let first = shape.first else { return boxes.map { _ in [] } }
        var lo = first, hi = first
        for p in shape { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let w = max(hi.x - lo.x, .leastNonzeroMagnitude)
        let h = max(hi.y - lo.y, .leastNonzeroMagnitude)
        var out = [[Int]](repeating: [], count: boxes.count)
        for (i, p) in shape.enumerated() {
            // +X in the face anchor's space is the person's own left.
            let u = (p.x - lo.x) / w, v = (p.y - lo.y) / h
            for (j, box) in boxes.enumerated() where box.u.contains(u) && box.v.contains(v) {
                out[j].append(i)
            }
        }
        return out
    }

    static func measure(_ v: [SIMD3<Float>], against shape: [SIMD3<Float>], members: [[Int]]) -> [Double] {
        members.map { ids in
            guard !ids.isEmpty else { return 0 }
            var sum: Float = 0
            for i in ids { sum += simd_distance(v[i], shape[i]) }
            let mm = Double(sum / Float(ids.count)) * 1000
            return mm.isFinite ? round2(min(max(mm, 0), maxMm)) : 0
        }
    }

    private mutating func appendEmpty() {
        rows.append([Double](repeating: 0, count: Self.boxes.count))
        tracked.append(0)
    }

    static func median(_ values: [Float]) -> Float {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
