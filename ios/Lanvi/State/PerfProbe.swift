import Foundation
import QuartzCore
import UIKit
import Darwin
import os

#if DEBUG
/// Debug builds only (off with the launch argument `-noperf`): the numbers behind
/// "is the app fast?", measured on the phone itself. Every line starts with
/// `lanvi-perf:` and goes to the device log (Console, `log stream`), to stdout
/// when no debugger mirrors the log, and to `tmp/lanvi-perf.log` in the app's
/// container. It only watches; it changes nothing the person sees.
///
/// Lines:
/// - `launch`: process start → first frame, and → Home's first frame, and → the
///   first moment after it with ten frames in a row under 20 ms ("interactive").
/// - `tap`: one per tap, named by the control's accessibility label or identifier.
///   `down→frame` is the touch going down to the end of the first frame committed
///   after it (a pressed look shows there). `up→frame` is the finger lifting (a
///   SwiftUI button acts here) to the end of the frame that carries the action's
///   own synchronous work. `→ '<change>'` is the frame that carries the state the tap
///   asked for (a screen opening, a message added) when that change is named.
///   "Committed" frames reach the glass about one display frame later.
/// - `open` / `close`: a screen or panel over Home, or a first-run step: state
///   change → first frame (the main thread's cost of building it), then the
///   worst frame and the dropped frames during its 0.6 s move.
/// - `keyboard`: the tap on a text field → the keyboard starting to rise, → risen.
/// - `main blocked`: the main thread went more than 50 ms without letting a frame out.
/// - `frames`: every 5 s, average and worst frame time, dropped frames, how busy
///   the main thread was, where the person was (Home day or night, or which screen).
final class PerfProbe {
    static let shared = PerfProbe()

    // MARK: Output

    private static let logger = Logger(subsystem: "app.lanvi.Lanvi", category: "perf")
    /// Xcode mirrors the device log into its console by itself; anywhere else
    /// (for example `devicectl ... --console`) the line is printed too.
    private static let alsoPrint = ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] == nil
    private static let fileQueue = DispatchQueue(label: "lanvi.perf.log", qos: .utility)
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lanvi-perf.log")

    /// One line. `line` is written without the prefix.
    static func log(_ line: String) {
        let full = "lanvi-perf: " + line
        logger.notice("\(full, privacy: .public)")
        if alsoPrint { print(full) }
        let stamped = String(format: "%.3f ", CACurrentMediaTime()) + full + "\n"
        fileQueue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

    // MARK: Where the person is

    /// The world's light on Home (`day`, `night`, ...), set by Home.
    var world = "?"
    private var step = "?"
    private var homeShown = false
    private var cover: String?
    private var sheet: String?

    var place: String {
        guard homeShown else { return step }
        if let cover { return cover }
        if let sheet { return sheet }
        return "home \(world)"
    }

    // MARK: Run loop

    private var installed = false
    private var iterStart: CFTimeInterval = 0
    private var busyTotal: Double = 0      // seconds, read and reset every frames window
    private var lastMark = "start"

    func install() {
        guard FrameMeter.enabled, !installed else { return }
        installed = true
        UIWindow.lanviPerfSwizzle()
        let rl = CFRunLoopGetMain()
        let start = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            self?.iterStart = CACurrentMediaTime()
        }
        // After Core Animation's commit (order 2_000_000): the pass's frame is handed over.
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            self?.passEnded()
        }
        CFRunLoopAddObserver(rl, start, .commonModes)
        CFRunLoopAddObserver(rl, end, .commonModes)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keyboard(will: true)
        }
        nc.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keyboard(will: false)
        }
    }

    func takeBusy() -> Double { defer { busyTotal = 0 }; return busyTotal }

    private func passEnded() {
        let now = CACurrentMediaTime()
        let busy = iterStart > 0 ? now - iterStart : 0
        busyTotal += busy
        if busy > 0.05 {
            Self.log(String(format: "main blocked %.0f ms (no frame could go out), on %@, last change '%@'",
                            busy * 1000, place, lastMark))
        }
        if firstFrameAt == nil { firstFrameAt = now; firstFramePlace = place }
        if homeShown, homeFirstFrame == nil { homeFirstFrame = now }
        tapPassEnded(now: now, busy: busy)
        if var t = transition, t.firstFrame == nil {
            t.firstFrame = now - t.at
            t.busy = busy
            transition = t
        }
    }

    // MARK: Marks (FrameMeter.mark): a named change the person will see

    func marked(_ what: String) {
        lastMark = what
        let now = CACurrentMediaTime()
        let parts = what.split(separator: " ", maxSplits: 1).map(String.init)
        let kind = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "cover":
            startTransition(value == "closed" ? "close \(cover ?? "cover")" : "open \(value)", at: now)
            cover = value == "closed" ? nil : value
        case "sheet":
            startTransition(value == "closed" ? "close \(sheet ?? "panel")" : "open \(value)", at: now)
            sheet = value == "closed" ? nil : value
        case "step":
            startTransition("open step \(value)", at: now)
            step = value
        default: break
        }
        // Only changes a tap asks for (not the fox's own glances and moods).
        let fromTap: Set<String> = ["cover", "sheet", "step", "chat", "today"]
        if tap != nil, tapChange == nil, pendingChange == nil, fromTap.contains(kind) { pendingChange = what }
    }

    /// The first screen RootView shows (before any step change).
    func rootShown(_ step: String) {
        if self.step == "?" { self.step = step }
    }

    func homeAppeared() {
        homeShown = true
    }

    // MARK: Screens and panels opening and closing

    private struct Transition {
        var name: String
        var at: CFTimeInterval
        var firstFrame: Double?
        var busy: Double = 0
        var worst: Double = 0
        var dropped = 0
    }
    private var transition: Transition?

    private func startTransition(_ name: String, at now: CFTimeInterval) {
        finishTransition()
        transition = Transition(name: name, at: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            if self?.transition?.at == now { self?.finishTransition() }
        }
    }

    private func finishTransition() {
        guard let t = transition else { return }
        transition = nil
        Self.log(String(format: "%@: state → first frame %.0f ms (main busy %.0f ms building it), move 0.6 s: worst frame %.0f ms, %d dropped",
                        t.name, (t.firstFrame ?? -0.001) * 1000, t.busy * 1000, t.worst, t.dropped))
    }

    // MARK: Taps

    private struct Tap {
        var name: String?
        var namedLate = false
        var nameCost: Double = 0
        var point: CGPoint
        var placeAtDown: String
        var down: TimeInterval
        var up: TimeInterval?
        var downFrame: Double?
        var downBusy: Double = 0
        var upFrame: Double?
        var upBusy: Double = 0
        var worst: Double = 0
    }
    private var tap: Tap?
    private var tapChange: (String, Double)?
    private var pendingChange: String?
    private var lastTouchDown: (TimeInterval, String)?

    func touchBegan(_ ts: TimeInterval, at p: CGPoint, in window: UIWindow) {
        finishTap()
        tap = Tap(point: p, placeAtDown: place, down: ts)
        tapChange = nil
        pendingChange = nil
        // Name the control a moment later, while the finger is still down, so the
        // lookup never sits between the touch and its first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak window] in
            guard let self, let window, self.tap?.down == ts else { return }
            let t0 = CACurrentMediaTime()
            let name = Self.controlName(at: p, in: window)
            if var t = self.tap {
                t.nameCost = CACurrentMediaTime() - t0
                t.name = name
                t.namedLate = t.up != nil
                self.tap = t
            }
            self.lastTouchDown = (ts, name ?? String(format: "%.0f,%.0f", p.x, p.y))
        }
        lastTouchDown = (ts, String(format: "%.0f,%.0f", p.x, p.y))
    }

    func touchEnded(_ ts: TimeInterval, at p: CGPoint, cancelled: Bool) {
        guard var t = tap, t.up == nil else { return }
        // A drag or a scroll is not a tap.
        if cancelled || hypot(p.x - t.point.x, p.y - t.point.y) > 12 { tap = nil; return }
        t.up = ts
        tap = t
        let down = t.down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.tap?.down == down { self?.finishTap() }
        }
    }

    private func tapPassEnded(now: CFTimeInterval, busy: Double) {
        guard var t = tap else { return }
        if t.downFrame == nil, now >= t.down { t.downFrame = now - t.down; t.downBusy = busy }
        if let up = t.up, t.upFrame == nil, now >= up { t.upFrame = now - up; t.upBusy = busy }
        tap = t
        if let m = pendingChange, tapChange == nil {
            tapChange = (m, now - (t.up ?? t.down))
            pendingChange = nil
        }
    }

    private func finishTap() {
        guard let t = tap else { return }
        tap = nil
        guard let up = t.up else { return }
        let name = t.name.map { "\"\($0)\"" + (t.namedLate ? "?" : "") } ?? String(format: "at %.0f,%.0f", t.point.x, t.point.y)
        let change = tapChange.map { String(format: ", → '%@' %.0f ms", $0.0, $0.1 * 1000) } ?? ""
        Self.log(String(format: "tap %@ on %@: down→frame %.0f ms (busy %.0f), up→frame %.0f ms (busy %.0f)%@, worst frame in 0.6 s %.0f ms, held %.0f ms, naming took %.1f ms",
                        name, t.placeAtDown,
                        (t.downFrame ?? -0.001) * 1000, t.downBusy * 1000,
                        (t.upFrame ?? -0.001) * 1000, t.upBusy * 1000,
                        change, t.worst, (up - t.down) * 1000, t.nameCost * 1000))
        tapChange = nil
        pendingChange = nil
    }

    /// The smallest button, field or adjustable control under the point, by its
    /// identifier, else its label (never plain text, so no chat words are logged).
    /// Stops after 8 ms.
    static func controlName(at p: CGPoint, in window: UIWindow) -> String? {
        let sp = window.convert(p, to: window.screen.coordinateSpace)
        let deadline = CACurrentMediaTime() + 0.008
        var best: (name: String, area: CGFloat)?
        let wanted: UIAccessibilityTraits = [.button, .adjustable, .link, .searchField, .keyboardKey]
        func visit(_ obj: NSObject, depth: Int) {
            guard depth < 60, CACurrentMediaTime() < deadline else { return }
            if obj.isAccessibilityElement {
                let f = obj.accessibilityFrame
                let isField = obj is UITextField || obj is UITextView
                guard f.contains(sp), isField || !obj.accessibilityTraits.intersection(wanted).isEmpty else { return }
                let id = (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                let label = isField ? "text field" : String((obj.accessibilityLabel ?? "").prefix(32))
                let name = id.isEmpty ? label : id
                let area = f.width * f.height
                if !name.isEmpty, area < (best?.area ?? .infinity) { best = (name, area) }
                return
            }
            if let view = obj as? UIView {
                if view.isHidden || view.alpha < 0.01 { return }
                let local = view.convert(p, from: window)
                if view.clipsToBounds, !view.bounds.contains(local) { return }
            }
            if let els = obj.accessibilityElements as? [NSObject] {
                for e in els { visit(e, depth: depth + 1) }
            } else {
                let n = obj.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 400) {
                        if let e = obj.accessibilityElement(at: i) as? NSObject { visit(e, depth: depth + 1) }
                    }
                } else if let view = obj as? UIView {
                    for sub in view.subviews.reversed() { visit(sub, depth: depth + 1) }
                }
            }
        }
        visit(window, depth: 0)
        return best?.name
    }

    // MARK: Frames (from FrameMeter's display link)

    private var firstFrameAt: CFTimeInterval?
    private var firstFramePlace = ""
    private var homeFirstFrame: CFTimeInterval?
    private var smoothRun = 0
    private var launchDone = false

    /// One display frame's interval in ms.
    func frame(_ ms: Double, at now: CFTimeInterval) {
        if var t = tap, now > t.down, now - t.down < 0.6 {
            t.worst = max(t.worst, ms)
            tap = t
        }
        if var tr = transition, now > tr.at {
            tr.worst = max(tr.worst, ms)
            if ms > 20 { tr.dropped += Int((ms / 16.7).rounded()) - 1 }
            transition = tr
        }
        if homeFirstFrame != nil, !launchDone {
            smoothRun = ms < 20 ? smoothRun + 1 : 0
            if smoothRun >= 10 {
                launchDone = true
                let start = Self.processStart
                Self.log(String(format: "launch: process start → first frame %.0f ms (%@), → Home first frame %.0f ms, → interactive (10 smooth frames) %.0f ms",
                                ((firstFrameAt ?? now) - start) * 1000, firstFramePlace,
                                ((homeFirstFrame ?? now) - start) * 1000, (now - start) * 1000))
            }
        }
    }

    // MARK: Keyboard

    private var keyboardWill: Double?

    private func keyboard(will: Bool) {
        guard let (down, name) = lastTouchDown else { return }
        let since = CACurrentMediaTime() - down
        guard since < 2 else { return }
        if will { keyboardWill = since; return }
        Self.log(String(format: "keyboard for %@ on %@: tap → starts rising %.0f ms, → fully up %.0f ms",
                        name, place, (keyboardWill ?? -0.001) * 1000, since * 1000))
        keyboardWill = nil
        lastTouchDown = nil
    }

    // MARK: Process start

    /// When this process started, on the CACurrentMediaTime clock.
    static let processStart: CFTimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        let ageNow = Date().timeIntervalSince1970 - start
        return CACurrentMediaTime() - ageNow
    }()
}

extension UIWindow {
    static func lanviPerfSwizzle() {
        guard let a = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let b = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.lanviPerfSendEvent(_:))) else { return }
        method_exchangeImplementations(a, b)
    }

    @objc func lanviPerfSendEvent(_ event: UIEvent) {
        lanviPerfSendEvent(event)   // the original (swapped)
        guard event.type == .touches, let touches = event.allTouches else { return }
        guard touches.count == 1, let touch = touches.first, touch.window === self else {
            if let any = touches.first { PerfProbe.shared.touchEnded(any.timestamp, at: .zero, cancelled: true) }
            return
        }
        let p = touch.location(in: self)
        switch touch.phase {
        case .began: PerfProbe.shared.touchBegan(touch.timestamp, at: p, in: self)
        case .ended: PerfProbe.shared.touchEnded(touch.timestamp, at: p, cancelled: false)
        case .cancelled: PerfProbe.shared.touchEnded(touch.timestamp, at: p, cancelled: true)
        default: break
        }
    }
}
#endif
