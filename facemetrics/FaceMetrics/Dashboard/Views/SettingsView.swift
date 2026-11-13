import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        cameraPanel
                        analysisPanel
                        blinkPanel
                        aboutPanel
                    }
                    .padding(14)
                }
            }
            .navigationTitle("Instrument settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cameraPanel: some View {
        InstrumentPanel("Camera and session", subtitle: "changes restart ARKit") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video format (ARFaceTrackingConfiguration.supportedVideoFormats)").font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(model.availableFormats) { f in
                        Chip(label: f.label, selected: model.selectedFormatIndex == f.id) { model.selectedFormatIndex = f.id }
                    }
                }
                Toggle("Light estimation (ARDirectionalLightEstimate)", isOn: $model.lightEstimation)
                    .tint(Theme.accent).foregroundStyle(Theme.textPrimary)
                Button("Apply and restart tracking") { model.restartTracking() }
                    .buttonStyle(InstrumentButtonStyle(tint: Theme.accent, prominent: true))
                    .disabled(model.isRecordingOrPaused)
                if model.isRecordingOrPaused {
                    Text("Stop the recording before restarting the session.").font(.caption2).foregroundStyle(Theme.warn)
                }
                HStack(spacing: 8) {
                    Button("Pause camera") { model.pauseTracking() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.warn))
                    Button("Resume") { model.startTrackingIfNeeded() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.ok))
                }
                ReadoutGrid(items: [
                    ("World tracking", ARSessionController.supportsWorldTracking ? "supported" : "no", nil),
                    ("Max faces", String(ARSessionController.supportedNumberOfTrackedFaces), nil),
                    ("Formats", String(model.availableFormats.count), nil)
                ])
            }
        }
    }

    private var analysisPanel: some View {
        InstrumentPanel("Temporal analysis") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow("Analysis window", value: $model.analysisWindowSeconds, range: 1...30, step: 1, format: "%.0f s")
                sliderRow("UI refresh", value: $model.uiRate, range: 5...30, step: 5, format: "%.0f Hz")
                sliderRow("Activation onset", value: Binding(get: { Double(model.temporalConfig.activationOnset) }, set: { model.temporalConfig.activationOnset = Float($0) }),
                          range: 0.05...0.9, step: 0.05, format: "%.2f")
                sliderRow("Activation offset", value: Binding(get: { Double(model.temporalConfig.activationOffset) }, set: { model.temporalConfig.activationOffset = Float($0) }),
                          range: 0.02...0.8, step: 0.02, format: "%.2f")
                sliderRow("Low-activity threshold", value: Binding(get: { Double(model.temporalConfig.lowActivityThreshold) }, set: { model.temporalConfig.lowActivityThreshold = Float($0) }),
                          range: 0.01...0.5, step: 0.01, format: "%.2f")
                sliderRow("Low-activity min. duration", value: $model.temporalConfig.lowActivityMinimumDuration, range: 0.5...10, step: 0.5, format: "%.1f s")
                HStack(spacing: 8) {
                    Button("Reset run statistics") { model.resetStatistics() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.textSecondary))
                    Button("Reset head baseline") { model.resetHeadBaseline() }
                        .buttonStyle(InstrumentButtonStyle(tint: Theme.textSecondary))
                }
                SectionNote(text: "The offset must stay below the onset so detection has hysteresis (a dead band that stops an event from flickering on and off).")
            }
        }
    }

    private var blinkPanel: some View {
        InstrumentPanel("Blink detection") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow("Onset threshold", value: Binding(get: { Double(model.blinkConfig.onsetThreshold) }, set: { model.blinkConfig.onsetThreshold = Float($0) }),
                          range: 0.2...0.9, step: 0.05, format: "%.2f")
                sliderRow("Offset threshold", value: Binding(get: { Double(model.blinkConfig.offsetThreshold) }, set: { model.blinkConfig.offsetThreshold = Float($0) }),
                          range: 0.05...0.8, step: 0.05, format: "%.2f")
                sliderRow("Minimum duration", value: $model.blinkConfig.minimumDuration, range: 0.0...0.2, step: 0.01, format: "%.2f s")
                sliderRow("Long closure above", value: $model.blinkConfig.longClosureDuration, range: 0.2...2, step: 0.1, format: "%.1f s")
                sliderRow("Cluster interval", value: $model.blinkConfig.clusterInterval, range: 0.3...3, step: 0.1, format: "%.1f s")
                sliderRow("Rate window", value: $model.blinkConfig.rateWindowSeconds, range: 10...300, step: 10, format: "%.0f s")
            }
        }
    }

    private var aboutPanel: some View {
        InstrumentPanel("What this instrument measures") {
            VStack(alignment: .leading, spacing: 8) {
                SectionNote(text: "Raw from ARKit: 52 blend-shape coefficients (or whatever the SDK exposes), the face anchor transform, 1220-vertex face mesh, left/right eye transforms, lookAtPoint, camera tracking state, intrinsics, exposure, light estimate, depth-data presence.")
                SectionNote(text: "Derived by the app: Euler angles, velocities and accelerations, windowed statistics, activation events, blink events, left/right asymmetry, gaze vectors, quality score. These are not emotions or clinical indicators.")
                SectionNote(text: "Not available from ARKit: pupil position, pupil size, screen-calibrated gaze, per-vertex confidence, a tracking confidence score.")
                SectionNote(text: "Privacy: everything runs on the device. No frames are stored. Recording is visible in the status strip. Face geometry is written only when opted in per session. Sessions can be deleted in the Record section.")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
        }
    }
}
