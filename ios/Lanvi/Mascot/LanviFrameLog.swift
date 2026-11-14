import Foundation
import QuartzCore

/// Debug only (launch argument `-puppetLog YES`): records, for every frame the puppet
/// draws, the wall-clock time, the timeline's date and the final transform of each
/// moving part, from 2 s to 10 s after the first frame. Written to
/// `tmp/puppet-frames.csv` in the app's container. Used to measure the real frame
/// rate and to find any shake (a value that changes direction too often).
final class LanviFrameLog {
    static let shared: LanviFrameLog? = UserDefaults.standard.bool(forKey: "puppetLog") ? LanviFrameLog() : nil

    private var lines: [String] = []
    private var first: CFTimeInterval?
    private var written = false

    func record(date: Date, _ f: RigFrame) {
        guard !written else { return }
        let now = CACurrentMediaTime()
        if first == nil { first = now }
        let age = now - (first ?? now)
        if age < 2 { return }
        if age > 10 { write(); return }
        var values: [Double] = [now, date.timeIntervalSinceReferenceDate]
        values += [Double(f.rootX), Double(f.rootY), Double(f.rootSX), Double(f.rootSY), f.rootTilt]
        values += [Double(f.headDX), Double(f.headDY), f.headTilt, Double(f.bodySY)]
        values += [f.earL, f.earR, f.tail, f.tailTip]
        let row = values.map { String(format: "%.5f", $0) }.joined(separator: ",")
        lines.append(row + ",\(f.eyes)")
    }

    private func write() {
        written = true
        let header = "now,date,rootX,rootY,rootSX,rootSY,rootTilt,headDX,headDY,headTilt,bodySY,earL,earR,tail,tailTip,eyes\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("puppet-frames.csv")
        try? (header + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
