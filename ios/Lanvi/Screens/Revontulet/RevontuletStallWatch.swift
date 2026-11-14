import Foundation
import QuartzCore
import UIKit

/// Debug builds only: catches a stalled game and says whose time it was.
/// - Every drawn frame checks the gap since the frame before. A gap over 0.25 s while the app
///   is active prints the beat and the slowest step of ours that ran inside the gap.
/// - A watchdog thread notices when the main thread stops answering for 0.25 s and prints
///   which step of ours it is inside right then, or that it is in none of ours (SwiftUI, the
///   system or the simulator), and how long the silence lasted once it ends.
/// - Any one step of ours over 50 ms is printed too.
/// Release builds keep only the plain call to `body`.
final class RevontuletStallWatch: @unchecked Sendable {
    static let shared = RevontuletStallWatch()
    static let gapLimit = 0.25
    static let stepLimit = 0.05

    private let lock = NSLock()
    private var current: (name: String, at: Double)?
    private var slowest: (name: String, seconds: Double)?
    private var beat = "-"
    private var lastFrame = 0.0
    private var answeredAt = 0.0
    private var silentReported = false
    private var running = false
    private var active = true
    private var observers: [NSObjectProtocol] = []

    /// Runs one step of ours, timed.
    func measure<T>(_ name: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let label = name()
        let t0 = CACurrentMediaTime()
        lock.lock()
        let outer = current
        current = (label, t0)
        lock.unlock()
        defer {
            let s = CACurrentMediaTime() - t0
            lock.lock()
            current = outer
            if s > (slowest?.seconds ?? 0) { slowest = (label, s) }
            let b = beat
            lock.unlock()
            if s > Self.stepLimit { print(String(format: "revontulet: slow step %@ %.0f ms in %@", label, s * 1000, b)) }
        }
        #endif
        return try body()
    }

    /// Called at the start of every drawn frame.
    func frame(beat b: String, at now: Double) {
        #if DEBUG
        lock.lock()
        beat = b
        let gap = lastFrame > 0 && active ? now - lastFrame : 0
        let worst = slowest
        lastFrame = now
        slowest = nil
        lock.unlock()
        if gap > Self.gapLimit {
            let ours = worst.map { String(format: "slowest step of ours inside it: %@ %.0f ms", $0.name, $0.seconds * 1000) }
                ?? "no step of ours ran inside it"
            print(String(format: "revontulet: STALL frame gap %.2f s in %@; %@", gap, b, ours))
        }
        #endif
    }

    @MainActor func start() {
        #if DEBUG
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lastFrame = 0
        answeredAt = CACurrentMediaTime()
        active = UIApplication.shared.applicationState == .active
        lock.unlock()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(true) },
        ]
        let watcher = Thread { [weak self] in self?.watch() }
        watcher.name = "revontulet-stall-watch"
        watcher.qualityOfService = .userInitiated
        watcher.start()
        #endif
    }

    @MainActor func stop() {
        #if DEBUG
        lock.lock()
        running = false
        lock.unlock()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        #endif
    }

    #if DEBUG
    private func setActive(_ a: Bool) {
        lock.lock()
        active = a
        lastFrame = 0
        answeredAt = CACurrentMediaTime()
        lock.unlock()
    }

    private func watch() {
        while true {
            lock.lock()
            guard running else { lock.unlock(); return }
            let now = CACurrentMediaTime()
            let silent = now - answeredAt
            let inside = current
            let b = beat
            let report = active && silent > Self.gapLimit && !silentReported
            if report { silentReported = true }
            lock.unlock()
            if report {
                let ours = inside.map { String(format: "inside our step %@ (running %.2f s)", $0.name, now - $0.at) }
                    ?? "in no step of ours"
                print(String(format: "revontulet: STALL main thread silent %.2f s in %@, %@", silent, b, ours))
            }
            DispatchQueue.main.async { [weak self] in self?.answered() }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func answered() {
        lock.lock()
        let now = CACurrentMediaTime()
        let was = silentReported ? now - answeredAt : nil
        silentReported = false
        answeredAt = now
        let b = beat
        lock.unlock()
        if let was { print(String(format: "revontulet: STALL over: main thread was silent %.2f s in all (%@)", was, b)) }
    }
    #endif
}
