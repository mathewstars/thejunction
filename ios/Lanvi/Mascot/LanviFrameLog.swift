import Foundation
import QuartzCore

/// Debug only (launch argument `-puppetLog YES`): records, for every frame the puppet
/// draws, the wall-clock time, the timeline's date and the final transform of each
/// moving part, from 2 s to `puppetLogSeconds` (default 10) s after the first frame. Written to
/// `tmp/puppet-frames.csv` in the app's container. Used to measure the real frame
/// rate and to find any shake (a value that changes direction too often).
final class LanviFrameLog {
    static let shared: LanviFrameLog? = UserDefaults.standard.bool(forKey: "puppetLog") ? LanviFrameLog() : nil

    private var lines: [String] = []
    private var first: CFTimeInterval?
    private var written = false
    private let limit: Double = {
        let v = UserDefaults.standard.double(forKey: "puppetLogSeconds")
        return v > 0 ? v : 10
    }()

    /// `extra`: the puppet's own state for the frame (petting, finger, touch, moment, look
    /// steps, clock lag), only worked out while logging.
    func record(date: Date, _ f: RigFrame, extra: @autoclosure () -> String = "") {
        guard !written else { return }
        let now = CACurrentMediaTime()
        if first == nil { first = now }
        let age = now - (first ?? now)
        if age < 2 { return }
        if age > limit { write(); return }
        let p = f.pose
        var values: [Double] = [now, date.timeIntervalSinceReferenceDate]
        values += [p.rootX, p.rootY, p.rootSX, p.rootSY, p.rootTilt]
        values += [p.headX, p.headY, p.headTilt, p.bodySY, p.chest, p.dirX, p.dirY]
        values += [p.earL, p.earR, f.earLBend, f.earRBend, p.tail, f.tailBend, f.headSY, p.eyeX, p.eyeY]
        let row = values.map { String(format: "%.5f", $0) }.joined(separator: ",")
        // every eye picture drawn this frame with its opacity, e.g. "open:0.55|half:0.45"
        let eyeLayers = f.eyes.map { "\($0.0):" + String(format: "%.2f", $0.1) }.joined(separator: "|")
        lines.append(row + ",\(f.face.eyes),\(f.face.mouth),\(f.eyes.count),\(eyeLayers),\(extra())")
    }

    private func write() {
        written = true
        let header = "now,date,rootX,rootY,rootSX,rootSY,rootTilt,headX,headY,headTilt,bodySY,chest,dirX,dirY,earL,earR,earLBend,earRBend,tail,tailBend,headSY,eyeX,eyeY,eyes,mouth,eyeCount,eyeLayers,petting,finger,touch,moment,lookSteps,clockLag,held,reaction,prevTouch,fingerLook,lookX,lookY,eyeCross,eyeSet,lidDown,eyeOpacity,lashOpacity,blink,mouths\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("puppet-frames.csv")
        try? (header + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
