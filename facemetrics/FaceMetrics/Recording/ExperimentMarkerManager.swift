import Foundation

/// A researcher-placed event marker. Times use the ARFrame clock so they line up with samples.
struct ExperimentMarker: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    /// ARFrame timestamp at which the marker (or interval) started.
    var startTimestamp: Double
    /// ARFrame timestamp at which an interval marker ended; nil for instantaneous markers or open intervals.
    var endTimestamp: Double?
    var startFrameIndex: Int
    var endFrameIndex: Int?
    var wallClock: Date
    var note: String?

    var isInterval: Bool { endTimestamp != nil || isOpen }
    var isOpen: Bool { kind == .interval && endTimestamp == nil }
    var kind: Kind

    enum Kind: String, Codable { case instant, interval }

    var duration: Double? { endTimestamp.map { $0 - startTimestamp } }
}

/// Thread-safe store for markers during a tracking run. The tracking queue reads
/// `activeIntervalLabel()` for every sample, the UI writes from the main thread.
final class ExperimentMarkerManager {

    static let presetLabels: [String] = [
        "Neutral face", "Smile", "Blink", "Raise eyebrows", "Open mouth",
        "Look left", "Look right", "Look up", "Look down", "Speak", "Relax facial muscles"
    ]

    private let lock = NSLock()
    private var storage: [ExperimentMarker] = []
    private var openInterval: ExperimentMarker?

    /// Supplies the latest ARFrame timestamp and frame index. Set by the tracking manager.
    var clock: (() -> (timestamp: Double, frameIndex: Int))?

    var markers: [ExperimentMarker] {
        lock.lock(); defer { lock.unlock() }
        return storage + (openInterval.map { [$0] } ?? [])
    }

    var currentOpenInterval: ExperimentMarker? {
        lock.lock(); defer { lock.unlock() }
        return openInterval
    }

    func activeIntervalLabel() -> String? {
        lock.lock(); defer { lock.unlock() }
        return openInterval?.label
    }

    /// Adds an instantaneous marker at the current frame.
    @discardableResult
    func mark(_ label: String, note: String? = nil) -> ExperimentMarker {
        let now = clock?() ?? (0, 0)
        let m = ExperimentMarker(label: label, startTimestamp: now.timestamp, endTimestamp: nil,
                                 startFrameIndex: now.frameIndex, endFrameIndex: nil,
                                 wallClock: Date(), note: note, kind: .instant)
        lock.lock(); storage.append(m); lock.unlock()
        return m
    }

    /// Starts a held interval marker, closing any open one first.
    func beginInterval(_ label: String) {
        endInterval()
        let now = clock?() ?? (0, 0)
        let m = ExperimentMarker(label: label, startTimestamp: now.timestamp, endTimestamp: nil,
                                 startFrameIndex: now.frameIndex, endFrameIndex: nil,
                                 wallClock: Date(), note: nil, kind: .interval)
        lock.lock(); openInterval = m; lock.unlock()
    }

    func endInterval() {
        let now = clock?() ?? (0, 0)
        lock.lock()
        if var m = openInterval {
            m.endTimestamp = now.timestamp
            m.endFrameIndex = now.frameIndex
            storage.append(m)
            openInterval = nil
        }
        lock.unlock()
    }

    func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        if openInterval?.id == id { openInterval = nil }
        lock.unlock()
    }

    func clear() {
        lock.lock(); storage.removeAll(); openInterval = nil; lock.unlock()
    }

    /// Markers whose start time falls inside a recording window.
    func markers(from start: Double, to end: Double) -> [ExperimentMarker] {
        markers.filter { $0.startTimestamp >= start && $0.startTimestamp <= end }
    }
}
