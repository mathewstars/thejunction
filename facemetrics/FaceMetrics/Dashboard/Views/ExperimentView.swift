import SwiftUI

struct ExperimentView: View {
    @EnvironmentObject var model: DashboardViewModel
    @State private var customLabel = ""
    @State private var holdMode = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                controlsPanel
                markersPanel
            }
            .padding(14)
        }
    }

    private var controlsPanel: some View {
        InstrumentPanel("Mark events", subtitle: holdMode ? "tap starts an interval, tap again ends it" : "tap places an instant marker") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Chip(label: "Interval", selected: holdMode) { holdMode = true }
                    Chip(label: "Instant", selected: !holdMode) { holdMode = false }
                    Spacer()
                    if model.isRecording {
                        StatusLamp(color: Theme.recording, label: "Recording", pulsing: true)
                    } else {
                        Text("Not recording: markers still get frame timestamps").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let open = model.openInterval {
                    HStack {
                        StatusLamp(color: Theme.trace3, label: "\(open.label) in progress", pulsing: true)
                        Spacer()
                        Button("End") { model.endInterval() }
                            .buttonStyle(InstrumentButtonStyle(tint: Theme.trace3, prominent: true))
                            .frame(width: 90)
                    }
                    .padding(10)
                    .background(Theme.trace3.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ExperimentMarkerManager.presetLabels, id: \.self) { label in
                        Button(label) { fire(label) }
                            .buttonStyle(InstrumentButtonStyle(tint: model.openInterval?.label == label ? Theme.trace3 : Theme.accent,
                                                               prominent: model.openInterval?.label == label))
                    }
                }
                HStack(spacing: 8) {
                    TextField("Custom event", text: $customLabel)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .foregroundStyle(Theme.textPrimary)
                        .submitLabel(.done)
                        .onSubmit { fireCustom() }
                    Button("Mark") { fireCustom() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.right, prominent: true))
                        .frame(width: 90)
                        .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                SectionNote(text: "Markers record the ARFrame timestamp and frame index of the moment you tap, so they align with the samples in the CSV. While an interval is open its label is written into the active_marker column. Markers describe what the participant was asked to do; the app never infers emotion from them.")
            }
        }
    }

    private func fire(_ label: String) {
        if holdMode {
            if model.openInterval?.label == label { model.endInterval() } else { model.beginInterval(label) }
        } else {
            model.mark(label)
        }
    }

    private func fireCustom() {
        let label = customLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        fire(label)
        if !holdMode { customLabel = "" }
    }

    private var markersPanel: some View {
        let latest = model.snapshot.frameIndex
        return InstrumentPanel("Markers", subtitle: "\(model.markers.count) this run", trailing: AnyView(
            Group {
                if !model.markers.isEmpty {
                    Button("Clear") { model.clearMarkers() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.bad))
                        .frame(width: 80)
                }
            })) {
            VStack(spacing: 6) {
                if model.markers.isEmpty {
                    Text("No markers yet. They are saved into session.json when a recording stops.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.markers.reversed()) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: m.kind == .interval ? "flag.checkered" : "flag")
                            .font(.caption).foregroundStyle(m.isOpen ? Theme.trace3 : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.label).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            Text(detail(for: m, latestFrame: latest)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(Fmt.time(m.wallClock)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        Button { model.removeMarker(m.id) } label: {
                            Image(systemName: "xmark").font(.caption2).foregroundStyle(Theme.textTertiary).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func detail(for m: ExperimentMarker, latestFrame: Int) -> String {
        var parts = ["t \(Fmt.f(m.startTimestamp, 3)) s", "frame \(m.startFrameIndex)"]
        if m.kind == .interval {
            if let d = m.duration { parts.append("duration \(Fmt.f(d, 2)) s") }
            else { parts.append("open") }
        }
        return parts.joined(separator: " · ")
    }
}
