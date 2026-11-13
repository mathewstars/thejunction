import Foundation
import simd

// Immutable value types handed to the UI at a throttled rate. Built on the tracking queue,
// read on the main thread. Nothing here references ARKit objects.

struct CoefficientSnapshot: Identifiable {
    let id: String
    let name: String
    let category: BlendShapeCategory
    let side: BlendShapeSide
    let value: Float
    let minimum: Float?
    let maximum: Float?
    let mean: Float?
    let delta: Float?
    let velocity: Float?
    let firstDerivative: Float?
    let secondDerivative: Float?
    let isActive: Bool
    let activationCount: Int
    let windowMin: Float
    let windowMax: Float
    let windowMean: Float
    let windowStd: Float
    let history: [Float]
}

struct HeadSnapshot {
    let reading: HeadPoseReading
    let metrics: HeadMovementMetrics?
    let pitchHistory: [Float]
    let yawHistory: [Float]
    let rollHistory: [Float]
    let angularSpeedHistory: [Float]
}

struct EyeSnapshot {
    let reading: EyeReading
    let metrics: GazeMetrics?
    let gazeYawHistory: [Float]
    let gazePitchHistory: [Float]
    let gazeSpeedHistory: [Float]
}

struct BlinkSnapshot {
    let statistics: BlinkStatistics
    let recentEvents: [BlinkEvent]
    let leftBlinkHistory: [Float]
    let rightBlinkHistory: [Float]
}

struct TemporalSnapshot {
    let metrics: TemporalMetrics?
    let activityHistory: [Float]
    let meanActivationHistory: [Float]
    let totalVariationHistory: [Float]
    let totalActivationEvents: Int
    let lowActivityPeriodCount: Int
    let recentActivations: [ActivationEvent]
    let configuration: TemporalConfiguration
}

struct AsymmetrySnapshot {
    let pairs: [AsymmetryPair]
    let groups: [AsymmetryGroupValue]
    let windowedMeanAbsolute: [String: Float]
    let histories: [String: [Float]]
}

struct GeometrySnapshot {
    let reading: GeometryReading?
    let meshUpdateCount: Int
    let secondsSinceLastMeshUpdate: Double?
    let hasReferenceMesh: Bool
}

struct TrackingSnapshot {
    var runState: ARSessionRunState = .idle
    var isSupported: Bool = true
    var errorMessage: String?
    var faceAnchorPresent: Bool = false
    var faceTracked: Bool = false
    var frameIndex: Int = 0
    var sessionDuration: Double = 0
    var fps: Double = 0
    var videoFormatLabel: String = ""
    var quality: TrackingQualityReport?
    var lifecycleEvents: [SessionLifecycleEvent] = []
    var frameIntervalHistory: [Float] = []
    var coefficients: [CoefficientSnapshot] = []
    var head: HeadSnapshot?
    var eyes: EyeSnapshot?
    var blink: BlinkSnapshot?
    var temporal: TemporalSnapshot?
    var asymmetry: AsymmetrySnapshot?
    var geometry: GeometrySnapshot?
    var camera: CameraReading?
    var light: LightReading?
    var derived: DerivedMetrics?
    var trackedTransitions: [(time: Double, tracked: Bool)] = []
    var lightEstimationEnabled: Bool = true

    static let empty = TrackingSnapshot()
}
