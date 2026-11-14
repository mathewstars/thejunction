import SwiftUI
import UniformTypeIdentifiers

struct HealthKitScreen: View {
    @EnvironmentObject var state: AppState
    @State private var showXMLImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                availabilitySection
                actionsSection
                if let r = state.fetchResult { fetchResultSection(r) }
                if let x = state.xmlResult { xmlSection(x) }
                if let s = state.healthSummary { metricsSection(s) }
                if !state.discoveries.isEmpty { discoverySection }
            }
            .navigationTitle("HealthKit")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gear") } } }
            .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
            .fileImporter(isPresented: $showXMLImporter, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first { Task { await state.importXML(u) } }
            }
        }
    }

    private var availabilitySection: some View {
        Section("Availability") {
            let a = state.health.checkHealthKitAvailability()
            HStack { Text("HealthKit"); Spacer(); StatusBadge(text: a.isAvailable ? "available" : "unavailable", tone: a.isAvailable ? .good : .bad) }
            Text(a.reason).font(.caption).foregroundStyle(.secondary)
            if let p = state.health.permissionResult {
                KV("Permission requested", p.requestedAt)
                KV("Types requested", p.requestedTypes.count)
                KV("Types not on this iOS", p.unavailableTypes.count)
                Text(p.note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Request Health permissions") { Task { await state.requestPermissions() } }
            Button("Discover available types (latest sample, last 30 days count)") { Task { await state.discover() } }
            DatePicker("From", selection: Binding(get: { state.healthRange.start }, set: { state.healthRange.start = $0 }), displayedComponents: .date)
            DatePicker("To", selection: Binding(get: { state.healthRange.end }, set: { state.healthRange.end = $0 }), displayedComponents: .date)
            Button("Fetch historical samples for the range") { Task { await state.fetchHistory() } }
            Button("Import Apple Health export.xml") { showXMLImporter = true }
            HStack {
                Button("Export JSON") { state.exportHealth(.json) }.disabled(state.healthSamples.isEmpty)
                Spacer()
                Button("Export CSV") { state.exportHealth(.csv) }.disabled(state.healthSamples.isEmpty)
            }
            ExportFooter()
        }
        .disabled(state.busy != nil)
    }

    private func fetchResultSection(_ r: HistoricalFetchResult) -> some View {
        Section("Last HealthKit fetch") {
            KV("Samples", r.samples.count)
            KV("Daily statistics rows", r.dailyStatistics.count)
            KV("Types with data", r.countsByType.count)
            KV("Empty or not authorised", r.emptyTypes.count)
            KV("Not on this iOS", r.unavailableTypes.count)
            if !r.errors.isEmpty {
                ForEach(r.errors.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    VStack(alignment: .leading) { Text(CombinedDatasetBuilder.metricKey(k)).font(.caption.bold()); Text(v).font(.caption2) }
                }
            }
            if let f = r.finishedAt { KV("Took", f.timeIntervalSince(r.startedAt), digits: 1, unit: "s") }
        }
    }

    private func xmlSection(_ x: AppleHealthXMLImporter.Result) -> some View {
        Section("Apple Health XML import") {
            KV("Records", x.recordCount)
            KV("Workouts", x.workoutCount)
            KV("Types", x.countsByType.count)
            KV("Unknown types skipped/kept", x.skippedUnknownTypes.values.reduce(0, +))
            KV("First", x.firstDate)
            KV("Last", x.lastDate)
            KV("Export date", x.exportDate)
            KV("File size", Fmt.bytes(Int(x.bytesRead)))
            ForEach(x.parseErrors.prefix(3), id: \.self) { Text($0).font(.caption2).foregroundStyle(.red) }
        }
    }

    private func metricsSection(_ s: HealthDataSummary) -> some View {
        Section("Metrics in summary (\(s.metrics.count)) · \(s.totalSamples) samples") {
            ForEach(s.metrics) { m in
                NavigationLink { MetricDetail(metric: m) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.displayName).font(.callout)
                            Spacer()
                            Text("\(m.sampleCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            if let l = m.lastDate { Text(Fmt.dateTime(l)) }
                            Text(m.sources.joined(separator: ", ")).lineLimit(1)
                            if let c = m.coverage { Text("cov \(Fmt.pct(c.coverageFraction))") }
                            if let f = m.samplingFrequency, !f.isContinuous { StatusBadge(text: "sparse", tone: .neutral) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !s.emptyTypes.isEmpty {
                DisclosureGroup("Empty or not authorised (\(s.emptyTypes.count))") {
                    ForEach(s.emptyTypes, id: \.self) { Text(CombinedDatasetBuilder.metricKey($0)).font(.caption) }
                }
            }
            if !s.unavailableTypes.isEmpty {
                DisclosureGroup("Unavailable on this device (\(s.unavailableTypes.count))") {
                    ForEach(s.unavailableTypes, id: \.self) { Text(CombinedDatasetBuilder.metricKey($0)).font(.caption) }
                }
            }
            DisclosureGroup("Notes (\(s.notes.count))") { ForEach(s.notes, id: \.self) { Text($0).font(.caption) } }
        }
    }

    private var discoverySection: some View {
        Section("Discovered types") {
            ForEach(HealthTypeDescriptor.Group.allCases, id: \.self) { g in
                let items = state.discoveries.filter { $0.descriptor.group == g }
                if !items.isEmpty {
                    DisclosureGroup("\(g.rawValue) (\(items.filter { $0.state == .hasData }.count)/\(items.count) with data)") {
                        ForEach(items) { d in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.descriptor.displayName).font(.callout)
                                    if let l = d.latestSample {
                                        Text("latest \(Fmt.dateTime(l.endDate)) · \(l.sourceName ?? "?")").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    StatusBadge(text: badgeText(d.state), tone: d.state == .hasData ? .good : (d.state == .unavailable ? .bad : .neutral))
                                    Text("\(d.recentCount) in \(d.recentDays) d").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func badgeText(_ s: HealthTypeDiscovery.State) -> String {
        switch s { case .hasData: return "data"; case .noReadableData: return "none/denied"; case .unavailable: return "n/a" }
    }
}

struct MetricDetail: View {
    let metric: HealthMetricSummary
    var body: some View {
        List {
            Section {
                DailyChart(daily: metric.daily, unit: metric.unit, bars: metric.aggregation == .sum || metric.aggregation == .count || metric.aggregation == .durationHours)
            }
            Section("Identity") {
                KV("Type", metric.typeIdentifier)
                KV("Category", metric.category)
                KV("Unit", metric.unit ?? "–")
                KV("Daily aggregation", metric.aggregation.rawValue)
                KV("Samples", metric.sampleCount)
                KV("First", metric.firstDate)
                KV("Last", metric.lastDate)
                KV("Sources", metric.sources.joined(separator: ", "))
            }
            if let st = metric.statistics { statsSection("Per-sample statistics", st) }
            if let st = metric.dailyStatistics { statsSection("Per-day statistics", st) }
            if let f = metric.samplingFrequency {
                Section("Sampling") {
                    KV("Median interval", f.medianIntervalSeconds.map { $0 / 60 }, digits: 1, unit: "min")
                    KV("Samples per day", f.samplesPerDay, digits: 1)
                    KV("Largest gap", f.largestGapSeconds.map { $0 / 3600 }, digits: 1, unit: "h")
                    KV("Largest gap starts", f.largestGapStart)
                    Text(f.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let c = metric.coverage {
                Section("Coverage") {
                    KV("Days in range", c.daysInRange)
                    KV("Days with data", c.daysWithData)
                    KV("Coverage", Fmt.pct(c.coverageFraction))
                    if !c.missingDays.isEmpty { Text("Missing: " + c.missingDays.prefix(20).joined(separator: ", ") + (c.missingDays.count > 20 ? "…" : "")).font(.caption2) }
                }
            }
            if let o = metric.outliers, o.outlierCount > 0 {
                Section("Outlier days (\(o.method) > \(Fmt.num(o.threshold, 1)))") { Text(o.outlierDays.joined(separator: ", ")).font(.caption) }
            }
            if let l = metric.longitudinalChange {
                Section("Change over the period") {
                    KV("First period", l.firstPeriod); KV("Median then", l.firstPeriodMedian)
                    KV("Last period", l.lastPeriod); KV("Median now", l.lastPeriodMedian)
                    KV("Relative change", l.relativeChange.map { $0 * 100 }, digits: 1, unit: "%")
                    KV("Slope per day", l.slopePerDay, digits: 4)
                }
            }
            if let b = metric.categoryBreakdown {
                Section("Breakdown") { ForEach(b.sorted(by: { $0.key < $1.key }), id: \.key) { KV($0.key, $0.value) } }
            }
            Section("Weekly") {
                ForEach(metric.weekly) { w in KV(w.weekStart, w.mean, digits: 2, unit: metric.unit) }
            }
        }
        .navigationTitle(metric.displayName)
    }

    private func statsSection(_ title: String, _ st: DescriptiveStatistics) -> some View {
        Section(title) {
            KV("n", st.count); KV("mean", st.mean); KV("median", st.median); KV("sd", st.standardDeviation)
            KV("min", st.minimum); KV("p5", st.percentile5); KV("p25", st.percentile25); KV("p75", st.percentile75); KV("p95", st.percentile95); KV("max", st.maximum)
            KV("IQR", st.interquartileRange); KV("MAD", st.medianAbsoluteDeviation)
        }
    }
}
