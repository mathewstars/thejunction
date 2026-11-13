import Foundation
import simd
import CoreGraphics

// MARK: - Raw ARKit readings
//
// Everything in this file is a plain value copied out of an ARFrame / ARFaceAnchor inside the
// session delegate callback. No ARKit objects are retained, so ARKit keeps delivering frames.

enum CameraTrackingStateCode: String, Codable {
    case notAvailable
    case limited
    case normal
}

struct CameraReading {
    var trackingState: CameraTrackingStateCode
    var limitedReason: String?
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    var imageResolution: CGSize
    var exposureDuration: Double
    var exposureOffset: Float
    var depthDataAvailable: Bool
    var depthDataTimestamp: Double?
    /// Selected EXIF values ARKit attaches to the frame (iOS 16+). Keys are EXIF names.
    var exif: [String: Double]
}

struct LightReading {
    var ambientIntensity: Float
    var ambientColorTemperature: Float
    var primaryLightDirection: SIMD3<Float>?
    var primaryLightIntensity: Float?
}

struct HeadPoseReading {
    /// Face anchor transform in ARKit world coordinates (gravity-aligned session origin).
    var worldTransform: simd_float4x4
    /// Face anchor transform in portrait camera view space: +X right, +Y up, camera looks down -Z.
    var viewTransform: simd_float4x4
    var worldPosition: SIMD3<Float>
    var viewPosition: SIMD3<Float>
    /// Pitch (X), yaw (Y), roll (Z) in radians from the world transform.
    var worldEuler: SIMD3<Float>
    /// Pitch, yaw, roll in radians relative to the portrait camera view.
    var viewEuler: SIMD3<Float>
    var distanceToCamera: Float
    /// Derived: finite difference of viewEuler, rad/s.
    var angularVelocity: SIMD3<Float>?
    /// Derived: finite difference of angularVelocity, rad/s^2.
    var angularAcceleration: SIMD3<Float>?
    /// Derived: finite difference of viewPosition, m/s.
    var linearVelocity: SIMD3<Float>?
    /// Derived: viewPosition minus the reference pose captured at baseline.
    var relativePosition: SIMD3<Float>?
    /// Derived: viewEuler minus the reference pose captured at baseline, wrapped.
    var relativeEuler: SIMD3<Float>?
}

struct EyeReading {
    /// Eye transforms are relative to the face anchor (ARKit: leftEyeTransform / rightEyeTransform).
    var leftTransform: simd_float4x4
    var rightTransform: simd_float4x4
    var leftPosition: SIMD3<Float>
    var rightPosition: SIMD3<Float>
    /// Derived: the +Z axis of each eye transform, in face-anchor space (direction the eye points).
    var leftForwardAnchor: SIMD3<Float>
    var rightForwardAnchor: SIMD3<Float>
    /// Derived: pitch/yaw/roll of each eye transform, radians, face-anchor space.
    var leftEulerAnchor: SIMD3<Float>
    var rightEulerAnchor: SIMD3<Float>
    /// Raw: ARFaceAnchor.lookAtPoint, face-anchor space, metres.
    var lookAtPointAnchor: SIMD3<Float>
    /// Derived: normalised (lookAtPoint - midpoint of the eyes), face-anchor space.
    var gazeDirectionAnchor: SIMD3<Float>
    /// Derived: gaze direction rotated into portrait camera view space.
    var gazeDirectionView: SIMD3<Float>
    /// Derived: gaze direction rotated into ARKit world space.
    var gazeDirectionWorld: SIMD3<Float>
    var leftForwardView: SIMD3<Float>
    var rightForwardView: SIMD3<Float>
    /// Derived: angle in degrees between the left and right eye forward vectors.
    var leftRightDivergenceDegrees: Float
    /// Derived: horizontal/vertical angle of the combined gaze in view space, degrees.
    var gazeYawDegrees: Float
    var gazePitchDegrees: Float
    var leftYawDegrees: Float
    var leftPitchDegrees: Float
    var rightYawDegrees: Float
    var rightPitchDegrees: Float
    /// Derived: where the gaze ray crosses the camera plane (z = 0 in view space), metres from the camera.
    /// nil when the gaze points away from the camera.
    var gazePlaneHit: SIMD2<Float>?
    /// Derived: angular speed of the combined gaze direction, deg/s.
    var gazeAngularSpeed: Float?
}

struct GeometryReading {
    var vertexCount: Int
    var triangleCount: Int
    var textureCoordinateCount: Int
    var boundingBoxMin: SIMD3<Float>
    var boundingBoxMax: SIMD3<Float>
    /// Derived: mean vertex displacement since the previous frame, metres.
    var meanVertexDisplacement: Float?
    /// Derived: largest single vertex displacement since the previous frame, metres.
    var maxVertexDisplacement: Float?
}

// MARK: - Derived metrics attached to a sample

struct TemporalMetrics {
    /// Mean |d/dt| across all coefficients, 1/s.
    var facialActivity: Float
    /// Sum of |delta| across all coefficients for this frame.
    var totalVariation: Float
    /// Mean over coefficients of (max - min) inside the window.
    var movementAmplitude: Float
    /// Zero-crossing rate of the mean-removed mean activation signal inside the window, Hz.
    var movementFrequencyHz: Float
    /// Mean coefficient value over all coefficients, this frame.
    var meanActivation: Float
    /// Standard deviation of the mean activation signal inside the window.
    var activationStd: Float
    /// Variance of the mean activation signal inside the window.
    var activationVariance: Float
    /// Onsets per second inside the window (hysteresis-based activation events).
    var transitionRate: Float
    /// Number of coefficients currently above the activation threshold.
    var activeCoefficientCount: Int
    /// True while the windowed activity has stayed below the low-activity threshold.
    var lowActivity: Bool
    /// Seconds the current low-activity period has lasted (0 when not in one).
    var lowActivityDuration: Float
}

struct DerivedMetrics {
    var temporal: TemporalMetrics?
    var blinkInProgress: Bool
    var blinkCount: Int
    var blinkRatePerMinute: Float?
    var asymmetry: [String: Float]
    var headSpeed: Float?
    var headMovementAmplitude: Float?
    var headMovementFrequencyHz: Float?
    var headVariability: Float?
    var headStability: Float?
    var gazeVariability: Float?
    var qualityScore: Float?
}

// MARK: - One processed frame

struct FaceSample {
    let frameIndex: Int
    /// ARFrame.timestamp: seconds on the device uptime clock.
    let timestamp: Double
    let wallClock: Date
    /// Seconds since the previous ARFrame, nil for the first frame.
    let frameInterval: Double?
    /// Application-derived: round(interval / expectedInterval) - 1 when an interval is long.
    let droppedFrameEstimate: Int
    let faceAnchorPresent: Bool
    let faceTracked: Bool
    /// Raw ARKit identifier (BlendShapeLocation.rawValue, e.g. "eyeBlink_L") to coefficient value.
    /// Empty when no face anchor is present.
    let blendShapes: [String: Float]
    let head: HeadPoseReading?
    let eyes: EyeReading?
    let geometry: GeometryReading?
    let camera: CameraReading
    let light: LightReading?
    var derived: DerivedMetrics?
    var activeMarker: String?
    /// Full mesh for this frame. Only attached while opt-in geometry recording is active.
    var mesh: FaceMeshData?
}
