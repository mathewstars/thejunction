import Foundation
import SwiftUI

/// Everything the four screens share. Owns the managers and the in-memory data; nothing is persisted
/// between launches except settings (UserDefaults) and the proxy token (Keychain).
@MainActor
final class AppState: ObservableObject {

    let health = HealthKitManager()
    let gemini = GeminiAnalyzer()
    let importer = ARKitDatasetImporter()
    let calendar = Calendar.current

    // HealthKit
    @Published var healthRange: DateRange
    @Published var healthSamples: [HealthSample] = []
    @Published var healthDailyStats: [HealthSample] = []
    @Published var healthSummary: HealthDataSummary?
    @Published var discoveries: [HealthTypeDiscovery] = []
    @Published var fetchResult: HistoricalFetchResult?
    @Published var xmlResult: AppleHealthXMLImporter.Result?

    // ARKit
    @Published var arKitSessions: [ARKitSession] = []
    @Published var geometry: [String: ARKitGeometryData] = [:]
    /// Cache of per-session summaries. Not @Published on purpose: it is filled lazily from view bodies.
    var arKitSummaries: [String: ARKitSessionSummary] = [:]
    @Published var selectedSessionIDs: Set<String> = []

    // Combined
    @Published var combined: CombinedDataset?
    @Published var baseline: BaselineProfile?
    @Published var aggregationWindowSeconds: Double = 3600

    // UI state
    @Published var busy: String?
    @Published var lastError: String?
    @Published var lastExport: URL?
    @Published var pendingRequest: GeminiAnalysisRequest?

    init() {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -90, to: end) ?? end
        healthRange = DateRange(start: start, end: end)
    }

    // MARK: HealthKit

    func requestPermissions() async {
        await perform("Requesting Health permissions") { _ = try await self.health.requestHealthPermissions() }
    }

    func discover() async {
        await perform("Discovering types") { self.discoveries = await self.health.discoverAvailableHealthTypes() }
    }

    func fetchHistory() async {
        await perform("Reading Health history") {
            let r = await self.health.fetchAllAvailableHistoricalData(from: self.healthRange.start, to: self.healthRange.end) { msg in
                Task { @MainActor in self.busy = msg }
            }
            self.fetchResult = r
            // Replace HealthKit-origin samples only; keep XML imports.
            self.healthSamples.removeAll { $0.origin == .healthKit }
            self.healthSamples.append(contentsOf: r.samples)
            self.healthDailyStats = r.dailyStatistics
            self.rebuildHealthSummary()
        }
    }

    func importXML(_ url: URL) async {
        await perform("Importing Apple Health XML") {
            let (samples, result) = try await self.health.importAppleHealthXML(file: url, range: nil) { n in
                Task { @MainActor in self.busy = "Importing Apple Health XML: \(n) records" }
            }
            self.xmlResult = result
            self.healthSamples.removeAll { $0.origin == .appleHealthXML }
            self.healthSamples.append(contentsOf: samples)
            if let f = result.firstDate, let l = result.lastDate, self.healthSamples.filter({ $0.origin == .healthKit }).isEmpty {
                self.healthRange = DateRange(start: f, end: l)
            }
            self.rebuildHealthSummary()
        }
    }

    func rebuildHealthSummary() {
        let unavailable = fetchResult?.unavailableTypes ?? []
        let empty = fetchResult?.emptyTypes ?? []
        healthSummary = health.generateHealthDataSummary(samples: healthSamples, dailyStatistics: healthDailyStats, range: healthRange,
                                                         unavailableTypes: unavailable, emptyTypes: empty)
    }

    func exportHealth(_ format: HealthExportFormat) {
        do { lastExport = try health.exportHealthData(samples: healthSamples, summary: healthSummary, format: format) }
        catch { lastError = error.localizedDescription }
    }

    // MARK: ARKit

    func importCSV(_ url: URL) async {
        await perform("Importing \(url.lastPathComponent)") {
            let session = try await Task.detached { try self.importer.importARKitCSV(file: url) }.value
            self.arKitSessions.removeAll { $0.id == session.id }
            self.arKitSessions.append(session)
            self.selectedSessionIDs.insert(session.id)
            self.arKitSummaries[session.id] = nil
        }
    }

    func importSessionJSON(_ url: URL, into sessionID: String) async {
        await perform("Attaching session.json") {
            let manifest = try self.importer.importSessionJSON(file: url)
            guard let i = self.arKitSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            var s = self.arKitSessions[i]
            let oldID = s.id
            self.importer.attach(manifest: manifest, fileName: url.lastPathComponent, to: &s)
            self.arKitSessions[i] = s
            if s.id != oldID {
                self.selectedSessionIDs.remove(oldID); self.selectedSessionIDs.insert(s.id)
                self.geometry[s.id] = self.geometry.removeValue(forKey: oldID)
            }
            self.arKitSummaries[s.id] = nil
        }
    }

    func importGeometry(_ url: URL, into sessionID: String) async {
        await perform("Reading geometry") {
            let g = try await Task.detached { try self.importer.importGeometryFile(file: url) }.value
            guard let i = self.arKitSessions.firstIndex(where: { $0.id == sessionID }) else { return }
            var s = self.arKitSessions[i]
            self.importer.attach(geometry: g, fileName: url.lastPathComponent, to: &s)
            self.arKitSessions[i] = s
            self.geometry[s.id] = g
            self.arKitSummaries[s.id] = nil
        }
    }

    func importSessionFolder(_ url: URL) async {
        await perform("Importing folder \(url.lastPathComponent)") {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let (session, _) = try await Task.detached { try self.importer.importSessionFolder(url, includeGeometry: false) }.value
            self.arKitSessions.removeAll { $0.id == session.id }
            self.arKitSessions.append(session)
            self.selectedSessionIDs.insert(session.id)
        }
    }

    func removeSession(_ id: String) {
        arKitSessions.removeAll { $0.id == id }
        geometry[id] = nil
        arKitSummaries[id] = nil
        selectedSessionIDs.remove(id)
    }

    func summary(for session: ARKitSession) -> ARKitSessionSummary {
        if let s = arKitSummaries[session.id] { return s }
        let s = importer.generateARKitSummary(session, geometry: geometry[session.id])
        arKitSummaries[session.id] = s
        return s
    }

    func selectedSummaries() -> [ARKitSessionSummary] {
        arKitSessions.filter { selectedSessionIDs.contains($0.id) }.map { summary(for: $0) }
    }

    func exportNormalized(_ session: ARKitSession) {
        do { lastExport = try importer.exportNormalizedARKitData(session) } catch { lastError = error.localizedDescription }
    }

    // MARK: Combined

    func buildCombined() async {
        await perform("Aligning and joining") {
            guard let hs = self.healthSummary else { throw AppError.message("Fetch or import Health data first.") }
            let summaries = self.selectedSummaries()
            let baseline = BaselineBuilder(calendar: self.calendar).build(health: hs, arKit: summaries)
            self.baseline = baseline
            var ds = CombinedDatasetBuilder(calendar: self.calendar, aggregationWindowSeconds: self.aggregationWindowSeconds)
                .buildCombinedDataset(healthData: hs, arKitData: summaries, healthSamples: self.healthSamples, baseline: baseline)
            ds.alignments = self.arKitSessions.filter { self.selectedSessionIDs.contains($0.id) }.compactMap { $0.alignment }
            self.combined = ds
        }
    }

    func exportCombined() {
        guard let ds = combined else { return }
        do { lastExport = try FileExport.writeJSON(ds, name: "combined-dataset.json") } catch { lastError = error.localizedDescription }
    }

    func exportReport(_ response: GeminiAnalysisResponse) {
        guard let req = gemini.requests.first(where: { $0.id == response.requestID }) else { return }
        struct Report: Encodable { var request: GeminiAnalysisRequest; var response: GeminiAnalysisResponse }
        do { lastExport = try FileExport.writeJSON(Report(request: req, response: response), name: "gemini-\(response.experiment.rawValue)-report.json") }
        catch { lastError = error.localizedDescription }
    }

    // MARK: Gemini (consent first)

    /// Builds the request and parks it for the consent sheet. Nothing is sent here.
    func prepare(_ experiment: AnalysisExperiment) {
        do {
            switch experiment {
            case .connectionTest:
                pendingRequest = gemini.buildRequest(experiment: .connectionTest, payload: .object(["ping": .string("ok")]), dataCategories: [], range: nil)
            case .healthKitOnly:
                guard let hs = healthSummary else { throw AppError.message("No Health summary yet.") }
                pendingRequest = try gemini.requestForHealthKit(hs, baseline: baseline)
            case .arKitOnly:
                let s = selectedSummaries()
                guard !s.isEmpty else { throw AppError.message("Import and select at least one ARKit session.") }
                pendingRequest = try gemini.requestForARKit(s)
            case .combined:
                guard let ds = combined else { throw AppError.message("Build the combined dataset first.") }
                pendingRequest = try gemini.requestForCombined(ds)
            case .baseline:
                guard let b = baseline else { throw AppError.message("Build the combined dataset first (it also builds the baseline).") }
                pendingRequest = try gemini.requestForBaseline(b)
            case .geometryFeatures:
                guard let s = selectedSummaries().first(where: { $0.geometryFeatures != nil }) else { throw AppError.message("No selected session has geometry loaded.") }
                pendingRequest = try gemini.requestForGeometry(s)
            case .comparison:
                let ok = gemini.responses.filter { $0.analysis != nil }
                guard ok.count >= 2 else { throw AppError.message("Need two successful analyses to compare.") }
                let p = try gemini.payloadBuilder.comparisonPayload(ok[ok.count - 2].analysis!, ok[ok.count - 1].analysis!)
                pendingRequest = gemini.buildRequest(experiment: .comparison, payload: p, dataCategories: ["Two earlier analyses"], range: nil)
            }
        } catch { lastError = error.localizedDescription }
    }

    /// Called by the consent sheet after the person accepted.
    func sendPending() async {
        guard let req = pendingRequest else { return }
        pendingRequest = nil
        await perform("Waiting for \(req.model)") {
            let r = await self.gemini.send(req, path: req.experiment == .connectionTest ? "/v1/test" : "/v1/analyze")
            if r.status != .success { self.lastError = r.errorMessage ?? r.status.rawValue }
        }
    }

    // MARK: Helpers

    enum AppError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private func perform(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do { try await work() } catch { lastError = error.localizedDescription }
    }
}
