import Foundation
import ARKit
import simd

/// Central coordinator. Receives every ARFrame on the session's delegate queue, runs the
/// collectors and engines, hands the resulting FaceSample to the recorder, and publishes a
/// throttled TrackingSnapshot to the UI on the main thread.
///
/// Threading contract: every stored property below (other than the sinks and the public
/// `latestClock`) is touched only on `sessionController.delegateQueue`. Code running on that
/// queue must never block on the main queue (`DispatchQueue.main.sync`), because
/// `finalizationData()` blocks main on the tracking queue.
final class FaceTrackingManager {

    let sessionController = ARSessionController()
    let blendShapes = BlendShapeCollector()
    let headPose = HeadPoseProcessor()
    let eyeTracking = EyeTrackingProcessor()
    let geometry = FaceGeometryProcessor()
    let temporal = TemporalFeatureEngine()
    let blinks = BlinkDetectionEngine()
    let asymmetry = AsymmetryAnalyzer()
    let quality = TrackingQualityMonitor()
    let markers: ExperimentMarkerManager

    /// Called on the tracking queue for every frame. Keep it cheap and never block.
    var sampleSink: ((FaceSample) -> Void)?
    /// Called on the main queue at most every `uiUpdateInterval` seconds.
    var snapshotSink: ((TrackingSnapshot) -> Void)?

    // Both are read on the tracking queue; change them through the setters below.
    private(set) var uiUpdateInterval: Double = 1.0 / 15.0
    private(set) var historyPointsForUI: Int = 150
    /// When true, each sample carries the full face mesh (opt-in geometry recording). Tracking queue only.
    private var attachMeshToSamples = false

    func setHistoryPointsForUI(_ n: Int) {
        sessionController.delegateQueue.async { self.historyPointsForUI = max(2, n) }
    }

    func setAttachMeshToSamples(_ enabled: Bool) {
        sessionController.delegateQueue.async {
            self.attachMeshToSamples = enabled
            if enabled { self.geometry.retainsMesh = true }
        }
    }

    private var frameIndex: Int = 0
    private var lastSnapshotUptime: Double = 0
    private var runState: ARSessionRunState = .idle
    private var lastError: String?
    private var lifecycleLog: [SessionLifecycleEvent] = []
    private var lastDerived: DerivedMetrics?
    private var lastTemporal: TemporalMetrics?
    private var lastAsymmetryValues: [String: Float] = [:]

    private let clockLock = NSLock()
    private var latestTimestamp: Double = 0
    private var latestFrameIndex: Int = 0

    private let eyeBlinkLeftID = ARFaceAnchor.BlendShapeLocation.eyeBlinkLeft.rawValue
    private let eyeBlinkRightID = ARFaceAnchor.BlendShapeLocation.eyeBlinkRight.rawValue

    init(markers: ExperimentMarkerManager) {
        self.markers = markers
        markers.clock = { [weak self] in self?.latestClock ?? (0, 0) }
        sessionController.frameSink = { [weak self] frame in self?.handle(frame: frame) }
        sessionController.onLifecycleEvent = { [weak self] event in self?.handle(lifecycle: event) }
        sessionController.onRunStateChanged = { [weak self] state in
            self?.runState = state
            self?.publishSnapshotIfNeeded(force: true)
        }
    }

    /// Latest ARFrame timestamp and frame index. Safe from any thread.
    var latestClock: (timestamp: Double, frameIndex: Int) {
        clockLock.lock(); defer { clockLock.unlock() }
        return (latestTimestamp, latestFrameIndex)
    }

    // MARK: Control (callable from the main thread)

    func start(formatIndex: Int? = nil, lightEstimation: Bool? = nil) {
        sessionController.delegateQueue.async {
            self.quality.expectedFrameInterval = self.sessionController.expectedFrameInterval
        }
        sessionController.start(formatIndex: formatIndex, lightEstimation: lightEstimation)
        sessionController.delegateQueue.async {
            self.quality.expectedFrameInterval = self.sessionController.expectedFrameInterval
        }
    }

    func pause() { sessionController.pause() }

    /// Clears statistics, histories and events without restarting the camera.
    func resetStatistics() {
        sessionController.delegateQueue.async {
            self.blendShapes.resetSessionStatistics()
            self.headPose.reset()
            self.eyeTracking.reset()
            self.geometry.reset()
            self.temporal.reset()
            self.blinks.reset()
            self.asymmetry.reset()
            self.quality.reset()
            self.frameIndex = 0
            self.lastDerived = nil
            self.lastTemporal = nil
            self.publishSnapshotIfNeeded(force: true)
        }
    }

    func resetHeadBaseline() {
        sessionController.delegateQueue.async { self.headPose.requestBaselineReset() }
    }

    func setAnalysisWindow(seconds: Double) {
        sessionController.delegateQueue.async {
            self.temporal.configuration.windowSeconds = seconds
            self.headPose.windowSeconds = seconds
            self.eyeTracking.windowSeconds = seconds
            self.asymmetry.windowSeconds = seconds
        }
    }

    func setTemporalConfiguration(_ config: TemporalConfiguration) {
        sessionController.delegateQueue.async { self.temporal.configuration = config }
    }

    func setBlinkConfiguration(_ config: BlinkConfiguration) {
        sessionController.delegateQueue.async { self.blinks.configuration = config }
    }

    func setMeshRetention(_ enabled: Bool) {
        sessionController.delegateQueue.async { self.geometry.retainsMesh = enabled }
    }

    func setUIUpdateInterval(_ seconds: Double) {
        sessionController.delegateQueue.async { self.uiUpdateInterval = seconds }
    }

    /// Everything the recorder needs to finish a manifest, read synchronously on the tracking queue.
    /// Safe to call from the main thread: the tracking queue never blocks on main.
    struct FinalizationData {
        var blinkEvents: [BlinkEvent]
        var lowActivityPeriods: [LowActivityPeriod]
        var activationEventCount: Int
        var lifecycle: [SessionLifecycleEvent]
        var interruptionCount: Int
        var averageFPS: Double
    }

    func finalizationData() -> FinalizationData {
        sessionController.delegateQueue.sync {
            var lows = temporal.lowActivityPeriods
            if let open = temporal.currentLowActivity { lows.append(open) }
            let report = quality.report(faceAnchorPresent: false, faceTracked: false, cameraState: .normal, cameraReason: nil)
            return FinalizationData(
                blinkEvents: blinks.events,
                lowActivityPeriods: lows,
                activationEventCount: temporal.totalActivationCount,
                lifecycle: quality.lifecycleEvents,
                interruptionCount: quality.interruptionCount,
                averageFPS: report.averageFPS
            )
        }
    }

    // MARK: Frame processing (tracking queue)

    private func handle(lifecycle event: SessionLifecycleEvent) {
        quality.noteLifecycle(event)
        lifecycleLog.append(event)
        if lifecycleLog.count > 200 { lifecycleLog.removeFirst(lifecycleLog.count - 200) }
        if event.kind == .failed { lastError = event.detail }
        if event.kind == .started { lastError = nil }
        publishSnapshotIfNeeded(force: true)
    }

    private func handle(frame: ARFrame) {
        let timestamp = frame.timestamp
        frameIndex += 1
        clockLock.lock()
        latestTimestamp = timestamp
        latestFrameIndex = frameIndex
        clockLock.unlock()

        let anchor = frame.anchors.first { $0 is ARFaceAnchor } as? ARFaceAnchor
        let anchorPresent = anchor != nil
        let tracked = anchor?.isTracked ?? false
        let (interval, dropped) = quality.noteFrame(timestamp: timestamp, faceTracked: tracked)

        let camera = FaceTrackingManager.cameraReading(from: frame)
        let light = FaceTrackingManager.lightReading(from: frame)

        var values: [String: Float] = [:]
        var head: HeadPoseReading?
        var eyes: EyeReading?
        var geom: GeometryReading?
        var temporalMetrics: TemporalMetrics?
        var asym: [String: Float] = [:]

        if let anchor, tracked {
            values = BlendShapeCollector.extract(from: anchor)
            blendShapes.ingest(values: values, timestamp: timestamp)
            let h = headPose.process(anchor: anchor, camera: frame.camera, timestamp: timestamp)
            head = h
            eyes = eyeTracking.process(anchor: anchor, viewTransform: h.viewTransform, worldTransform: anchor.transform, timestamp: timestamp)
            geom = geometry.process(anchor: anchor, viewTransform: h.viewTransform, timestamp: timestamp)
            temporalMetrics = temporal.process(values: values, timestamp: timestamp, valueHistory: blendShapes.history)
            blinks.process(left: values[eyeBlinkLeftID], right: values[eyeBlinkRightID], timestamp: timestamp)
            asym = asymmetry.process(values: values, timestamp: timestamp)
        } else {
            blendShapes.ingestMissingFrame(timestamp: timestamp)
            headPose.noteMissingFrame(timestamp: timestamp)
            eyeTracking.noteMissingFrame(timestamp: timestamp)
            geometry.noteMissingFrame()
            temporal.noteMissingFrame(timestamp: timestamp)
            blinks.process(left: nil, right: nil, timestamp: timestamp)
            asymmetry.noteMissingFrame(timestamp: timestamp)
        }

        let headMetrics = headPose.windowedMetrics(reading: head)
        let gazeMetrics = eyeTracking.windowedMetrics()
        let blinkStats = blinks.statistics()
        let qualityReport = quality.report(faceAnchorPresent: anchorPresent, faceTracked: tracked,
                                           cameraState: camera.trackingState, cameraReason: camera.limitedReason)

        let derived = DerivedMetrics(
            temporal: temporalMetrics,
            blinkInProgress: blinkStats.blinkInProgress,
            blinkCount: blinkStats.totalBlinks,
            blinkRatePerMinute: blinkStats.ratePerMinute,
            asymmetry: asym,
            headSpeed: headMetrics?.angularSpeed,
            headMovementAmplitude: headMetrics?.movementAmplitude,
            headMovementFrequencyHz: headMetrics?.movementFrequencyHz,
            headVariability: headMetrics?.variability,
            headStability: headMetrics?.stability,
            gazeVariability: gazeMetrics?.gazeVariabilityDegrees,
            qualityScore: qualityReport.qualityScore
        )
        lastDerived = derived
        lastTemporal = temporalMetrics
        lastAsymmetryValues = asym

        var sample = FaceSample(
            frameIndex: frameIndex,
            timestamp: timestamp,
            wallClock: Date(),
            frameInterval: interval,
            droppedFrameEstimate: dropped,
            faceAnchorPresent: anchorPresent,
            faceTracked: tracked,
            blendShapes: values,
            head: head,
            eyes: eyes,
            geometry: geom,
            camera: camera,
            light: light,
            derived: derived,
            activeMarker: markers.activeIntervalLabel()
        )
        if attachMeshToSamples, tracked { sample.mesh = geometry.currentMesh() }
        sampleSink?(sample)

        publishSnapshotIfNeeded(force: false, sample: sample, headMetrics: headMetrics, gazeMetrics: gazeMetrics,
                                blinkStats: blinkStats, quality: qualityReport)
    }

    // MARK: Snapshot

    private func publishSnapshotIfNeeded(force: Bool, sample: FaceSample? = nil, headMetrics: HeadMovementMetrics? = nil,
                                         gazeMetrics: GazeMetrics? = nil, blinkStats: BlinkStatistics? = nil,
                                         quality report: TrackingQualityReport? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSnapshotUptime >= uiUpdateInterval else { return }
        lastSnapshotUptime = now
        let snapshot = buildSnapshot(sample: sample, headMetrics: headMetrics, gazeMetrics: gazeMetrics,
                                     blinkStats: blinkStats ?? blinks.statistics(), quality: report)
        DispatchQueue.main.async { [snapshotSink] in snapshotSink?(snapshot) }
    }

    private func buildSnapshot(sample: FaceSample?, headMetrics: HeadMovementMetrics?, gazeMetrics: GazeMetrics?,
                               blinkStats: BlinkStatistics, quality report: TrackingQualityReport?) -> TrackingSnapshot {
        let n = historyPointsForUI
        var snap = TrackingSnapshot()
        snap.runState = runState
        snap.isSupported = ARSessionController.isSupported
        snap.errorMessage = lastError
        snap.faceAnchorPresent = sample?.faceAnchorPresent ?? false
        snap.faceTracked = sample?.faceTracked ?? false
        snap.frameIndex = frameIndex
        snap.quality = report
        snap.sessionDuration = report?.sessionDuration ?? 0
        snap.fps = report?.measuredFPS ?? 0
        if let cfg = sessionController.currentConfiguration {
            let f = cfg.videoFormat
            snap.videoFormatLabel = "\(Int(f.imageResolution.width))x\(Int(f.imageResolution.height)) @ \(f.framesPerSecond)"
            snap.lightEstimationEnabled = cfg.isLightEstimationEnabled
        }
        snap.lifecycleEvents = Array(lifecycleLog.suffix(60))
        snap.frameIntervalHistory = quality.recentFrameIntervals(count: n)
        snap.trackedTransitions = quality.trackedTransitions
        snap.camera = sample?.camera
        snap.light = sample?.light
        snap.derived = lastDerived

        snap.coefficients = blendShapes.orderedIdentifiers.compactMap { id -> CoefficientSnapshot? in
            guard let st = blendShapes.states[id] else { return nil }
            let dyn = temporal.dynamics[id]
            return CoefficientSnapshot(
                id: id, name: st.name, category: st.category, side: st.side,
                value: st.value, minimum: st.minimum, maximum: st.maximum, mean: st.mean,
                delta: st.delta, velocity: st.velocity,
                firstDerivative: dyn?.firstDerivative, secondDerivative: dyn?.secondDerivative,
                isActive: dyn?.isActive ?? false, activationCount: dyn?.activationCount ?? 0,
                windowMin: dyn?.windowMin ?? st.value, windowMax: dyn?.windowMax ?? st.value,
                windowMean: dyn?.windowMean ?? st.value, windowStd: dyn?.windowStd ?? 0,
                history: blendShapes.recentValues(for: id, count: n)
            )
        }

        if let head = sample?.head {
            snap.head = HeadSnapshot(
                reading: head, metrics: headMetrics,
                pitchHistory: headPose.recent("pitch", count: n),
                yawHistory: headPose.recent("yaw", count: n),
                rollHistory: headPose.recent("roll", count: n),
                angularSpeedHistory: headPose.recent("angularSpeed", count: n)
            )
        }
        if let eyes = sample?.eyes {
            snap.eyes = EyeSnapshot(
                reading: eyes, metrics: gazeMetrics,
                gazeYawHistory: eyeTracking.recent("gazeYaw", count: n),
                gazePitchHistory: eyeTracking.recent("gazePitch", count: n),
                gazeSpeedHistory: eyeTracking.recent("gazeSpeed", count: n)
            )
        }
        snap.blink = BlinkSnapshot(
            statistics: blinkStats,
            recentEvents: Array(blinks.events.suffix(30)),
            leftBlinkHistory: blendShapes.recentValues(for: eyeBlinkLeftID, count: n),
            rightBlinkHistory: blendShapes.recentValues(for: eyeBlinkRightID, count: n)
        )
        snap.temporal = TemporalSnapshot(
            metrics: lastTemporal,
            activityHistory: temporal.recent("activity", count: n),
            meanActivationHistory: temporal.recent("meanActivation", count: n),
            totalVariationHistory: temporal.recent("totalVariation", count: n),
            totalActivationEvents: temporal.totalActivationCount,
            lowActivityPeriodCount: temporal.lowActivityPeriods.count + (temporal.currentLowActivity == nil ? 0 : 1),
            recentActivations: Array(temporal.completedEvents.suffix(20)),
            configuration: temporal.configuration
        )
        var windowed: [String: Float] = [:]
        var histories: [String: [Float]] = [:]
        for g in asymmetry.groupValues {
            windowed[g.group] = asymmetry.windowedMeanAbsolute(group: g.group)
            histories[g.group] = asymmetry.recent(g.group, count: n)
        }
        snap.asymmetry = AsymmetrySnapshot(pairs: asymmetry.pairs, groups: asymmetry.groupValues,
                                           windowedMeanAbsolute: windowed, histories: histories)
        snap.geometry = GeometrySnapshot(
            reading: sample?.geometry,
            meshUpdateCount: geometry.meshUpdateCount,
            secondsSinceLastMeshUpdate: geometry.lastMeshUpdateTimestamp.map { (sample?.timestamp ?? $0) - $0 },
            hasReferenceMesh: geometry.referenceMesh() != nil
        )
        return snap
    }

    // MARK: Raw frame readings

    static func cameraReading(from frame: ARFrame) -> CameraReading {
        let cam = frame.camera
        let (state, reason) = ARSessionController.code(for: cam.trackingState)
        var exif: [String: Double] = [:]
        if #available(iOS 16.0, *) {
            FaceTrackingManager.collectExif(frame.exifData, into: &exif)
        }
        return CameraReading(
            trackingState: state,
            limitedReason: reason,
            transform: cam.transform,
            intrinsics: cam.intrinsics,
            imageResolution: cam.imageResolution,
            exposureDuration: cam.exposureDuration,
            exposureOffset: cam.exposureOffset,
            depthDataAvailable: frame.capturedDepthData != nil,
            depthDataTimestamp: frame.capturedDepthData != nil ? frame.capturedDepthDataTimestamp : nil,
            exif: exif
        )
    }

    private static let exifKeysOfInterest: Set<String> = [
        "ExposureTime", "FNumber", "ISOSpeedRatings", "BrightnessValue", "ApertureValue",
        "ShutterSpeedValue", "FocalLength", "ExposureBiasValue", "WhiteBalance"
    ]

    private static func collectExif(_ dict: [String: Any], into out: inout [String: Double]) {
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                collectExif(nested, into: &out)
                continue
            }
            guard exifKeysOfInterest.contains(key) else { continue }
            if let n = value as? NSNumber {
                out[key] = n.doubleValue
            } else if let arr = value as? [NSNumber], let first = arr.first {
                out[key] = first.doubleValue
            }
        }
    }

    static func lightReading(from frame: ARFrame) -> LightReading? {
        guard let estimate = frame.lightEstimate else { return nil }
        var reading = LightReading(
            ambientIntensity: Float(estimate.ambientIntensity),
            ambientColorTemperature: Float(estimate.ambientColorTemperature),
            primaryLightDirection: nil,
            primaryLightIntensity: nil
        )
        if let directional = estimate as? ARDirectionalLightEstimate {
            reading.primaryLightDirection = directional.primaryLightDirection
            reading.primaryLightIntensity = Float(directional.primaryLightIntensity)
        }
        return reading
    }
}
