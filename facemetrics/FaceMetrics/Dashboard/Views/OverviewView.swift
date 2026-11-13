import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: DashboardViewModel
    @State private var showMesh = true
    @State private var showEyeRays = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                previewPanel
                statusPanel
                livePanel
            }
            .padding(14)
        }
    }

    private var previewPanel: some View {
        let snap = model.snapshot
        return InstrumentPanel("Camera", subtitle: snap.videoFormatLabel.isEmpty ? nil : snap.videoFormatLabel + " fps",
                               trailing: AnyView(
            HStack(spacing: 6) {
                Chip(label: "Mesh", selected: showMesh) { showMesh.toggle() }
                Chip(label: "Eye rays", selected: showEyeRays, color: Theme.left) { showEyeRays.toggle() }
            })) {
            ZStack(alignment: .bottomLeading) {
                ARPreviewView(session: model.tracking.sessionController.session, showMesh: showMesh, showEyeRays: showEyeRays)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 8) {
                    if model.isRecording {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.recording).frame(width: 8, height: 8)
                            Text("Recording").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    Text("Preview only. No frames are stored.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                }
                .padding(8)
            }
        }
    }

    private var statusPanel: some View {
        let snap = model.snapshot
        let q = snap.quality
        let cam = snap.camera
        return InstrumentPanel("Tracking status") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    StatusLamp(color: snap.runState == .running ? Theme.ok : Theme.warn, label: "Session \(snap.runState.rawValue)")
                    StatusLamp(color: snap.faceAnchorPresent ? Theme.ok : Theme.textTertiary, label: snap.faceAnchorPresent ? "Face anchor" : "No anchor")
                    StatusLamp(color: snap.faceTracked ? Theme.ok : Theme.warn, label: snap.faceTracked ? "Tracked" : "Not tracked")
                }
                HStack(spacing: 16) {
                    StatusLamp(color: cam?.trackingState == .normal ? Theme.ok : (cam?.trackingState == .limited ? Theme.warn : Theme.textTertiary),
                               label: "Camera \(cam?.trackingState.rawValue ?? "—")\(cam?.limitedReason.map { " (\($0))" } ?? "")")
                    StatusLamp(color: snap.eyes != nil ? Theme.ok : Theme.textTertiary, label: snap.eyes != nil ? "Eye transforms" : "No eye data")
                }
                if let err = snap.errorMessage {
                    Text(err).font(.caption).foregroundStyle(Theme.bad)
                }
                ReadoutGrid(items: [
                    ("FPS", String(format: "%.1f", snap.fps), nil),
                    ("Session", Fmt.duration(snap.sessionDuration), nil),
                    ("Frames", Fmt.int(q?.frameCount), nil),
                    ("Tracked frames", Fmt.int(q?.trackedFrameCount), nil),
                    ("Interruptions", Fmt.int(q?.interruptionCount), nil),
                    ("Dropped (est.)", Fmt.int(q?.droppedFrameEstimate), nil),
                    ("Frame interval", Fmt.ms(q?.frameInterval), nil),
                    ("Depth data", cam?.depthDataAvailable == true ? "present" : "none", nil),
                    ("Quality (app)", Fmt.f(q?.qualityScore, 2), nil)
                ])
            }
        }
    }

    private var livePanel: some View {
        let snap = model.snapshot
        let t = snap.temporal?.metrics
        let h = snap.head?.reading
        let e = snap.eyes?.reading
        return InstrumentPanel("Live measurements", subtitle: "window \(Int(model.analysisWindowSeconds)) s") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Readout(label: "Facial activity (mean |d/dt|)", value: Fmt.f(t?.facialActivity, 3), unit: "1/s", large: true)
                        Sparkline(values: snap.temporal?.activityHistory ?? [], color: Theme.accent)
                            .frame(height: 44)
                        ReadoutGrid(items: [
                            ("Active coeffs", Fmt.int(t?.activeCoefficientCount), nil),
                            ("Mean activation", Fmt.f(t?.meanActivation, 3), nil),
                            ("Blinks", Fmt.int(snap.blink?.statistics.totalBlinks), nil),
                            ("Blink rate", Fmt.f(snap.blink?.statistics.ratePerMinute, 1), "/min")
                        ], columns: 2)
                    }
                    VStack(spacing: 6) {
                        AttitudeIndicator(pitch: h?.viewEuler.x ?? 0, yaw: h?.viewEuler.y ?? 0, roll: h?.viewEuler.z ?? 0)
                            .frame(width: 110, height: 110)
                        Text("Head attitude").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                ReadoutGrid(items: [
                    ("Pitch", Fmt.deg(h?.viewEuler.x), nil),
                    ("Yaw", Fmt.deg(h?.viewEuler.y), nil),
                    ("Roll", Fmt.deg(h?.viewEuler.z), nil),
                    ("Distance", Fmt.mm(h?.distanceToCamera), nil),
                    ("Gaze yaw", Fmt.degValue(e?.gazeYawDegrees), nil),
                    ("Gaze pitch", Fmt.degValue(e?.gazePitchDegrees), nil)
                ])
                SectionNote(text: "Angles are relative to the portrait camera view. Activity and blink figures are application-derived from the raw ARKit coefficients.")
            }
        }
    }
}
