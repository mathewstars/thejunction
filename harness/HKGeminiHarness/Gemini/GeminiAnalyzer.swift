import Foundation

/// Settings for reaching Gemini through our proxy. The Gemini API key lives on the proxy only.
public struct GeminiConfiguration: Codable, Equatable {
    /// e.g. https://lanvi.app/gemini-proxy or http://192.168.1.10:8787 during development.
    public var proxyBaseURL: String
    /// Verified against the official model list on 14 Nov 2026 (gemini-4-carbon, GA, paid tier).
    public var model: String
    /// "low", "medium" or "high" (Gemini 4 thinking_level). Sampling parameters are ignored by Carbon.
    public var thinkingLevel: String
    public var timeoutSeconds: Double
    public var validatorFailsOnUnsupportedNumbers: Bool

    public static let defaultModel = "gemini-4-carbon"

    public init(proxyBaseURL: String = "", model: String = GeminiConfiguration.defaultModel, thinkingLevel: String = "medium",
                timeoutSeconds: Double = 600, validatorFailsOnUnsupportedNumbers: Bool = true) {
        self.proxyBaseURL = proxyBaseURL
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.timeoutSeconds = timeoutSeconds
        self.validatorFailsOnUnsupportedNumbers = validatorFailsOnUnsupportedNumbers
    }

    private static let defaultsKey = "gemini.configuration"
    public static func load() -> GeminiConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let c = try? JSONDecoder().decode(GeminiConfiguration.self, from: data) else { return GeminiConfiguration() }
        return c
    }
    public func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// Talks to the backend proxy, keeps every request and response with timing and token usage, and
/// validates replies against the strict schema.
///
/// Wire format to the proxy (see harness/proxy/README.md):
///   POST {base}/v1/analyze  Authorization: Bearer <proxy token>
///   { request_id, experiment, model, thinking_level, system_instruction, user_prompt, payload, response_schema }
///   → { request_id, status, model, text, usage{prompt_tokens,output_tokens,thought_tokens,total_tokens}, latency_ms, upstream_status, error }
@MainActor
public final class GeminiAnalyzer: ObservableObject {

    @Published public var configuration: GeminiConfiguration
    @Published public private(set) var requests: [GeminiAnalysisRequest] = []
    @Published public private(set) var responses: [GeminiAnalysisResponse] = []
    @Published public private(set) var inFlight = false

    public var payloadBuilder = GeminiPayloadBuilder()
    public static let proxyTokenKey = "proxy.token"

    private let session: URLSession

    public init(configuration: GeminiConfiguration = .load(), session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = configuration.timeoutSeconds
            c.timeoutIntervalForResource = configuration.timeoutSeconds
            c.waitsForConnectivity = true
            self.session = URLSession(configuration: c)
        }
    }

    public var proxyToken: String? {
        get { KeychainStore.get(Self.proxyTokenKey) }
        set { KeychainStore.set(newValue ?? "", for: Self.proxyTokenKey) }
    }

    // MARK: Building requests (no network)

    public func buildRequest(experiment: AnalysisExperiment, payload: JSONValue, dataCategories: [String], range: DateRange?) -> GeminiAnalysisRequest {
        let bytes = (try? JSONValue.encoder(pretty: false).encode(payload).count) ?? 0
        return GeminiAnalysisRequest(
            id: UUID().uuidString, experiment: experiment, model: configuration.model, createdAt: Date(),
            systemInstruction: GeminiPrompts.systemInstruction, userPrompt: GeminiPrompts.userPrompt(for: experiment),
            payload: payload, responseSchema: GeminiSchema.responseSchema(experiment: experiment),
            thinkingLevel: configuration.thinkingLevel, inputDataRange: range, dataCategories: dataCategories, payloadBytes: bytes)
    }

    public func requestForHealthKit(_ summary: HealthDataSummary, baseline: BaselineProfile?) throws -> GeminiAnalysisRequest {
        let (p, cats, range) = try payloadBuilder.healthPayload(summary, baseline: baseline)
        return buildRequest(experiment: .healthKitOnly, payload: p, dataCategories: cats, range: range)
    }

    public func requestForARKit(_ sessions: [ARKitSessionSummary]) throws -> GeminiAnalysisRequest {
        let (p, cats, range) = try payloadBuilder.arKitPayload(sessions)
        return buildRequest(experiment: .arKitOnly, payload: p, dataCategories: cats, range: range)
    }

    public func requestForCombined(_ ds: CombinedDataset) throws -> GeminiAnalysisRequest {
        let (p, cats, range) = try payloadBuilder.combinedPayload(ds)
        return buildRequest(experiment: .combined, payload: p, dataCategories: cats, range: range)
    }

    public func requestForBaseline(_ b: BaselineProfile) throws -> GeminiAnalysisRequest {
        let (p, cats, range) = try payloadBuilder.baselinePayload(b)
        return buildRequest(experiment: .baseline, payload: p, dataCategories: cats, range: range)
    }

    public func requestForGeometry(_ s: ARKitSessionSummary) throws -> GeminiAnalysisRequest {
        let (p, cats, range) = try payloadBuilder.geometryPayload(s)
        return buildRequest(experiment: .geometryFeatures, payload: p, dataCategories: cats, range: range)
    }

    // MARK: The public analysis functions

    /// GET /v1/health on the proxy, then a tiny generation through the model.
    public func testConnection() async -> GeminiAnalysisResponse {
        let req = buildRequest(experiment: .connectionTest, payload: .object(["ping": .string("ok")]), dataCategories: [], range: nil)
        return await send(req, path: "/v1/test")
    }

    public func analyzeHealthKitData(_ summary: HealthDataSummary, baseline: BaselineProfile? = nil) async -> GeminiAnalysisResponse {
        await run { try self.requestForHealthKit(summary, baseline: baseline) }
    }

    public func analyzeARKitData(_ sessions: [ARKitSessionSummary]) async -> GeminiAnalysisResponse {
        await run { try self.requestForARKit(sessions) }
    }

    public func analyzeCombinedDataset(_ ds: CombinedDataset) async -> GeminiAnalysisResponse {
        await run { try self.requestForCombined(ds) }
    }

    public func generatePersonalBaseline(_ b: BaselineProfile) async -> GeminiAnalysisResponse {
        await run { try self.requestForBaseline(b) }
    }

    public func analyzeGeometryFeatures(_ s: ARKitSessionSummary) async -> GeminiAnalysisResponse {
        await run { try self.requestForGeometry(s) }
    }

    /// Deterministic, local comparison of two structured analyses.
    public func compareAnalysisResults(_ a: GeminiAnalysisResponse, with b: GeminiAnalysisResponse) -> AnalysisComparison {
        let oa = a.analysis?.allObservations ?? [], ob = b.analysis?.allObservations ?? []
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
                .split(separator: " ").filter { $0.count > 3 }.joined(separator: " ")
        }
        func similar(_ x: String, _ y: String) -> Bool {
            let sx = Set(norm(x).split(separator: " ")), sy = Set(norm(y).split(separator: " "))
            guard !sx.isEmpty, !sy.isEmpty else { return false }
            return Double(sx.intersection(sy).count) / Double(sx.union(sy).count) >= 0.5
        }
        var shared: [String] = [], onlyA: [String] = [], kindChanges: [String] = []
        var matchedB = Set<Int>()
        for x in oa {
            if let j = ob.indices.first(where: { !matchedB.contains($0) && similar(x.observation, ob[$0].observation) }) {
                matchedB.insert(j); shared.append(x.observation)
                if x.kind != ob[j].kind { kindChanges.append("\(x.observation) — \(x.kind) → \(ob[j].kind)") }
            } else { onlyA.append(x.observation) }
        }
        let onlyB = ob.indices.filter { !matchedB.contains($0) }.map { ob[$0].observation }
        let total = Double(oa.count + ob.count)
        return AnalysisComparison(firstResponseID: a.id, secondResponseID: b.id, sharedObservations: shared, onlyInFirst: onlyA,
                                  onlySecond: onlyB, kindChanges: kindChanges, similarityScore: total > 0 ? 2 * Double(shared.count) / total : 0)
    }

    public func validateResponse(_ rawText: String, request: GeminiAnalysisRequest) -> (StructuredAnalysis?, ResponseValidationReport) {
        var opts = GeminiResponseValidator.Options()
        opts.failOnUnsupportedNumbers = configuration.validatorFailsOnUnsupportedNumbers
        return GeminiResponseValidator.validate(rawText: rawText, request: request, options: opts)
    }

    // MARK: Sending

    private func run(_ make: () throws -> GeminiAnalysisRequest) async -> GeminiAnalysisResponse {
        let req: GeminiAnalysisRequest
        do { req = try make() } catch {
            let now = Date()
            return GeminiAnalysisResponse(id: UUID().uuidString, requestID: "-", experiment: .connectionTest, model: configuration.model,
                                          requestTimestamp: now, responseTimestamp: now, latencyMilliseconds: 0, status: .proxyError,
                                          httpStatus: nil, errorMessage: "Could not build the payload: \(error.localizedDescription)",
                                          usage: nil, rawText: nil, rawProxyResponse: nil, analysis: nil, validation: nil)
        }
        return await send(req)
    }

    /// Sends a prepared request. The UI calls this only after the consent sheet was accepted.
    public func send(_ req: GeminiAnalysisRequest, path: String = "/v1/analyze") async -> GeminiAnalysisResponse {
        requests.append(req)
        inFlight = true
        defer { inFlight = false }
        let started = Date()
        var resp = GeminiAnalysisResponse(id: UUID().uuidString, requestID: req.id, experiment: req.experiment, model: req.model,
                                          requestTimestamp: started, responseTimestamp: started, latencyMilliseconds: 0, status: .networkError,
                                          httpStatus: nil, errorMessage: nil, usage: nil, rawText: nil, rawProxyResponse: nil, analysis: nil, validation: nil)
        defer { responses.append(resp) }

        guard let base = URL(string: configuration.proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)), base.host != nil else {
            resp.status = .proxyError; resp.errorMessage = "Proxy URL is not set. Open Settings."
            resp.responseTimestamp = Date(); return resp
        }
        if base.scheme != "https", !(base.host == "localhost" || base.host?.hasPrefix("192.168.") == true || base.host?.hasPrefix("10.") == true || base.host == "127.0.0.1") {
            resp.status = .proxyError; resp.errorMessage = "Proxy URL must use https (plain http is allowed only for local addresses)."
            resp.responseTimestamp = Date(); return resp
        }
        var url = base
        url.append(path: path.hasPrefix("/") ? String(path.dropFirst()) : path)

        let body: [String: JSONValue] = [
            "request_id": .string(req.id), "experiment": .string(req.experiment.rawValue), "model": .string(req.model),
            "thinking_level": req.thinkingLevel.map { .string($0) } ?? .null,
            "system_instruction": .string(req.systemInstruction), "user_prompt": .string(req.userPrompt),
            "payload": req.payload, "response_schema": req.responseSchema
        ]
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = proxyToken, !token.isEmpty { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        urlRequest.timeoutInterval = configuration.timeoutSeconds
        do { urlRequest.httpBody = try JSONValue.encoder(pretty: false).encode(JSONValue.object(body)) } catch {
            resp.status = .proxyError; resp.errorMessage = "Could not encode request: \(error.localizedDescription)"; resp.responseTimestamp = Date(); return resp
        }

        do {
            let (data, urlResponse) = try await session.data(for: urlRequest)
            let http = urlResponse as? HTTPURLResponse
            resp.responseTimestamp = Date()
            resp.latencyMilliseconds = resp.responseTimestamp.timeIntervalSince(started) * 1000
            resp.httpStatus = http?.statusCode
            let json = try? JSONValue.decoder().decode(JSONValue.self, from: data)
            resp.rawProxyResponse = json
            guard let json else {
                resp.status = .proxyError; resp.errorMessage = "Proxy returned non-JSON (HTTP \(http?.statusCode ?? 0))."; return resp
            }
            if let m = json["model"]?.stringValue { resp.model = m }
            if let u = json["usage"]?.objectValue {
                resp.usage = GeminiUsage(promptTokens: u["prompt_tokens"]?.intValue, outputTokens: u["output_tokens"]?.intValue,
                                         thoughtTokens: u["thought_tokens"]?.intValue, totalTokens: u["total_tokens"]?.intValue)
            }
            if let lat = json["latency_ms"]?.doubleValue, resp.latencyMilliseconds == 0 { resp.latencyMilliseconds = lat }
            let status = json["status"]?.stringValue ?? ""
            guard (http?.statusCode ?? 500) < 300, status == "success", let text = json["text"]?.stringValue else {
                resp.status = (json["upstream_status"]?.intValue ?? 0) >= 400 ? .apiError : .proxyError
                resp.errorMessage = json["error"]?.stringValue ?? "HTTP \(http?.statusCode ?? 0): \(status)"
                return resp
            }
            resp.rawText = text
            let (analysis, report) = validateResponse(text, request: req)
            resp.analysis = analysis
            resp.validation = report
            if analysis == nil { resp.status = .invalidJSON; resp.errorMessage = report.schemaErrors.first?.message }
            else if !report.isValid { resp.status = .schemaRejected; resp.errorMessage = "Rejected by the validator: \(report.schemaErrors.count) schema problem(s), \(report.unsupportedNumbers.filter { $0.severity == "error" }.count) unsupported number(s)." }
            else { resp.status = .success }
        } catch is CancellationError {
            resp.status = .cancelled; resp.responseTimestamp = Date()
        } catch {
            resp.status = .networkError; resp.errorMessage = error.localizedDescription; resp.responseTimestamp = Date()
            resp.latencyMilliseconds = resp.responseTimestamp.timeIntervalSince(started) * 1000
        }
        return resp
    }

    public func clearHistory() { requests.removeAll(); responses.removeAll() }

    /// Writes every request and response of this session to Documents/HKGeminiExports.
    @discardableResult
    public func exportHistory() throws -> URL {
        struct History: Encodable { var requests: [GeminiAnalysisRequest]; var responses: [GeminiAnalysisResponse] }
        return try FileExport.writeJSON(History(requests: requests, responses: responses), name: "gemini-history.json")
    }
}
