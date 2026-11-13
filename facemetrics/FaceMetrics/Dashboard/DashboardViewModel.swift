import Foundation
import SwiftUI
import Combine

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case blendShapes = "Blend shapes"
    case geometry = "Geometry"
    case eyes = "Eyes"
    case movement = "Movement"
    case analytics = "Analytics"
    case record = "Record"
    case experiment = "Experiment"

    var id: String { rawValue }
}

/// Main-thread owner of the tracking manager, recorder and store. Receives throttled snapshots
/// and republishes them to SwiftUI. All methods are meant to be called from the main thread.
final class DashboardViewModel: ObservableObject {

    @Published private(set) var snapshot = TrackingSnapshot.empty
    @Published private(set) var recording = RecordingProgress()
    @Published var recordingConfig = RecordingConfiguration()
    @Published private(set) var sessions: [RecordedSessionSummary] = []
    @Published private(set) var markers: [ExperimentMarker] = []
    @Published var shareItems: [URL]? = nil
    @Published var alertMessage: String? = nil
    @Published var selectedSection: DashboardSection = .overview
    @Published var showSettings = false

    // Analysis settings
    @Published var analysisWindowSeconds: Double = 5 {
        didSet { tracking.setAnalysisWindow(seconds: analysisWindowSeconds) }
    }
    @Published var temporalConfig = TemporalConfiguration() {
        didSet {
            var c = temporalConfig
            c.windowSeconds = analysisWindowSeconds
            tracking.setTemporalConfiguration(c)
        }
    }
    @Published var blinkConfig = BlinkConfiguration() {
        didSet { tracking.setBlinkConfiguration(blinkConfig) }
    }
    @Published var selectedFormatIndex: Int = 0
    @Published var lightEstimation: Bool = true
    @Published var uiRate: Double = 15 {
        didSet { tracking.setUIUpdateInterval(1.0 / max(5, uiRate)) }
    }

    let tracking: FaceTrackingManager
    let recorder = SessionRecorder()
    let store = SessionStore()
    let markerManager = ExperimentMarkerManager()
    let availableFormats: [VideoFormatDescription]
    let isSupported: Bool

    private var hasStarted = false
    private var lastStartUptime: Double = -10

    init() {
        isSupported = ARSessionController.isSupported
        availableFormats = isSupported ? ARSessionController.supportedVideoFormats : []
        tracking = FaceTrackingManager(markers: markerManager)
        tracking.snapshotSink = { [weak self] snap in
            self?.snapshot = snap
        }
        tracking.sampleSink = { [recorder] sample in
            recorder.ingest(sample)
        }
        recorder.onProgress = { [weak self] progress in
            self?.recording = progress
        }
        refreshSessions()
    }

    // MARK: Tracking control

    func startTrackingIfNeeded() {
        guard isSupported else { return }
        // onAppear and the scene becoming active fire together; one start is enough.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStartUptime > 1 else { return }
        if !hasStarted || snapshot.runState == .paused || snapshot.runState == .idle || snapshot.runState == .failed {
            hasStarted = true
            lastStartUptime = now
            tracking.start(formatIndex: selectedFormatIndex, lightEstimation: lightEstimation)
        }
    }

    func restartTracking() {
        tracking.start(formatIndex: selectedFormatIndex, lightEstimation: lightEstimation)
    }

    func pauseTracking() {
        if recorder.state != .idle { stopRecording() }
        tracking.pause()
    }

    func resetStatistics() {
        tracking.resetStatistics()
    }

    func resetHeadBaseline() {
        tracking.resetHeadBaseline()
    }

    func captureReferenceMesh() { tracking.geometry.captureReferenceOnNextFrame() }
    func clearReferenceMesh() { tracking.geometry.clearReference() }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startTrackingIfNeeded()
        case .background:
            // ARKit interrupts itself; pause the recording so the gap is explicit in the manifest.
            if recorder.state == .recording { pauseRecording() }
        default:
            break
        }
    }

    // MARK: Recording

    var isRecording: Bool { recording.state == .recording }
    var isRecordingOrPaused: Bool { recording.state != .idle }

    func startRecording() {
        guard recorder.state == .idle else { return }
        let cfg = tracking.sessionController.currentConfiguration
        let format = cfg?.videoFormat
        let setup = SessionManifest.TrackingSetup(
            videoFormat: format.map { "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))" } ?? "unknown",
            framesPerSecond: format?.framesPerSecond ?? 0,
            lightEstimationEnabled: cfg?.isLightEstimationEnabled ?? false,
            expectedFrameIntervalSeconds: tracking.sessionController.expectedFrameInterval,
            supportsWorldTracking: ARSessionController.supportsWorldTracking,
            supportedNumberOfTrackedFaces: ARSessionController.supportedNumberOfTrackedFaces
        )
        let identifiers = snapshot.coefficients.map { $0.id }
        do {
            tracking.setAttachMeshToSamples(recordingConfig.includeFaceGeometry)
            _ = try recorder.start(configuration: recordingConfig, setup: setup, knownIdentifiers: identifiers)
            var p = RecordingProgress()
            p.state = .recording
            p.startDate = Date()
            recording = p
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func pauseRecording() {
        recorder.pause()
        recording.state = recorder.state
    }

    func resumeRecording() {
        recorder.resume()
        recording.state = recorder.state
    }

    func stopRecording() {
        guard recorder.state != .idle else { return }
        tracking.setAttachMeshToSamples(false)
        let data = tracking.finalizationData()
        let input = RecordingFinalizationInput(
            markers: markerManager.markers,
            blinkEvents: data.blinkEvents,
            lowActivityPeriods: data.lowActivityPeriods,
            lifecycle: data.lifecycle,
            activationEventCount: data.activationEventCount,
            interruptionCount: data.interruptionCount,
            averageFPS: data.averageFPS
        )
        recorder.stop(finalization: input) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.refreshSessions()
            case .failure(let error):
                self.alertMessage = "Recording could not be finished: \(error.localizedDescription)"
                self.refreshSessions()
            }
        }
    }

    // MARK: Markers

    func mark(_ label: String) {
        markerManager.mark(label)
        markers = markerManager.markers
    }

    func beginInterval(_ label: String) {
        markerManager.beginInterval(label)
        markers = markerManager.markers
    }

    func endInterval() {
        markerManager.endInterval()
        markers = markerManager.markers
    }

    func removeMarker(_ id: UUID) {
        markerManager.remove(id: id)
        markers = markerManager.markers
    }

    func clearMarkers() {
        markerManager.clear()
        markers = markerManager.markers
    }

    var openInterval: ExperimentMarker? { markerManager.currentOpenInterval }

    // MARK: Sessions

    func refreshSessions() {
        sessions = store.list()
    }

    func share(_ session: RecordedSessionSummary, includeGeometry: Bool) {
        let urls = store.shareableFiles(for: session, includeGeometry: includeGeometry)
        guard !urls.isEmpty else { alertMessage = "This session has no files to share."; return }
        shareItems = urls
    }

    func delete(_ session: RecordedSessionSummary) {
        do {
            try store.delete(id: session.id)
        } catch {
            alertMessage = "Could not delete the session: \(error.localizedDescription)"
        }
        refreshSessions()
    }

    func deleteAllSessions() {
        do { try store.deleteAll() } catch { alertMessage = "Could not delete all sessions: \(error.localizedDescription)" }
        refreshSessions()
    }

    // MARK: Convenience for views

    var sessionDurationText: String { Fmt.duration(snapshot.sessionDuration) }

    var trackingStateLabel: (text: String, color: Color) {
        if !isSupported { return ("Face tracking unsupported", Theme.bad) }
        switch snapshot.runState {
        case .idle: return ("Idle", Theme.textSecondary)
        case .starting: return ("Starting", Theme.warn)
        case .running:
            if snapshot.faceTracked { return ("Tracking face", Theme.ok) }
            if snapshot.faceAnchorPresent { return ("Face lost", Theme.warn) }
            return ("No face", Theme.warn)
        case .paused: return ("Paused", Theme.textSecondary)
        case .interrupted: return ("Interrupted", Theme.bad)
        case .failed: return ("Failed", Theme.bad)
        case .unsupported: return ("Unsupported", Theme.bad)
        }
    }
}
