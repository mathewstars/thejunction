import SwiftUI

/// Instrument frame: status strip on top, section tabs, the active section, and the transport bar
/// with the record control at the bottom.
struct RootView: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                StatusStrip()
                SectionTabs()
                Divider().overlay(Theme.border)
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.border)
                TransportBar()
            }
        }
        .onAppear { model.startTrackingIfNeeded() }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.shareItems != nil }, set: { if !$0 { model.shareItems = nil } })) {
            if let items = model.shareItems {
                ShareSheet(items: items) { model.shareItems = nil }
                    .ignoresSafeArea()
            }
        }
        .alert("FaceMetrics", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if !model.isSupported {
            UnsupportedView()
        } else {
            switch model.selectedSection {
            case .overview: OverviewView()
            case .blendShapes: BlendShapeExplorerView()
            case .geometry: FaceGeometryLabView()
            case .eyes: EyeTrackingLabView()
            case .movement: MovementAnalysisView()
            case .analytics: SessionAnalyticsView()
            case .record: RecordingView()
            case .experiment: ExperimentView()
            }
        }
    }
}

struct StatusStrip: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        let state = model.trackingStateLabel
        HStack(spacing: 14) {
            StatusLamp(color: state.color, label: state.text, pulsing: model.snapshot.faceTracked)
            Spacer()
            if model.isRecordingOrPaused {
                HStack(spacing: 5) {
                    Circle().fill(model.isRecording ? Theme.recording : Theme.warn).frame(width: 8, height: 8)
                    Text(model.isRecording ? "REC" : "PAUSED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(model.isRecording ? Theme.recording : Theme.warn)
                    Text(Fmt.duration(model.recording.recordedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text(String(format: "%.0f fps", model.snapshot.fps))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Text(model.sessionDurationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Button { model.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct SectionTabs: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DashboardSection.allCases) { section in
                        Chip(label: section.rawValue, selected: model.selectedSection == section) {
                            model.selectedSection = section
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(section.id, anchor: .center) }
                        }
                        .id(section.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Record / pause / stop plus a quick marker button. Always visible so recording state is never hidden.
struct TransportBar: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        HStack(spacing: 10) {
            if model.recording.state == .idle {
                Button {
                    model.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(InstrumentButtonStyle(tint: Theme.recording, prominent: true))
                .disabled(model.snapshot.runState != .running)
            } else {
                if model.recording.state == .recording {
                    Button { model.pauseRecording() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.warn))
                } else {
                    Button { model.resumeRecording() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.ok))
                }
                Button { model.stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(InstrumentButtonStyle(tint: Theme.recording, prominent: true))
            }
            if let open = model.openInterval {
                Button { model.endInterval() } label: {
                    Label("End \(open.label)", systemImage: "flag.checkered")
                        .lineLimit(1)
                }
                .buttonStyle(InstrumentButtonStyle(tint: Theme.trace3))
            } else {
                Button { model.mark("Mark") } label: { Label("Mark", systemImage: "flag") }
                    .buttonStyle(InstrumentButtonStyle(tint: Theme.accent))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "faceid").font(.system(size: 44)).foregroundStyle(Theme.textSecondary)
            Text("Face tracking is not available on this device")
                .font(.headline).foregroundStyle(Theme.textPrimary)
            Text("FaceMetrics needs an iPhone with a TrueDepth camera (Face ID). ARKit reports ARFaceTrackingConfiguration.isSupported == false here. The simulator cannot run it either.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }
}
