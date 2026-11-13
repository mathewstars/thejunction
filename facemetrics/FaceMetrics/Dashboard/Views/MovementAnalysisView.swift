import SwiftUI
import simd

struct MovementAnalysisView: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headPanel
                activityPanel
                asymmetryPanel
            }
            .padding(14)
        }
    }

    private func degrees(_ v: [Float]) -> [Float] { v.map { $0 * 180 / .pi } }

    private var headPanel: some View {
        let h = model.snapshot.head
        let m = h?.metrics
        let r = h?.reading
        return InstrumentPanel("Head orientation", subtitle: "relative to portrait camera view") {
            VStack(alignment: .leading, spacing: 10) {
                LineChartView(series: [
                    ChartSeries(id: "pitch", values: degrees(h?.pitchHistory ?? []), color: Theme.accent),
                    ChartSeries(id: "yaw", values: degrees(h?.yawHistory ?? []), color: Theme.trace3),
                    ChartSeries(id: "roll", values: degrees(h?.rollHistory ?? []), color: Theme.right)
                ], zeroLine: true, unit: "°", height: 130, decimals: 1)
                LineChartView(series: [
                    ChartSeries(id: "angular speed", values: degrees(h?.angularSpeedHistory ?? []), color: Theme.trace4)
                ], unit: "°/s", height: 80, decimals: 0)
                HStack(alignment: .top, spacing: 12) {
                    ReadoutGrid(items: [
                        ("Ang. velocity", r?.angularVelocity.map { String(format: "%.0f °/s", simd_length($0) * 180 / .pi) } ?? "—", nil),
                        ("Ang. accel.", r?.angularAcceleration.map { String(format: "%.0f °/s²", simd_length($0) * 180 / .pi) } ?? "—", nil),
                        ("Lin. speed", m.map { String(format: "%.0f mm/s", $0.linearSpeed * 1000) } ?? "—", nil),
                        ("Amplitude", m.map { String(format: "%.1f°", $0.movementAmplitude * 180 / .pi) } ?? "—", nil),
                        ("Frequency", Fmt.f(m?.movementFrequencyHz, 2), "Hz"),
                        ("Variability", m.map { String(format: "%.2f°", $0.variability * 180 / .pi) } ?? "—", "std"),
                        ("Stability", Fmt.f(m?.stability, 2), "0-1"),
                        ("Rel. yaw", Fmt.deg(r?.relativeEuler?.y), "vs baseline"),
                        ("Rel. pitch", Fmt.deg(r?.relativeEuler?.x), "vs baseline")
                    ], columns: 2)
                    VStack(spacing: 6) {
                        AttitudeIndicator(pitch: r?.viewEuler.x ?? 0, yaw: r?.viewEuler.y ?? 0, roll: r?.viewEuler.z ?? 0)
                            .frame(width: 100, height: 100)
                        Button("Set baseline") { model.resetHeadBaseline() }
                            .buttonStyle(InstrumentButtonStyle(tint: Theme.textSecondary))
                            .frame(width: 110)
                    }
                }
                SectionNote(text: "Absolute position is the anchor's world transform (gravity-aligned ARKit origin). Relative values subtract the baseline pose. Stability = 1 − clamp(variability / 2.9°) over the \(Int(model.analysisWindowSeconds)) s window; application-derived.")
            }
        }
    }

    private var activityPanel: some View {
        let t = model.snapshot.temporal
        let m = t?.metrics
        return InstrumentPanel("Facial activity", subtitle: "all \(model.snapshot.coefficients.count) coefficients") {
            VStack(alignment: .leading, spacing: 10) {
                LineChartView(series: [
                    ChartSeries(id: "activity |d/dt|", values: t?.activityHistory ?? [], color: Theme.accent)
                ], unit: "", height: 90, decimals: 3)
                LineChartView(series: [
                    ChartSeries(id: "mean activation", values: t?.meanActivationHistory ?? [], color: Theme.trace3),
                    ChartSeries(id: "total variation", values: t?.totalVariationHistory ?? [], color: Theme.right)
                ], unit: "", height: 90, decimals: 3)
                ReadoutGrid(items: [
                    ("Amplitude", Fmt.f(m?.movementAmplitude, 3), nil),
                    ("Frequency", Fmt.f(m?.movementFrequencyHz, 2), "Hz"),
                    ("Std (variability)", Fmt.f(m?.activationStd, 4), nil),
                    ("Variance", Fmt.f(m?.activationVariance, 5), nil),
                    ("Transitions", Fmt.f(m?.transitionRate, 2), "/s"),
                    ("Activation events", Fmt.int(t?.totalActivationEvents), nil),
                    ("Low activity", m?.lowActivity == true ? "yes, \(Fmt.f(m?.lowActivityDuration, 0)) s" : "no", nil),
                    ("Low periods", Fmt.int(t?.lowActivityPeriodCount), nil),
                    ("Onset / offset", "\(Fmt.f(t?.configuration.activationOnset, 2)) / \(Fmt.f(t?.configuration.activationOffset, 2))", nil)
                ])
                if let recent = t?.recentActivations, !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent activation events").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(recent.suffix(6).reversed()) { ev in
                            HStack {
                                Text(BlendShapeCatalog.friendlyName(for: ev.identifier)).font(.caption2).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("peak \(Fmt.f(ev.peak, 2))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                Text(Fmt.ms(ev.duration)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private var asymmetryPanel: some View {
        let a = model.snapshot.asymmetry
        let groups = a?.groups.filter { $0.group != "overall" } ?? []
        let colors: [String: Color] = ["smile": Theme.right, "brow": Theme.trace3, "eye": Theme.left, "cheek": Theme.trace4, "mouth": Theme.accent, "nose": Theme.textSecondary]
        return InstrumentPanel("Left / right asymmetry", subtitle: "left − right per pair") {
            VStack(alignment: .leading, spacing: 10) {
                LineChartView(series: groups.map { g in
                    ChartSeries(id: g.group, values: a?.histories[g.group] ?? [], color: colors[g.group] ?? Theme.accent)
                }, yRange: -0.5...0.5, zeroLine: true, height: 110, decimals: 2)
                ForEach(groups) { g in
                    HStack(spacing: 8) {
                        Text(g.group).font(.caption).foregroundStyle(Theme.textPrimary).frame(width: 46, alignment: .leading)
                        SignedBar(value: g.difference, range: 0.5)
                        Text(Fmt.signed(g.difference, 3)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary).frame(width: 56, alignment: .trailing)
                        Text("|w| \(Fmt.f(a?.windowedMeanAbsolute[g.group], 3))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .trailing)
                    }
                }
                if let overall = a?.groups.first(where: { $0.group == "overall" }) {
                    Readout(label: "Overall mean |L−R| over \(overall.pairCount) pairs", value: Fmt.f(overall.difference, 3))
                }
                DisclosureGroup {
                    VStack(spacing: 4) {
                        ForEach(a?.pairs ?? []) { p in
                            HStack(spacing: 8) {
                                Text(p.base).font(.caption2).foregroundStyle(Theme.textPrimary).frame(width: 100, alignment: .leading)
                                Text(Fmt.f(p.left, 2)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.left).frame(width: 34)
                                SignedBar(value: p.difference, range: 1, height: 5)
                                Text(Fmt.f(p.right, 2)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.right).frame(width: 34)
                                Text(Fmt.signed(p.difference, 2)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("All \(a?.pairs.count ?? 0) pairs").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .tint(Theme.textSecondary)
                SectionNote(text: "Blue grows left, amber grows right. |w| is the mean absolute difference over the analysis window. Pairs are discovered from ARKit's _L/_R identifiers plus jawLeft/jawRight and mouthLeft/mouthRight.")
            }
        }
    }
}
