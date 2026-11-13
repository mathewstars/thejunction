import Foundation

/// Left minus right for one paired coefficient.
struct AsymmetryPair: Identifiable {
    var id: String { base }
    let base: String            // e.g. "mouthSmile"
    let leftIdentifier: String  // "mouthSmile_L"
    let rightIdentifier: String // "mouthSmile_R"
    let left: Float
    let right: Float
    /// left - right, range -1...1.
    var difference: Float { left - right }
    /// |left - right| / max(left, right), 0 when both are near zero.
    var normalisedIndex: Float {
        let m = max(left, right)
        return m > 0.02 ? abs(left - right) / m : 0
    }
}

/// Group-level asymmetry: mean of (left - right) across the pairs in the group.
struct AsymmetryGroupValue: Identifiable {
    var id: String { group }
    let group: String
    let difference: Float
    let meanAbsoluteDifference: Float
    let pairCount: Int
}

/// Compares every "_L" / "_R" coefficient pair ARKit exposes and aggregates them into groups.
/// Pairs are discovered from the identifiers, so new SDK coefficients join automatically.
final class AsymmetryAnalyzer {

    var windowSeconds: Double = 5

    /// Group name -> coefficient bases. Bases absent from the SDK are skipped.
    static let groups: [(name: String, bases: [String])] = [
        ("smile", ["mouthSmile"]),
        ("brow", ["browDown", "browOuterUp"]),
        ("eye", ["eyeBlink", "eyeSquint", "eyeWide", "eyeLookUp", "eyeLookDown"]),
        ("cheek", ["cheekSquint"]),
        ("mouth", ["mouthFrown", "mouthPress", "mouthStretch", "mouthUpperUp", "mouthLowerDown", "mouthDimple"]),
        ("nose", ["noseSneer"])
    ]

    /// Directional pairs that are separate coefficients rather than _L/_R variants.
    static let directionalPairs: [(base: String, left: String, right: String)] = [
        ("jawSide", "jawLeft", "jawRight"),
        ("mouthSide", "mouthLeft", "mouthRight")
    ]

    private(set) var pairs: [AsymmetryPair] = []
    private(set) var groupValues: [AsymmetryGroupValue] = []
    private(set) var history = TimeAlignedHistory(capacity: 1800)

    func process(values: [String: Float], timestamp: Double) -> [String: Float] {
        var found: [AsymmetryPair] = []
        var seenBases = Set<String>()
        for (id, value) in values where id.hasSuffix("_L") {
            let base = BlendShapeCatalog.pairBase(of: id)
            let rightId = base + "_R"
            guard let right = values[rightId] else { continue }
            found.append(AsymmetryPair(base: base, leftIdentifier: id, rightIdentifier: rightId, left: value, right: right))
            seenBases.insert(base)
        }
        for d in AsymmetryAnalyzer.directionalPairs {
            if let l = values[d.left], let r = values[d.right] {
                found.append(AsymmetryPair(base: d.base, leftIdentifier: d.left, rightIdentifier: d.right, left: l, right: r))
            }
        }
        found.sort { $0.base < $1.base }
        pairs = found

        var byBase = [String: AsymmetryPair]()
        for p in found { byBase[p.base] = p }

        var frameValues: [String: Float] = [:]
        var groups: [AsymmetryGroupValue] = []
        for g in AsymmetryAnalyzer.groups {
            let members = g.bases.compactMap { byBase[$0] }
            guard !members.isEmpty else { continue }
            let diff = members.map { $0.difference }.reduce(0, +) / Float(members.count)
            let absDiff = members.map { abs($0.difference) }.reduce(0, +) / Float(members.count)
            groups.append(AsymmetryGroupValue(group: g.name, difference: diff, meanAbsoluteDifference: absDiff, pairCount: members.count))
            frameValues[g.name] = diff
        }
        // Overall: mean absolute difference across every pair.
        if !found.isEmpty {
            let overall = found.map { abs($0.difference) }.reduce(0, +) / Float(found.count)
            groups.append(AsymmetryGroupValue(group: "overall", difference: overall, meanAbsoluteDifference: overall, pairCount: found.count))
            frameValues["overall"] = overall
        }
        groupValues = groups
        history.append(time: timestamp, values: frameValues)
        return frameValues
    }

    func noteMissingFrame(timestamp: Double) {
        history.append(time: timestamp, values: [:])
    }

    /// Mean absolute group difference inside the window (application-derived).
    func windowedMeanAbsolute(group: String) -> Float? {
        let n = history.sampleCount(withinLast: windowSeconds)
        guard n > 0 else { return nil }
        let v = history.values(for: group, last: n)
        guard !v.isEmpty else { return nil }
        return v.map { abs($0) }.reduce(0, +) / Float(v.count)
    }

    func recent(_ group: String, count: Int) -> [Float] { history.values(for: group, last: count) }

    func reset() {
        pairs.removeAll()
        groupValues.removeAll()
        history.removeAll()
    }
}
