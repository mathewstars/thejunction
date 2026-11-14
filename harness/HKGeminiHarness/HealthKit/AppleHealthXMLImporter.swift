import Foundation

/// Streaming importer for a complete Apple Health export (`export.xml` from Health → profile →
/// Export All Health Data, after unzipping). Files are often hundreds of megabytes, so the parser
/// reads from an `InputStream` and never loads the document into memory. Records are emitted one at a
/// time through `sink`; the importer keeps counts only.
///
/// Elements handled: `<Record>` (quantity and category samples), `<Workout>`, nested `<MetadataEntry>`.
/// Ignored on purpose: `<Me>` (date of birth, sex: identifying), `<ActivitySummary>`, `<Correlation>`
/// wrappers (their child Records are still imported), clinical records, audiograms, ECG.
public final class AppleHealthXMLImporter: NSObject, XMLParserDelegate {

    public struct Result {
        public var recordCount: Int = 0
        public var workoutCount: Int = 0
        public var skippedUnknownTypes: [String: Int] = [:]
        public var skippedOutOfRange: Int = 0
        public var parseErrors: [String] = []
        public var countsByType: [String: Int] = [:]
        public var firstDate: Date?
        public var lastDate: Date?
        public var exportDate: Date?
        public var bytesRead: Int64 = 0
    }

    public typealias Sink = (HealthSample) -> Void
    public typealias Progress = (Int) -> Void

    private let sink: Sink
    private let progress: Progress?
    private let range: DateRange?
    private let onlyKnownTypes: Bool
    private var result = Result()
    private var current: HealthSample?
    private var currentIsWorkout = false
    private var sequence = 0
    private var isCancelled: () -> Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// - Parameters:
    ///   - range: keep only samples whose end date falls inside; nil keeps everything.
    ///   - onlyKnownTypes: drop record types the catalog does not know (true) or keep them with the raw
    ///     identifier as display name (false).
    public init(range: DateRange? = nil, onlyKnownTypes: Bool = false, isCancelled: @escaping () -> Bool = { false },
                progress: Progress? = nil, sink: @escaping Sink) {
        self.sink = sink
        self.progress = progress
        self.range = range
        self.onlyKnownTypes = onlyKnownTypes
        self.isCancelled = isCancelled
    }

    public func run(file: URL) throws -> Result {
        guard let stream = InputStream(url: file) else {
            throw NSError(domain: "AppleHealthXMLImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(file.lastPathComponent)"])
        }
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize { result.bytesRead = Int64(size) }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if !ok, let e = parser.parserError, !isCancelled() {
            // XMLParser reports an error when the file is truncated; keep what was read.
            result.parseErrors.append("line \(parser.lineNumber): \(e.localizedDescription)")
        }
        return result
    }

    // MARK: XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        if isCancelled() { parser.abortParsing(); return }
        switch elementName {
        case "HealthData":
            // Nothing identifying here; locale only.
            break
        case "ExportDate":
            result.exportDate = a["value"].flatMap { Self.dateFormatter.date(from: $0) }
        case "Record":
            current = makeRecord(a)
            currentIsWorkout = false
        case "Workout":
            current = makeWorkout(a)
            currentIsWorkout = true
        case "MetadataEntry":
            if var c = current, let k = a["key"] {
                c.metadata[k] = .string(a["value"] ?? "")
                current = c
            }
        case "WorkoutStatistics":
            // iOS 16+ exports: per-workout totals live here instead of on the Workout element.
            if var c = current, currentIsWorkout, let type = a["type"] {
                if type == "HKQuantityTypeIdentifierActiveEnergyBurned", let s = a["sum"], let v = Double(s) {
                    c.workoutTotalEnergyKcal = v
                } else if type == "HKQuantityTypeIdentifierDistanceWalkingRunning", let s = a["sum"], let v = Double(s) {
                    // Unit in exports is usually "km" for distance; convert when told so.
                    c.workoutTotalDistanceM = (a["unit"] == "km") ? v * 1000 : v
                }
                current = c
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "Record" || elementName == "Workout", let c = current else { return }
        current = nil
        if let range, !(c.endDate >= range.start && c.endDate <= range.end) {
            result.skippedOutOfRange += 1
            return
        }
        if elementName == "Record" { result.recordCount += 1 } else { result.workoutCount += 1 }
        result.countsByType[c.typeIdentifier, default: 0] += 1
        if result.firstDate.map({ c.startDate < $0 }) ?? true { result.firstDate = c.startDate }
        if result.lastDate.map({ c.endDate > $0 }) ?? true { result.lastDate = c.endDate }
        sink(c)
        let total = result.recordCount + result.workoutCount
        if total % 5000 == 0 { progress?(total) }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if !isCancelled() { result.parseErrors.append("line \(parser.lineNumber): \(parseError.localizedDescription)") }
    }

    // MARK: Element builders

    private func makeRecord(_ a: [String: String]) -> HealthSample? {
        guard let type = a["type"],
              let start = a["startDate"].flatMap({ Self.dateFormatter.date(from: $0) }),
              let end = a["endDate"].flatMap({ Self.dateFormatter.date(from: $0) }) else { return nil }
        let descriptor = HealthTypeCatalog.descriptor(for: type)
        if descriptor == nil {
            result.skippedUnknownTypes[type, default: 0] += 1
            if onlyKnownTypes { return nil }
        }
        sequence += 1
        let isCategory = type.hasPrefix("HKCategoryTypeIdentifier")
        var value: Double? = nil
        var unit: String? = a["unit"]
        var categoryValue: Int? = nil
        var categoryLabel: String? = nil
        if isCategory {
            categoryValue = a["value"].flatMap { HealthTypeCatalog.categoryValue(fromXMLString: $0) }
            if let cv = categoryValue { categoryLabel = HealthTypeCatalog.categoryLabel(typeIdentifier: type, value: cv) }
            else { categoryLabel = a["value"] }
            unit = nil
        } else {
            value = a["value"].flatMap { Double($0) }
            // Normalise the few units where the export differs from the catalog's reading unit.
            if let d = descriptor, let v = value, let u = unit, let target = d.unitString, u != target {
                if let converted = Self.convert(v, from: u, to: target) { value = converted; unit = target }
            }
        }
        return HealthSample(
            id: "xml-\(sequence)", kind: isCategory ? .category : .quantity, typeIdentifier: type,
            displayName: descriptor?.displayName ?? type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""),
            startDate: start, endDate: end, value: value, unit: unit, categoryValue: categoryValue,
            categoryLabel: categoryLabel, sourceName: a["sourceName"], sourceBundleIdentifier: nil,
            sourceVersion: a["sourceVersion"], deviceName: Self.deviceName(from: a["device"]),
            deviceModel: Self.deviceModel(from: a["device"]), metadata: [:], origin: .appleHealthXML)
    }

    private func makeWorkout(_ a: [String: String]) -> HealthSample? {
        guard let start = a["startDate"].flatMap({ Self.dateFormatter.date(from: $0) }),
              let end = a["endDate"].flatMap({ Self.dateFormatter.date(from: $0) }) else { return nil }
        sequence += 1
        let activity = (a["workoutActivityType"] ?? "HKWorkoutActivityTypeOther")
            .replacingOccurrences(of: "HKWorkoutActivityType", with: "")
        var duration = end.timeIntervalSince(start)
        if let d = a["duration"].flatMap({ Double($0) }) {
            duration = (a["durationUnit"] == "min") ? d * 60 : d
        }
        var energy: Double? = a["totalEnergyBurned"].flatMap { Double($0) }
        if energy != nil, a["totalEnergyBurnedUnit"] == "kJ" { energy = energy! / 4.184 }
        var distance: Double? = a["totalDistance"].flatMap { Double($0) }
        if distance != nil, a["totalDistanceUnit"] == "km" { distance = distance! * 1000 }
        if distance != nil, a["totalDistanceUnit"] == "mi" { distance = distance! * 1609.344 }
        return HealthSample(
            id: "xml-workout-\(sequence)", kind: .workout, typeIdentifier: HealthTypeCatalog.workout.rawIdentifier,
            displayName: "Workout", startDate: start, endDate: end, value: duration, unit: "s",
            sourceName: a["sourceName"], sourceVersion: a["sourceVersion"],
            deviceName: Self.deviceName(from: a["device"]), deviceModel: Self.deviceModel(from: a["device"]),
            metadata: [:], origin: .appleHealthXML,
            workoutActivityType: activity.prefix(1).lowercased() + activity.dropFirst(),
            workoutTotalEnergyKcal: energy, workoutTotalDistanceM: distance)
    }

    /// `device="<<HKDevice: 0x...>, name:Apple Watch, manufacturer:Apple Inc., model:Watch, ...>"`
    static func deviceName(from s: String?) -> String? { field("name", in: s) }
    static func deviceModel(from s: String?) -> String? { field("model", in: s) }
    private static func field(_ key: String, in s: String?) -> String? {
        guard let s else { return nil }
        for part in s.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == key { return kv[1].replacingOccurrences(of: ">", with: "") }
        }
        return nil
    }

    /// Minimal unit conversions for the differences seen in real exports.
    static func convert(_ v: Double, from: String, to: String) -> Double? {
        switch (from, to) {
        case ("km", "m"): return v * 1000
        case ("mi", "m"): return v * 1609.344
        case ("cm", "m"): return v / 100
        case ("m", "cm"): return v * 100
        case ("ft", "m"): return v * 0.3048
        case ("in", "m"): return v * 0.0254
        case ("lb", "kg"): return v * 0.45359237
        case ("kJ", "kcal"): return v / 4.184
        case ("Cal", "kcal"): return v
        case ("degF", "degC"): return (v - 32) * 5 / 9
        case ("mL", "L"): return v / 1000
        case ("fl_oz_us", "L"): return v * 0.0295735
        case ("hr", "min"): return v * 60
        case ("s", "min"): return v / 60
        case ("g", "mg"): return v * 1000
        case ("mmol<180.1558800000541>/L", "mg/dL"): return v * 18.0156
        default: return nil
        }
    }
}
