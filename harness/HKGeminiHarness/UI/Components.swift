import SwiftUI
import Charts

// Small, reusable developer-UI pieces. No consumer styling.

struct KV: View {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    init(_ key: String, _ value: Double?, digits: Int = 2, unit: String? = nil) {
        self.key = key
        if let v = value { self.value = String(format: "%.\(digits)f", v) + (unit.map { " \($0)" } ?? "") } else { self.value = "–" }
    }
    init(_ key: String, _ value: Int?) { self.key = key; self.value = value.map(String.init) ?? "–" }
    init(_ key: String, _ date: Date?) { self.key = key; self.value = date.map { Fmt.dateTime($0) } ?? "–" }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.body.monospacedDigit()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

enum Fmt {
    static let dateTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    static func dateTime(_ d: Date) -> String { dateTime.string(from: d) }
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    static func pct(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
    static func num(_ x: Double?, _ digits: Int = 2) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "–" }
}

struct StatusBadge: View {
    let text: String
    let tone: Tone
    enum Tone { case good, warn, bad, neutral }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch tone { case .good: return .green; case .warn: return .orange; case .bad: return .red; case .neutral: return .secondary }
    }
}

/// Scrollable monospaced JSON with copy and share.
struct JSONView: View {
    let title: String
    let json: JSONValue
    @State private var text = ""
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "…" : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }.disabled(text.isEmpty)
            }
        }
        .task {
            let s = json.prettyString()
            // Very large payloads are truncated for display only; the share link carries the whole text.
            text = s
        }
    }
}

struct DailyChart: View {
    let daily: [DailyAggregate]
    let unit: String?
    let bars: Bool
    var body: some View {
        let points = daily.compactMap { a -> (Date, Double)? in
            guard let v = LocalStatistics.dailyValue(a), let d = LocalStatistics.date(fromDayKey: a.day, calendar: .current) else { return nil }
            return (d, v)
        }
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                if bars {
                    BarMark(x: .value("Day", p.0, unit: .day), y: .value(unit ?? "", p.1))
                } else {
                    LineMark(x: .value("Day", p.0), y: .value(unit ?? "", p.1)).interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.0), y: .value(unit ?? "", p.1)).symbolSize(12)
                }
            }
        }
        .chartYAxisLabel(unit ?? "")
        .frame(height: 180)
    }
}

struct WindowChart: View {
    let windows: [FacialFeatureWindow]
    let key: String
    var body: some View {
        let pts = windows.compactMap { w -> (Double, Double)? in
            CombinedDatasetBuilder.facialValues(w)[key].map { (w.startUptime - (windows.first?.startUptime ?? 0), $0) }
        }
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("s", p.0), y: .value(key, p.1))
                PointMark(x: .value("s", p.0), y: .value(key, p.1)).symbolSize(10)
            }
        }
        .chartXAxisLabel("seconds into recording")
        .frame(height: 160)
    }
}

struct ScatterChart: View {
    let rows: [CombinedDailyRow]
    let healthKey: String
    let facialKey: String
    var body: some View {
        let pts = rows.compactMap { r -> (Double, Double)? in
            guard let h = r.health[healthKey], let f = r.facial[facialKey] else { return nil }
            return (h, f)
        }
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value(healthKey, p.0), y: .value(facialKey, p.1))
            }
        }
        .chartXAxisLabel(healthKey).chartYAxisLabel(facialKey)
        .frame(height: 200)
    }
}

struct ExportFooter: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let u = state.lastExport {
            HStack {
                Image(systemName: "doc.badge.arrow.up")
                Text("Saved \(u.lastPathComponent) to Files › HKGeminiHarness › HKGeminiExports").font(.caption)
                Spacer()
                ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}
