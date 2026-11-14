import SwiftUI

struct GeminiExperimentsScreen: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    KV("Proxy", state.gemini.configuration.proxyBaseURL.isEmpty ? "(not set)" : state.gemini.configuration.proxyBaseURL)
                    KV("Model", state.gemini.configuration.model)
                    KV("Thinking", state.gemini.configuration.thinkingLevel)
                    Button("Test API connection") { state.prepare(.connectionTest) }
                }
                Section("Experiments (each shows a consent sheet first)") {
                    Button("A · HealthKit only") { state.prepare(.healthKitOnly) }.disabled(state.healthSummary == nil)
                    Button("B · ARKit only (\(state.selectedSessionIDs.count) selected)") { state.prepare(.arKitOnly) }.disabled(state.selectedSessionIDs.isEmpty)
                    Button("C · Combined HealthKit + ARKit") { state.prepare(.combined) }.disabled(state.combined == nil)
                    Button("Personal baseline") { state.prepare(.baseline) }.disabled(state.baseline == nil)
                    Button("Optional · geometry-derived features") { state.prepare(.geometryFeatures) }.disabled(!state.selectedSessionIDs.contains { state.geometry[$0] != nil })
                    Button("Compare the last two analyses") { state.prepare(.comparison) }.disabled(state.gemini.responses.filter { $0.analysis != nil }.count < 2)
                }
                .disabled(state.busy != nil || state.gemini.inFlight)

                Section("History (\(state.gemini.responses.count))") {
                    ForEach(state.gemini.responses.reversed()) { r in
                        NavigationLink { ResponseDetail(response: r) } label: { responseRow(r) }
                    }
                    if !state.gemini.responses.isEmpty {
                        Button("Export history JSON") { do { state.lastExport = try state.gemini.exportHistory() } catch { state.lastError = error.localizedDescription } }
                        Button("Clear history", role: .destructive) { state.gemini.clearHistory() }
                    }
                }
                ExportFooter()
            }
            .navigationTitle("Gemini")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gear") } } }
            .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
        }
    }

    private func responseRow(_ r: GeminiAnalysisResponse) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(r.experiment.title).font(.callout)
                Spacer()
                StatusBadge(text: r.status.rawValue, tone: r.status == .success ? .good : (r.status == .schemaRejected ? .warn : .bad))
            }
            HStack(spacing: 8) {
                Text(Fmt.dateTime(r.requestTimestamp))
                Text(String(format: "%.1f s", r.latencyMilliseconds / 1000))
                if let u = r.usage { Text("in \(u.promptTokens ?? 0) · think \(u.thoughtTokens ?? 0) · out \(u.outputTokens ?? 0)") }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct ResponseDetail: View {
    @EnvironmentObject var state: AppState
    let response: GeminiAnalysisResponse

    private var request: GeminiAnalysisRequest? { state.gemini.requests.first { $0.id == response.requestID } }

    var body: some View {
        List {
            Section("Request") {
                KV("Experiment", response.experiment.title)
                KV("Model", response.model)
                KV("Request at", response.requestTimestamp)
                KV("Response at", response.responseTimestamp)
                KV("Latency", response.latencyMilliseconds / 1000, digits: 2, unit: "s")
                if let r = request {
                    KV("Payload size", Fmt.bytes(r.payloadBytes))
                    if let range = r.inputDataRange { KV("Data from", range.start); KV("Data to", range.end) }
                    KV("Thinking", r.thinkingLevel ?? "–")
                }
                HStack { Text("Status"); Spacer(); StatusBadge(text: response.status.rawValue, tone: response.status == .success ? .good : .bad) }
                if let h = response.httpStatus { KV("HTTP", h) }
                if let e = response.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
            }
            if let u = response.usage {
                Section("Token usage") {
                    KV("Prompt tokens", u.promptTokens); KV("Thought tokens", u.thoughtTokens); KV("Output tokens", u.outputTokens); KV("Total", u.totalTokens)
                }
            }
            if let v = response.validation {
                Section("Validation") {
                    HStack { Text("Result"); Spacer(); StatusBadge(text: v.isValid ? "accepted" : "rejected", tone: v.isValid ? .good : .bad) }
                    KV("Observations", v.observationCount); KV("Numbers checked", v.checkedNumbers)
                    KV("Schema problems", v.schemaErrors.count); KV("Unsupported numbers", v.unsupportedNumbers.count); KV("Flagged terms", v.forbiddenTerms.count)
                    ForEach(Array((v.schemaErrors + v.unsupportedNumbers + v.forbiddenTerms).prefix(40).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .top) { StatusBadge(text: p.severity, tone: p.severity == "error" ? .bad : .warn); VStack(alignment: .leading) { Text(p.location).font(.caption2.monospaced()); Text(p.message).font(.caption) } }
                    }
                }
            }
            if let a = response.analysis {
                Section("Plain-language explanation") { Text(a.plainLanguageExplanation).font(.callout).textSelection(.enabled) }
                observations("Health observations", a.healthObservations)
                observations("Facial behaviour observations", a.facialBehaviorObservations)
                observations("Cross-modal patterns", a.crossModalPatterns)
                observations("Longitudinal changes", a.longitudinalChanges)
                observations("Potential confounders", a.potentialConfounders)
                if !a.uncertainties.isEmpty { Section("Uncertainties") { ForEach(a.uncertainties, id: \.self) { Text($0).font(.callout) } } }
                if !a.recommendedTracking.isEmpty { Section("Recommended tracking") { ForEach(a.recommendedTracking, id: \.self) { Text($0).font(.callout) } } }
                Section("Baseline summary / data quality") {
                    Text(a.baselineSummary.prettyString()).font(.caption2.monospaced())
                    Text(a.dataQuality.prettyString()).font(.caption2.monospaced())
                }
            }
            Section("Raw") {
                if let r = request {
                    NavigationLink("Request payload JSON") { JSONView(title: "Payload", json: r.payload) }
                    NavigationLink("Response schema sent") { JSONView(title: "Schema", json: r.responseSchema) }
                    NavigationLink("Full request (as sent to proxy)") {
                        JSONView(title: "Request", json: .object(["request_id": .string(r.id), "experiment": .string(r.experiment.rawValue), "model": .string(r.model),
                                                                   "thinking_level": .string(r.thinkingLevel ?? ""), "system_instruction": .string(r.systemInstruction),
                                                                   "user_prompt": .string(r.userPrompt), "payload": r.payload, "response_schema": r.responseSchema]))
                    }
                }
                if let raw = response.rawProxyResponse { NavigationLink("Raw proxy response JSON") { JSONView(title: "Proxy response", json: raw) } }
                if let t = response.rawText {
                    NavigationLink("Raw model text") { ScrollView { Text(t).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle("Model text") }
                }
                Button("Export request + response report") { state.exportReport(response) }
            }
            ExportFooter()
        }
        .navigationTitle("Response")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func observations(_ title: String, _ obs: [AnalysisObservation]) -> some View {
        Section("\(title) (\(obs.count))") {
            ForEach(Array(obs.enumerated()), id: \.offset) { _, o in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { StatusBadge(text: o.kind, tone: o.kind == "direct_observation" ? .good : .neutral); Spacer(); if let t = o.timeRange { Text("\(t.start ?? "") → \(t.end ?? "")").font(.caption2).foregroundStyle(.secondary) } }
                    Text(o.observation).font(.callout)
                    if !o.supportingMeasurements.isEmpty { Text("Evidence: " + o.supportingMeasurements.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                    Text("Quality: \(o.dataQuality)").font(.caption2).foregroundStyle(.secondary)
                    Text("Limits: \(o.limitations)").font(.caption2).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }
}
