import Foundation

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
