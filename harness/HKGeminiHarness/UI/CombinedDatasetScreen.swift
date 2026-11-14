import SwiftUI

struct CombinedDatasetScreen: View {
    @EnvironmentObject var state: AppState
    @State private var healthKey = "HeartRateVariabilitySDNN"
    @State private var facialKey = "facialVariability"

    var body: some View {
        NavigationStack {
            List {
                Section("HealthKit range") {
                    DatePicker("From", selection: Binding(get: { state.healthRange.start }, set: { state.healthRange.start = $0; state.rebuildHealthSummary() }), displayedComponents: .date)
                    DatePicker("To", selection: Binding(get: { state.healthRange.end }, set: { state.healthRange.end = $0; state.rebuildHealthSummary() }), displayedComponents: .date)
                    KV("Health samples loaded", state.healthSamples.count)
                    KV("Metrics in summary", state.healthSummary?.metrics.count ?? 0)
                }
                Section("ARKit sessions") {
                    if state.arKitSessions.isEmpty { Text("Import sessions on the ARKit tab.").foregroundStyle(.secondary) }
                    ForEach(state.arKitSessions) { s in
                        Toggle(isOn: Binding(get: { state.selectedSessionIDs.contains(s.id) },
                                             set: { on in if on { state.selectedSessionIDs.insert(s.id) } else { state.selectedSessionIDs.remove(s.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.id).font(.caption.monospaced())
                                HStack(spacing: 6) {
                                    if let d = s.alignment?.recordingStartWallClock { Text(Fmt.dateTime(d)) } else { Text("no wall clock") }
                                    StatusBadge(text: s.alignment?.method.rawValue ?? "unaligned", tone: (s.alignment?.method ?? .unaligned) == .unaligned ? .bad : .good)
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Build") {
                    Picker("Bin width", selection: $state.aggregationWindowSeconds) {
                        Text("15 min").tag(900.0); Text("1 h").tag(3600.0); Text("1 day").tag(86400.0)
                    }
                    Button("Align timestamps, join, compute baseline and correlations") { Task { await state.buildCombined() } }
                        .disabled(state.healthSummary == nil || state.selectedSessionIDs.isEmpty)
                }
                .disabled(state.busy != nil)

                if let ds = state.combined { datasetSections(ds) }
                ExportFooter()
            }
            .navigationTitle("Combined")
        }
    }

    @ViewBuilder
    private func datasetSections(_ ds: CombinedDataset) -> some View {
        Section("Dataset") {
            KV("Range from", ds.range.start); KV("Range to", ds.range.end)
            KV("Daily rows", ds.dailyRows.count)
            KV("Rows with facial data", ds.dailyRows.filter { !$0.facial.isEmpty }.count)
            KV("Bins", ds.bins.count)
            KV("Correlations computed", ds.correlations.filter { $0.spearmanRho != nil }.count)
            KV("Sessions aligned", ds.alignments.filter { $0.method != .unaligned }.count)
            ForEach(ds.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Button("Export combined dataset JSON") { state.exportCombined() }
            Button("Run Gemini Experiment C") { state.prepare(.combined) }
        }
        Section("Scatter") {
            Picker("Health", selection: $healthKey) {
                ForEach(CombinedDatasetBuilder.healthMetricsForJoin.map(CombinedDatasetBuilder.metricKey), id: \.self) { Text($0).tag($0) }
            }
            Picker("Facial", selection: $facialKey) { ForEach(CombinedDatasetBuilder.facialKeys, id: \.self) { Text($0).tag($0) } }
            ScatterChart(rows: ds.dailyRows, healthKey: healthKey, facialKey: facialKey)
        }
        Section("Correlations (Spearman ρ · Pearson r · paired days)") {
            ForEach(ds.correlations.filter { $0.spearmanRho != nil }.sorted { abs($0.spearmanRho ?? 0) > abs($1.spearmanRho ?? 0) }.prefix(40)) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(c.metricA) × \(c.metricB)\(c.lagDays != 0 ? " (lag \(c.lagDays) d)" : "")").font(.caption.monospaced())
                    Text("ρ \(Fmt.num(c.spearmanRho, 2)) · r \(Fmt.num(c.pearsonR, 2)) · n \(c.pairedPoints)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            let skipped = ds.correlations.filter { $0.spearmanRho == nil }.count
            if skipped > 0 { Text("\(skipped) pairs had too few paired days and were not computed.").font(.caption2).foregroundStyle(.secondary) }
        }
        if let b = ds.baseline {
            Section("Personal baseline (\(b.healthReferences.count) health · \(b.facialReferences.count) facial)") {
                ForEach(b.healthReferences.prefix(30)) { r in referenceRow(r) }
                ForEach(b.facialReferences) { r in referenceRow(r) }
                Text(b.caveat).font(.caption2).foregroundStyle(.secondary)
                Button("Ask Gemini to interpret the baseline") { state.prepare(.baseline) }
            }
        }
        Section("Daily rows (latest 30)") {
            ForEach(ds.dailyRows.suffix(30).reversed()) { r in
                VStack(alignment: .leading, spacing: 1) {
                    HStack { Text(r.day).font(.caption.monospaced()); Spacer(); Text("\(r.facialWindowCount) windows").font(.caption2).foregroundStyle(.secondary) }
                    Text(r.health.sorted(by: { $0.key < $1.key }).map { "\($0.key) \(Fmt.num($0.value, 1))" }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if !r.facial.isEmpty { Text(r.facial.sorted(by: { $0.key < $1.key }).map { "\($0.key) \(Fmt.num($0.value, 3))" }.joined(separator: " · ")).font(.caption2).lineLimit(2) }
                }
            }
        }
    }

    private func referenceRow(_ r: ReferenceRange) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(r.metric).font(.caption.monospaced())
            Text("median \(Fmt.num(r.median, 2)) · usual \(Fmt.num(r.lowerUsual, 2))–\(Fmt.num(r.upperUsual, 2)) · p5–p95 \(Fmt.num(r.percentile5, 2))–\(Fmt.num(r.percentile95, 2)) · \(r.daysCovered) d\(r.unit.map { " · \($0)" } ?? "")")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
