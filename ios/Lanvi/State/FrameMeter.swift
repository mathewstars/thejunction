import Foundation
import QuartzCore

#if DEBUG
/// Debug builds only (on by default, off with `-noperf`): measures the real time
/// between display frames and how often chosen views rebuild, and prints both
/// every five seconds through `PerfProbe`, e.g.
/// `lanvi-perf: frames on home day: 300 frames, avg 16.7 ms, worst 17.1 ms, ...`
final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    static let enabled = !ProcessInfo.processInfo.arguments.contains("-noperf")

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var counts: [String: Int] = [:]
    private var windowStart: CFTimeInterval = 0
    private var windowPlace = ""

    /// Name what just happened, so a slow frame or a tap right after it can be traced.
    static func mark(_ what: String) {
        guard enabled else { return }
        PerfProbe.shared.marked(what)
    }

    /// Count one rebuild of a view (call from its body).
    static func count(_ name: String) {
        guard enabled else { return }
        shared.counts[name, default: 0] += 1
    }

    func start() {
        guard Self.enabled, link == nil else { return }
        PerfProbe.shared.install()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // 60 Hz, the 16e's own rate: watching must not raise the display's rate.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let place = PerfProbe.shared.place
        // A gap of more than a second is the app coming back from the background.
        if last > 0, now - last < 1 {
            let ms = (now - last) * 1000
            intervals.append(ms)
            PerfProbe.shared.frame(ms, at: now)
        }
        last = now
        if windowStart == 0 || place != windowPlace {
            if place != windowPlace, intervals.count >= 30 { report(now) }
            if place != windowPlace { reset(now, place) }
        }
        guard now - windowStart >= 5 else { return }
        report(now)
        reset(now, place)
    }

    private func reset(_ now: CFTimeInterval, _ place: String) {
        intervals.removeAll(keepingCapacity: true)
        counts.removeAll()
        _ = PerfProbe.shared.takeBusy()
        windowStart = now
        windowPlace = place
    }

    private func report(_ now: CFTimeInterval) {
        guard !intervals.isEmpty else { return }
        let sorted = intervals.sorted()
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let worst = sorted.last ?? 0
        // Frames the display wanted but did not get (a 33 ms gap at 60 Hz is one).
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / 16.67).rounded()) - 1) }
        let span = max(now - windowStart, 0.001)
        let views = counts.sorted { $0.key < $1.key }
            .map { "\($0.key) \(String(format: "%.1f", Double($0.value) / span))/s" }
            .joined(separator: ", ")
        let busy = PerfProbe.shared.takeBusy() * 1000 / Double(intervals.count)
        PerfProbe.log(String(format: "frames on %@: %d frames in %.1f s, avg %.1f ms, p95 %.1f ms, worst %.1f ms, dropped %d, main busy %.1f ms/frame | rebuilds: %@",
                             windowPlace, intervals.count, span, avg, p95, worst, dropped, busy, views.isEmpty ? "none" : views))
    }
}
#endif
