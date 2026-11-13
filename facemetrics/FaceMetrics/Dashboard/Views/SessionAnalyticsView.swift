import SwiftUI

struct SessionAnalyticsView: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                totalsPanel
                qualityPanel
                statisticsPanel
                eventsPanel
                lifecyclePanel
            }
            .padding(14)
        }
    }

    private var totalsPanel: some View {
        let s = model.snapshot
        let q = s.quality
        let completeness = (q?.frameCount ?? 0) > 0 ? Double(q!.trackedFrameCount) / Double(q!.frameCount) : nil
        return InstrumentPanel("This tracking run", trailing: AnyView(
            Button("Reset") { model.resetStatistics() }
                .buttonStyle(InstrumentButtonStyle(tint: Theme.textSecondary))
                .frame(width: 80))) {
            VStack(alignment: .leading, spacing: 10) {
                ReadoutGrid(items: [
                    ("Frames", Fmt.int(q?.frameCount), nil),
                    ("Tracked", Fmt.int(q?.trackedFrameCount), nil),
                    ("Completeness", Fmt.pct(completeness), nil),
                    ("Duration", Fmt.duration(s.sessionDuration), nil),
                    ("Average FPS", Fmt.f(q?.averageFPS, 1), nil),
                    ("Current FPS", Fmt.f(q?.measuredFPS, 1), nil),
                    ("Mean interval", Fmt.ms(q?.meanFrameInterval), nil),
                    ("Expected", Fmt.ms(q?.expectedFrameInterval), nil),
                    ("Dropped (est.)", Fmt.int(q?.droppedFrameEstimate), nil)
                ])
                if model.recording.state != .idle {
                    Text("Recording \(model.recording.sessionID ?? ""): \(model.recording.sampleCount) samples, \(Fmt.duration(model.recording.recordedSeconds)), \(Fmt.bytes(model.recording.bytesWritten))")
                        .font(.caption).foregroundStyle(Theme.recording)
                }
            }
        }
    }

    private var qualityPanel: some View {
        let s = model.snapshot
        let q = s.quality
        return InstrumentPanel("Tracking quality", subtitle: "last \(Int(q?.windowSeconds ?? 2)) s") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Readout(label: "Quality score (app-derived)", value: Fmt.f(q?.qualityScore, 2), large: true)
                    VStack(alignment: .leading, spacing: 4) {
                        LevelBar(value: q?.qualityScore ?? 0, color: (q?.qualityScore ?? 0) > 0.8 ? Theme.ok : Theme.warn)
                        Text("tracked \(Fmt.pct(q?.trackedFractionLastWindow)) · dropped \(Fmt.pct(q?.droppedFractionLastWindow)) · camera \(q?.cameraTrackingState.rawValue ?? "—")")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                TrackedTimeline(transitions: s.trackedTransitions, duration: s.sessionDuration)
                    .frame(height: 18)
                Text("Face tracked over the run (green = tracked)").font(.caption2).foregroundStyle(Theme.textTertiary)
                LineChartView(series: [
                    ChartSeries(id: "frame interval", values: s.frameIntervalHistory.map { $0 * 1000 }, color: Theme.accent)
                ], unit: " ms", height: 70, decimals: 1)
                SectionNote(text: TrackingQualityReport.qualityScoreFormula)
            }
        }
    }

    private var statisticsPanel: some View {
        let coeffs = model.snapshot.coefficients.sorted { ($0.maximum ?? 0) > ($1.maximum ?? 0) }
        return InstrumentPanel("Coefficient statistics", subtitle: "whole run, sorted by max") {
            VStack(spacing: 4) {
                HStack {
                    Text("coefficient").frame(maxWidth: .infinity, alignment: .leading)
                    Text("min").frame(width: 46, alignment: .trailing)
                    Text("mean").frame(width: 46, alignment: .trailing)
                    Text("max").frame(width: 46, alignment: .trailing)
                    Text("events").frame(width: 46, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(Theme.textTertiary)
                ForEach(coeffs) { c in
                    HStack {
                        Text(c.name).font(.caption2).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.f(c.minimum, 2)).frame(width: 46, alignment: .trailing)
                        Text(Fmt.f(c.mean, 2)).frame(width: 46, alignment: .trailing)
                        Text(Fmt.f(c.maximum, 2)).frame(width: 46, alignment: .trailing)
                        Text(String(c.activationCount)).frame(width: 46, alignment: .trailing)
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var eventsPanel: some View {
        let s = model.snapshot
        return InstrumentPanel("Event counts") {
            ReadoutGrid(items: [
                ("Blinks", Fmt.int(s.blink?.statistics.totalBlinks), nil),
                ("Long closures", Fmt.int(s.blink?.statistics.totalClosures), nil),
                ("Activations", Fmt.int(s.temporal?.totalActivationEvents), nil),
                ("Low-activity periods", Fmt.int(s.temporal?.lowActivityPeriodCount), nil),
                ("Interruptions", Fmt.int(s.quality?.interruptionCount), nil),
                ("Markers", String(model.markers.count), nil)
            ])
        }
    }

    private var lifecyclePanel: some View {
        InstrumentPanel("Session lifecycle", subtitle: "ARSession events") {
            VStack(alignment: .leading, spacing: 3) {
                if model.snapshot.lifecycleEvents.isEmpty {
                    Text("No events yet").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                ForEach(model.snapshot.lifecycleEvents.suffix(25).reversed()) { ev in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.time(ev.date)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        Text(ev.kind.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(color(for: ev.kind)).frame(width: 150, alignment: .leading)
                        Text(ev.detail).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private func color(for kind: SessionLifecycleEvent.Kind) -> Color {
        switch kind {
        case .failed, .interrupted: return Theme.bad
        case .started, .interruptionEnded, .faceAnchorAdded: return Theme.ok
        case .faceAnchorRemoved, .paused: return Theme.warn
        default: return Theme.textPrimary
        }
    }
}

/// Horizontal strip: green where the face was tracked, dark where it was not.
struct TrackedTimeline: View {
    let transitions: [(time: Double, tracked: Bool)]
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panelRaised))
            guard duration > 0, !transitions.isEmpty else { return }
            for (i, t) in transitions.enumerated() {
                let start = t.time
                let end = i + 1 < transitions.count ? transitions[i + 1].time : duration
                guard t.tracked, end > start else { continue }
                let x0 = size.width * CGFloat(start / duration)
                let x1 = size.width * CGFloat(end / duration)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)), with: .color(Theme.ok.opacity(0.8)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
