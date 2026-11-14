import Foundation
import QuartzCore

#if DEBUG
/// Debug only, `-perf`: measures the real time between display frames on the
/// main thread and how often chosen views rebuild, and prints both every two
/// seconds, e.g.
/// `lanvi-perf: 120 frames, avg 8.3 ms, p95 8.9 ms, max 16.9 ms, hitches 0 | Home 0/s`
final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-perf")

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var counts: [String: Int] = [:]
    private var windowStart: CFTimeInterval = 0

    private var lastMark = "start"
    private var lastMarkAt: CFTimeInterval = 0

    /// Name what just happened, so a slow frame right after it can be traced.
    static func mark(_ what: String) {
        guard enabled else { return }
        shared.lastMark = what
        shared.lastMarkAt = CACurrentMediaTime()
    }

    /// Count one rebuild of a view (call from its body).
    static func count(_ name: String) {
        guard enabled else { return }
        shared.counts[name, default: 0] += 1
    }

    func start() {
        guard Self.enabled, link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if last > 0 {
            let ms = (now - last) * 1000
            intervals.append(ms)
            if ms > 25 {
                print(String(format: "lanvi-perf: slow frame %.1f ms, %.2f s after '%@'", ms, now - lastMarkAt, lastMark))
            }
        }
        last = now
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= 2 else { return }
        let sorted = intervals.sorted()
        let avg = intervals.reduce(0, +) / Double(max(intervals.count, 1))
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let mx = sorted.last ?? 0
        let hitches = intervals.filter { $0 > 25 }.count
        let views = counts.sorted { $0.key < $1.key }
            .map { "\($0.key) \(String(format: "%.1f", Double($0.value) / (now - windowStart)))/s" }
            .joined(separator: ", ")
        print(String(format: "lanvi-perf: %d frames, avg %.1f ms, p95 %.1f ms, max %.1f ms, hitches %d | %@",
                     intervals.count, avg, p95, mx, hitches, views))
        intervals.removeAll(keepingCapacity: true)
        counts.removeAll()
        windowStart = now
    }
}
#endif
