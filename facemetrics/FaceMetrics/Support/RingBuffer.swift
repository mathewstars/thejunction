import Foundation

/// Fixed-capacity circular buffer. Index 0 is the oldest element, `count - 1` the newest.
/// Not thread-safe; owned by one queue at a time.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head: Int = 0      // index of the oldest element
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    mutating func append(_ element: Element) {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        return storage[(head + index) % capacity]!
    }

    var last: Element? { count > 0 ? self[count - 1] : nil }
    var first: Element? { count > 0 ? self[0] : nil }

    /// Oldest to newest copy.
    func toArray() -> [Element] {
        var out = [Element]()
        out.reserveCapacity(count)
        for i in 0..<count { out.append(self[i]) }
        return out
    }

    /// The newest `n` elements, oldest first.
    func suffix(_ n: Int) -> [Element] {
        let n = max(0, min(n, count))
        var out = [Element]()
        out.reserveCapacity(n)
        for i in (count - n)..<count { out.append(self[i]) }
        return out
    }

    func forEach(_ body: (Element) -> Void) {
        for i in 0..<count { body(self[i]) }
    }
}

/// Welford running statistics for a stream of Float values. Minimum, maximum, mean and
/// sample variance are exact for all values seen so far; nothing is stored.
struct RunningStatistics {
    private(set) var count: Int = 0
    private(set) var mean: Double = 0
    private var m2: Double = 0
    private(set) var minimum: Float = .greatestFiniteMagnitude
    private(set) var maximum: Float = -.greatestFiniteMagnitude

    mutating func add(_ x: Float) {
        count += 1
        let xd = Double(x)
        let delta = xd - mean
        mean += delta / Double(count)
        m2 += delta * (xd - mean)
        if x < minimum { minimum = x }
        if x > maximum { maximum = x }
    }

    var variance: Double { count > 1 ? m2 / Double(count - 1) : 0 }
    var standardDeviation: Double { sqrt(variance) }
    var hasValues: Bool { count > 0 }
    var minOrNil: Float? { hasValues ? minimum : nil }
    var maxOrNil: Float? { hasValues ? maximum : nil }
    var meanOrNil: Float? { hasValues ? Float(mean) : nil }

    mutating func reset() { self = RunningStatistics() }
}

/// Time-aligned history: one timestamp buffer plus one value buffer per named channel.
/// All channels are appended together once per frame so indices line up.
struct TimeAlignedHistory {
    private(set) var times: RingBuffer<Double>
    private(set) var channels: [String: RingBuffer<Float>] = [:]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.times = RingBuffer<Double>(capacity: capacity)
    }

    mutating func append(time: Double, values: [String: Float]) {
        times.append(time)
        for (key, value) in values {
            if channels[key] == nil {
                var rb = RingBuffer<Float>(capacity: capacity)
                // Backfill with NaN so the new channel stays aligned with `times`.
                for _ in 0..<(times.count - 1) { rb.append(.nan) }
                rb.append(value)
                channels[key] = rb
            } else {
                channels[key]!.append(value)
            }
        }
        // Channels missing from this frame get NaN to preserve alignment.
        let missing = Array(channels.keys.filter { values[$0] == nil })
        for key in missing {
            channels[key]!.append(.nan)
        }
    }

    /// Number of trailing samples whose timestamp is within `seconds` of the newest one.
    func sampleCount(withinLast seconds: Double) -> Int {
        guard let newest = times.last else { return 0 }
        let cutoff = newest - seconds
        var n = 0
        var i = times.count - 1
        while i >= 0, times[i] >= cutoff { n += 1; i -= 1 }
        return n
    }

    func values(for key: String, last n: Int) -> [Float] {
        guard let rb = channels[key] else { return [] }
        return rb.suffix(n).filter { !$0.isNaN }
    }

    mutating func removeAll() {
        times.removeAll()
        channels.removeAll()
    }
}
