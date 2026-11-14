import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

public struct HealthKitAvailability: Equatable {
    public var isAvailable: Bool
    public var reason: String
}

public struct PermissionResult: Codable, Equatable {
    public var requestedAt: Date
    public var requestedTypes: [String]
    /// Types this iOS version / device does not offer at all.
    public var unavailableTypes: [String]
    public var completed: Bool
    public var note: String
}

public struct HealthTypeDiscovery: Identifiable {
    public enum State: String { case hasData, noReadableData, unavailable }
    public var id: String { descriptor.rawIdentifier }
    public var descriptor: HealthTypeDescriptor
    public var state: State
    public var latestSample: HealthSample?
    /// Samples in the last `recentDays` (see `discoverAvailableHealthTypes`).
    public var recentCount: Int
    public var recentDays: Int
    public var sources: [String]
}

public struct HistoricalFetchResult {
    public var range: DateRange
    public var samples: [HealthSample] = []
    /// One sample per day for cumulative types, from HealthKit's statistics engine (sources merged).
    public var dailyStatistics: [HealthSample] = []
    public var countsByType: [String: Int] = [:]
    public var unavailableTypes: [String] = []
    public var emptyTypes: [String] = []
    public var errors: [String: String] = [:]
    public var startedAt = Date()
    public var finishedAt: Date?
}

public enum HealthExportFormat: String, CaseIterable, Identifiable {
    case json, csv
    public var id: String { rawValue }
}

public enum HealthKitManagerError: LocalizedError {
    case notAvailable
    case typeUnavailable(String)
    case notAQuantityType(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "HealthKit is not available on this device."
        case .typeUnavailable(let t): return "HealthKit type not available on this iOS version: \(t)"
        case .notAQuantityType(let t): return "Daily statistics need a quantity type: \(t)"
        }
    }
}

#if canImport(HealthKit)

/// Reads Apple Health data for the test harness and for Matthew's app.
///
/// Public surface (all read-only; nothing is ever written to HealthKit):
/// `checkHealthKitAvailability`, `requestHealthPermissions`, `discoverAvailableHealthTypes`,
/// `fetchHistoricalSamples`, `fetchAllAvailableHistoricalData`, `fetchRecentSamples`, `fetchWorkouts`,
/// `fetchDailyStatistics`, `generateHealthDataSummary`, `exportHealthData`, `importAppleHealthXML`.
///
/// HealthKit never tells an app whether *read* access was denied: a denied type looks exactly like an
/// empty one. Reports therefore say "no readable data (empty or not authorised)", not "denied".
@MainActor
public final class HealthKitManager: ObservableObject {

    public let store: HKHealthStore?
    public var calendar = Calendar.current
    /// Historical fetches run in chunks of this many days so a year of heart-rate samples does not
    /// come back as one giant array from a single query.
    public var chunkDays = 7

    @Published public private(set) var permissionResult: PermissionResult?
    @Published public private(set) var lastProgress: String = ""

    public init() {
        store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    }

    // MARK: Availability and permissions

    public func checkHealthKitAvailability() -> HealthKitAvailability {
        if !HKHealthStore.isHealthDataAvailable() {
            return HealthKitAvailability(isAvailable: false, reason: "HKHealthStore.isHealthDataAvailable() is false (iPad or simulator without Health).")
        }
        return HealthKitAvailability(isAvailable: true, reason: "HealthKit store available.")
    }

    /// Asks for read access to every type in the catalog that exists on this iOS version.
    public func requestHealthPermissions(types: [HealthTypeDescriptor] = HealthTypeCatalog.all) async throws -> PermissionResult {
        guard let store else { throw HealthKitManagerError.notAvailable }
        var readTypes = Set<HKObjectType>()
        var unavailable: [String] = []
        for d in types {
            if let t = HealthTypeCatalog.objectType(for: d) { readTypes.insert(t) } else { unavailable.append(d.rawIdentifier) }
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        let result = PermissionResult(
            requestedAt: Date(), requestedTypes: types.map { $0.rawIdentifier }.filter { !unavailable.contains($0) },
            unavailableTypes: unavailable, completed: true,
            note: "HealthKit does not reveal read denials. Types the person did not allow will simply return no samples.")
        permissionResult = result
        return result
    }

    // MARK: Discovery

    /// For every catalog type: whether it exists here, the latest readable sample ever, its source, and
    /// how many samples exist in the last `recentDays`. Counting the whole history would mean fetching
    /// it; use `fetchAllAvailableHistoricalData` for that.
    public func discoverAvailableHealthTypes(recentDays: Int = 30,
                                             types: [HealthTypeDescriptor] = HealthTypeCatalog.all) async -> [HealthTypeDiscovery] {
        guard let store else {
            return types.map { HealthTypeDiscovery(descriptor: $0, state: .unavailable, latestSample: nil, recentCount: 0, recentDays: recentDays, sources: []) }
        }
        var out: [HealthTypeDiscovery] = []
        let now = Date()
        let recentStart = calendar.date(byAdding: .day, value: -recentDays, to: now) ?? now
        for d in types {
            guard let sampleType = HealthTypeCatalog.sampleType(for: d) else {
                out.append(HealthTypeDiscovery(descriptor: d, state: .unavailable, latestSample: nil, recentCount: 0, recentDays: recentDays, sources: []))
                continue
            }
            lastProgress = "Discovering \(d.displayName)"
            do {
                let latestRaw = try await runSampleQuery(store: store, type: sampleType, predicate: nil, limit: 1, ascending: false)
                let latest = latestRaw.first.flatMap { Self.convert($0, descriptor: d) }
                let pred = HKQuery.predicateForSamples(withStart: recentStart, end: now, options: [])
                let recent = try await runSampleQuery(store: store, type: sampleType, predicate: pred, limit: HKObjectQueryNoLimit, ascending: true)
                let sources = Set(recent.map { $0.sourceRevision.source.name }).union(latestRaw.map { $0.sourceRevision.source.name })
                out.append(HealthTypeDiscovery(descriptor: d, state: latest == nil ? .noReadableData : .hasData,
                                               latestSample: latest, recentCount: recent.count, recentDays: recentDays,
                                               sources: sources.sorted()))
            } catch {
                out.append(HealthTypeDiscovery(descriptor: d, state: .noReadableData, latestSample: nil, recentCount: 0, recentDays: recentDays, sources: []))
            }
        }
        lastProgress = ""
        return out
    }

    // MARK: Fetching

    /// Every sample of one type between two dates, oldest first, fetched in `chunkDays` pieces.
    public func fetchHistoricalSamples(type d: HealthTypeDescriptor, from: Date, to: Date,
                                       progress: ((Int) -> Void)? = nil) async throws -> [HealthSample] {
        guard let store else { throw HealthKitManagerError.notAvailable }
        guard let sampleType = HealthTypeCatalog.sampleType(for: d) else { throw HealthKitManagerError.typeUnavailable(d.rawIdentifier) }
        var out: [HealthSample] = []
        var cursor = from
        while cursor < to {
            try Task.checkCancellation()
            let next = min(to, calendar.date(byAdding: .day, value: chunkDays, to: cursor) ?? to)
            // strictStartDate keeps a sample in exactly one chunk.
            let pred = HKQuery.predicateForSamples(withStart: cursor, end: next, options: [.strictStartDate])
            let raw = try await runSampleQuery(store: store, type: sampleType, predicate: pred, limit: HKObjectQueryNoLimit, ascending: true)
            for s in raw { if let c = Self.convert(s, descriptor: d) { out.append(c) } }
            progress?(out.count)
            lastProgress = "\(d.displayName): \(out.count) samples"
            cursor = next
        }
        return out
    }

    /// Reads every available type in the range. Never throws: per-type errors are collected.
    public func fetchAllAvailableHistoricalData(from: Date, to: Date,
                                                types: [HealthTypeDescriptor] = HealthTypeCatalog.all,
                                                progress: ((String) -> Void)? = nil) async -> HistoricalFetchResult {
        var result = HistoricalFetchResult(range: DateRange(start: from, end: to))
        guard store != nil else {
            result.unavailableTypes = types.map { $0.rawIdentifier }
            result.finishedAt = Date()
            return result
        }
        for d in types {
            if Task.isCancelled { break }
            guard HealthTypeCatalog.sampleType(for: d) != nil else { result.unavailableTypes.append(d.rawIdentifier); continue }
            progress?("Reading \(d.displayName)…")
            do {
                let samples: [HealthSample]
                if d.kind == .workout {
                    samples = try await fetchWorkouts(from: from, to: to)
                } else {
                    samples = try await fetchHistoricalSamples(type: d, from: from, to: to)
                }
                if samples.isEmpty {
                    result.emptyTypes.append(d.rawIdentifier)
                } else {
                    result.samples.append(contentsOf: samples)
                    result.countsByType[d.rawIdentifier] = samples.count
                    if d.isCumulative, d.kind == .quantity {
                        let daily = try await fetchDailyStatistics(type: d, from: from, to: to)
                        result.dailyStatistics.append(contentsOf: daily)
                    }
                }
            } catch {
                result.errors[d.rawIdentifier] = error.localizedDescription
            }
        }
        result.finishedAt = Date()
        lastProgress = ""
        return result
    }

    /// The newest `limit` samples of a type, newest first.
    public func fetchRecentSamples(type d: HealthTypeDescriptor, limit: Int = 50) async throws -> [HealthSample] {
        guard let store else { throw HealthKitManagerError.notAvailable }
        guard let sampleType = HealthTypeCatalog.sampleType(for: d) else { throw HealthKitManagerError.typeUnavailable(d.rawIdentifier) }
        let raw = try await runSampleQuery(store: store, type: sampleType, predicate: nil, limit: limit, ascending: false)
        return raw.compactMap { Self.convert($0, descriptor: d) }
    }

    public func fetchWorkouts(from: Date, to: Date) async throws -> [HealthSample] {
        guard let store else { throw HealthKitManagerError.notAvailable }
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let raw = try await runSampleQuery(store: store, type: .workoutType(), predicate: pred, limit: HKObjectQueryNoLimit, ascending: true)
        return raw.compactMap { Self.convert($0, descriptor: HealthTypeCatalog.workout) }
    }

    /// Daily totals for a cumulative quantity (steps, energy, distance) computed by HealthKit, which
    /// merges overlapping sources (iPhone + Watch) instead of double counting them.
    public func fetchDailyStatistics(type d: HealthTypeDescriptor, from: Date, to: Date) async throws -> [HealthSample] {
        guard let store else { throw HealthKitManagerError.notAvailable }
        guard let qt = HealthTypeCatalog.objectType(for: d) as? HKQuantityType else { throw HealthKitManagerError.notAQuantityType(d.rawIdentifier) }
        guard let unit = HealthTypeCatalog.unit(for: d) else { throw HealthKitManagerError.typeUnavailable(d.rawIdentifier) }
        let anchor = calendar.startOfDay(for: from)
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let calendar = self.calendar
        let typeID = d.rawIdentifier, display = d.displayName, unitString = d.unitString
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: qt, quantitySamplePredicate: pred, options: .cumulativeSum,
                                                anchorDate: anchor, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                var out: [HealthSample] = []
                collection?.enumerateStatistics(from: from, to: to) { stats, _ in
                    guard let sum = stats.sumQuantity() else { return }
                    let sources = (stats.sources ?? []).map { $0.name }.sorted()
                    let dayKey = LocalStatistics.dayKey(stats.startDate, calendar: calendar)
                    out.append(HealthSample(
                        id: "daily-\(typeID)-\(dayKey)", kind: .quantity, typeIdentifier: typeID, displayName: display,
                        startDate: stats.startDate, endDate: stats.endDate, value: sum.doubleValue(for: unit), unit: unitString,
                        sourceName: sources.joined(separator: "+"),
                        metadata: ["aggregate": .string("daily_cumulative_sum"), "sources": .array(sources.map { .string($0) })],
                        origin: .derived))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    // MARK: Summary, export, import

    public func generateHealthDataSummary(samples: [HealthSample], dailyStatistics: [HealthSample] = [],
                                          range: DateRange, unavailableTypes: [String] = [],
                                          emptyTypes: [String] = []) -> HealthDataSummary {
        HealthSummaryBuilder(range: range, calendar: calendar)
            .build(samples: samples, dailyStatistics: dailyStatistics, unavailableTypes: unavailableTypes, emptyTypesHint: emptyTypes)
    }

    /// Writes samples (and the summary, for JSON) to a file in the app's Documents/HKGeminiExports folder.
    @discardableResult
    public func exportHealthData(samples: [HealthSample], summary: HealthDataSummary?, format: HealthExportFormat,
                                 fileStem: String = "health-data") throws -> URL {
        switch format {
        case .json:
            struct ExportBundle: Encodable { var samples: [HealthSample]; var summary: HealthDataSummary? }
            return try FileExport.writeJSON(ExportBundle(samples: samples, summary: summary), name: "\(fileStem).json")
        case .csv:
            return try FileExport.writeCSV(rows: Self.csvRows(samples), name: "\(fileStem).csv")
        }
    }

    public func importAppleHealthXML(file: URL, range: DateRange? = nil, onlyKnownTypes: Bool = false,
                                     progress: ((Int) -> Void)? = nil) async throws -> (samples: [HealthSample], result: AppleHealthXMLImporter.Result) {
        let needsStop = file.startAccessingSecurityScopedResource()
        defer { if needsStop { file.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .userInitiated) {
            var collected: [HealthSample] = []
            collected.reserveCapacity(100_000)
            let importer = AppleHealthXMLImporter(range: range, onlyKnownTypes: onlyKnownTypes,
                                                  isCancelled: { Task.isCancelled }, progress: progress) { collected.append($0) }
            let result = try importer.run(file: file)
            return (collected, result)
        }.value
    }

    // MARK: Internals

    nonisolated private func runSampleQuery(store: HKHealthStore, type: HKSampleType, predicate: NSPredicate?, limit: Int,
                                            ascending: Bool) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: samples ?? []) }
            }
            store.execute(q)
        }
    }

    nonisolated static func convert(_ s: HKSample, descriptor d: HealthTypeDescriptor) -> HealthSample? {
        var meta: [String: JSONValue] = [:]
        for (k, v) in s.metadata ?? [:] {
            if let q = v as? HKQuantity { meta[k] = .string(q.description) }
            else if let date = v as? Date { meta[k] = .string(ISO8601.string(from: date)) }
            else { meta[k] = JSONValue(v) }
        }
        var out = HealthSample(
            id: s.uuid.uuidString, kind: .quantity, typeIdentifier: d.rawIdentifier, displayName: d.displayName,
            startDate: s.startDate, endDate: s.endDate, unit: d.unitString,
            sourceName: s.sourceRevision.source.name, sourceBundleIdentifier: s.sourceRevision.source.bundleIdentifier,
            sourceVersion: s.sourceRevision.version, deviceName: s.device?.name, deviceModel: s.device?.model,
            metadata: meta, origin: .healthKit)

        if let q = s as? HKQuantitySample {
            guard let unit = HealthTypeCatalog.unit(for: d), q.quantity.is(compatibleWith: unit) else { return nil }
            out.value = q.quantity.doubleValue(for: unit)
        } else if let c = s as? HKCategorySample {
            out.kind = .category
            out.unit = nil
            out.categoryValue = c.value
            out.categoryLabel = HealthTypeCatalog.categoryLabel(typeIdentifier: d.rawIdentifier, value: c.value)
        } else if let w = s as? HKWorkout {
            out.kind = .workout
            out.value = w.duration
            out.unit = "s"
            out.workoutActivityType = HealthTypeCatalog.workoutActivityName(w.workoutActivityType)
            if let e = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
                out.workoutTotalEnergyKcal = e.doubleValue(for: .kilocalorie())
            }
            if let dist = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()
                ?? w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity() {
                out.workoutTotalDistanceM = dist.doubleValue(for: .meter())
            }
        } else {
            return nil
        }
        return out
    }

    nonisolated static func csvRows(_ samples: [HealthSample]) -> [[String]] {
        var rows: [[String]] = [["id", "kind", "type", "display_name", "start", "end", "value", "unit", "category_value",
                                 "category_label", "source", "source_bundle", "device", "origin", "workout_activity",
                                 "workout_kcal", "workout_distance_m"]]
        for s in samples {
            rows.append([s.id, s.kind.rawValue, s.typeIdentifier, s.displayName, ISO8601.string(from: s.startDate),
                         ISO8601.string(from: s.endDate), s.value.map { "\($0)" } ?? "", s.unit ?? "",
                         s.categoryValue.map { String($0) } ?? "", s.categoryLabel ?? "", s.sourceName ?? "",
                         s.sourceBundleIdentifier ?? "", s.deviceName ?? "", s.origin.rawValue, s.workoutActivityType ?? "",
                         s.workoutTotalEnergyKcal.map { "\($0)" } ?? "", s.workoutTotalDistanceM.map { "\($0)" } ?? ""])
        }
        return rows
    }
}

#endif
