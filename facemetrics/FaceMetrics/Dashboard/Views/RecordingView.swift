import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var model: DashboardViewModel
    @State private var confirmDeleteAll = false
    @State private var pendingDelete: RecordedSessionSummary? = nil

    private let rates: [Double] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                statusPanel
                configPanel
                sessionsPanel
            }
            .padding(14)
        }
        .onAppear { model.refreshSessions() }
        .confirmationDialog("Delete all recorded sessions?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.deleteAllSessions() }
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { model.delete(s) }
                pendingDelete = nil
            }
        }
    }

    private var statusPanel: some View {
        let r = model.recording
        return InstrumentPanel("Recording") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusLamp(color: r.state == .recording ? Theme.recording : (r.state == .paused ? Theme.warn : Theme.textTertiary),
                               label: r.state == .idle ? "Not recording" : (r.state == .recording ? "Recording" : "Paused"),
                               pulsing: r.state == .recording)
                    Spacer()
                    if let id = r.sessionID { Text(id).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary) }
                }
                ReadoutGrid(items: [
                    ("Samples", String(r.sampleCount), nil),
                    ("Recorded", Fmt.duration(r.recordedSeconds), nil),
                    ("Written", Fmt.bytes(r.bytesWritten), nil),
                    ("Skipped by rate", String(r.framesSkippedByRate), nil),
                    ("Mesh records", String(r.geometryRecords), nil),
                    ("Effective rate", r.recordedSeconds > 1 ? String(format: "%.1f /s", Double(r.sampleCount) / r.recordedSeconds) : "—", nil)
                ])
                HStack(spacing: 10) {
                    if r.state == .idle {
                        Button { model.startRecording() } label: { Label("Start recording", systemImage: "record.circle") }
                            .buttonStyle(InstrumentButtonStyle(tint: Theme.recording, prominent: true))
                            .disabled(model.snapshot.runState != .running)
                    } else {
                        if r.state == .recording {
                            Button { model.pauseRecording() } label: { Label("Pause", systemImage: "pause.fill") }
                                .buttonStyle(InstrumentButtonStyle(tint: Theme.warn))
                        } else {
                            Button { model.resumeRecording() } label: { Label("Resume", systemImage: "play.fill") }
                                .buttonStyle(InstrumentButtonStyle(tint: Theme.ok))
                        }
                        Button { model.stopRecording() } label: { Label("Stop and save", systemImage: "stop.fill") }
                            .buttonStyle(InstrumentButtonStyle(tint: Theme.recording, prominent: true))
                    }
                }
                SectionNote(text: "Every kept frame becomes one CSV row (and one JSON object) with all blend shapes, head and eye transforms, gaze vectors, tracking state and derived metrics. Files are written in 64 KB chunks on a background queue so ARKit is never blocked. Missing values stay empty, never zero.")
            }
        }
    }

    private var configPanel: some View {
        InstrumentPanel("Session setup", subtitle: model.recording.state == .idle ? nil : "locked while recording") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target sample rate").font(.caption).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(rates, id: \.self) { rate in
                            Chip(label: "\(Int(rate))/s", selected: model.recordingConfig.targetSampleRate == rate) {
                                model.recordingConfig.targetSampleRate = rate
                            }
                        }
                    }
                    Text("Frames arriving faster than the target are skipped. The camera format sets the ceiling (\(model.snapshot.videoFormatLabel.isEmpty ? "—" : model.snapshot.videoFormatLabel) fps).")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                Toggle(isOn: $model.recordingConfig.writeJSONSamples) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also write samples.json").foregroundStyle(Theme.textPrimary)
                        Text("Structured per-sample stream. Roughly twice the CSV size.").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.accent)
                Toggle(isOn: $model.recordingConfig.includeFaceGeometry) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record face geometry (opt-in)").foregroundStyle(Theme.textPrimary)
                        Text("Writes the full 3D mesh per sample to geometry.bin. The mesh is identifiable; keep it off unless the study needs it. About 14 KB per sample.")
                            .font(.caption2).foregroundStyle(model.recordingConfig.includeFaceGeometry ? Theme.warn : Theme.textTertiary)
                    }
                }
                .tint(Theme.warn)
                if model.recordingConfig.includeFaceGeometry {
                    Stepper(value: $model.recordingConfig.geometryEveryNthSample, in: 1...30) {
                        Text("Mesh every \(model.recordingConfig.geometryEveryNthSample) sample\(model.recordingConfig.geometryEveryNthSample == 1 ? "" : "s")")
                            .font(.callout).foregroundStyle(Theme.textPrimary)
                    }
                }
                TextField("Participant label (optional, not a name)", text: $model.recordingConfig.participantLabel)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .foregroundStyle(Theme.textPrimary)
                TextField("Session notes", text: $model.recordingConfig.notes, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .foregroundStyle(Theme.textPrimary)
            }
            .disabled(model.recording.state != .idle)
            .opacity(model.recording.state != .idle ? 0.6 : 1)
        }
    }

    private var sessionsPanel: some View {
        InstrumentPanel("Recorded sessions", subtitle: "\(model.sessions.count) on this device", trailing: AnyView(
            Group {
                if !model.sessions.isEmpty {
                    Button("Delete all") { confirmDeleteAll = true }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.bad))
                        .frame(width: 100)
                }
            })) {
            VStack(spacing: 8) {
                if model.sessions.isEmpty {
                    Text("Nothing recorded yet. Sessions are stored in the app's Documents folder and are also visible in the Files app.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.sessions) { s in
                    SessionRow(session: s,
                               share: { geometry in model.share(s, includeGeometry: geometry) },
                               delete: { pendingDelete = s })
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: RecordedSessionSummary
    let share: (Bool) -> Void
    let delete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text("\(Fmt.dateTime(session.createdAt)) · \(Fmt.duration(session.durationSeconds)) · \(session.sampleCount) samples · \(Fmt.bytes(session.totalBytes))")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if session.hasGeometry {
                        Text("mesh").font(.caption2.weight(.semibold)).foregroundStyle(Theme.warn)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                if let m = session.manifest {
                    ReadoutGrid(items: [
                        ("Rate", "\(Int(m.configuration.targetSampleRate))/s", nil),
                        ("Tracked", Fmt.pct(m.summary.trackedSampleFraction), nil),
                        ("Blinks", String(m.summary.blinkCount), nil),
                        ("Markers", String(m.markers.count), nil),
                        ("Avg FPS", Fmt.f(m.summary.averageFPS, 1), nil),
                        ("Format", "\(m.tracking.videoFormat) @ \(m.tracking.framesPerSecond)", nil)
                    ])
                    if !m.configuration.participantLabel.isEmpty || !m.configuration.notes.isEmpty {
                        Text([m.configuration.participantLabel, m.configuration.notes].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("No session.json: this recording was not finished cleanly. The CSV may still be usable.")
                        .font(.caption2).foregroundStyle(Theme.warn)
                }
                Text(session.files.map { $0.lastPathComponent }.joined(separator: ", "))
                    .font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    Button { share(false) } label: { Label("Share data", systemImage: "square.and.arrow.up") }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.accent, prominent: true))
                    if session.hasGeometry {
                        Button { share(true) } label: { Label("With mesh", systemImage: "cube") }
                            .buttonStyle(InstrumentButtonStyle(tint: Theme.warn))
                    }
                    Button(role: .destructive) { delete() } label: { Image(systemName: "trash") }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.bad))
                        .frame(width: 52)
                }
            }
        }
        .padding(10)
        .background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
