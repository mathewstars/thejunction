import Foundation
import simd

/// Minimal streaming JSON object builder. Avoids JSONEncoder per sample at 30-60 Hz and gives
/// explicit control over nulls: missing measurements become `null`, never 0.
struct JSONObjectWriter {
    private var parts: [String] = []

    static func escape(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    @inline(__always) private static func num(_ v: Float?) -> String {
        guard let v, v.isFinite else { return "null" }
        return "\(v)"
    }
    @inline(__always) private static func num(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "null" }
        return "\(v)"
    }

    mutating func add(_ key: String, _ value: Float?) { parts.append("\(JSONObjectWriter.escape(key)):\(JSONObjectWriter.num(value))") }
    mutating func add(_ key: String, _ value: Double?) { parts.append("\(JSONObjectWriter.escape(key)):\(JSONObjectWriter.num(value))") }
    mutating func add(_ key: String, _ value: Int?) { parts.append("\(JSONObjectWriter.escape(key)):\(value.map { String($0) } ?? "null")") }
    mutating func add(_ key: String, _ value: Bool?) { parts.append("\(JSONObjectWriter.escape(key)):\(value.map { $0 ? "true" : "false" } ?? "null")") }
    mutating func add(_ key: String, _ value: String?) { parts.append("\(JSONObjectWriter.escape(key)):\(value.map { JSONObjectWriter.escape($0) } ?? "null")") }
    mutating func add(_ key: String, vec: SIMD3<Float>?) {
        if let v = vec {
            parts.append("\(JSONObjectWriter.escape(key)):[\(JSONObjectWriter.num(v.x)),\(JSONObjectWriter.num(v.y)),\(JSONObjectWriter.num(v.z))]")
        } else { parts.append("\(JSONObjectWriter.escape(key)):null") }
    }
    mutating func add(_ key: String, vec2: SIMD2<Float>?) {
        if let v = vec2 {
            parts.append("\(JSONObjectWriter.escape(key)):[\(JSONObjectWriter.num(v.x)),\(JSONObjectWriter.num(v.y))]")
        } else { parts.append("\(JSONObjectWriter.escape(key)):null") }
    }
    mutating func add(_ key: String, mat: simd_float4x4?) {
        if let m = mat {
            parts.append("\(JSONObjectWriter.escape(key)):[" + MathSupport.rowMajor(m).map { JSONObjectWriter.num($0) }.joined(separator: ",") + "]")
        } else { parts.append("\(JSONObjectWriter.escape(key)):null") }
    }
    mutating func add(_ key: String, floats: [Float]?) {
        if let a = floats {
            parts.append("\(JSONObjectWriter.escape(key)):[" + a.map { JSONObjectWriter.num($0) }.joined(separator: ",") + "]")
        } else { parts.append("\(JSONObjectWriter.escape(key)):null") }
    }
    mutating func add(_ key: String, object: JSONObjectWriter?) {
        parts.append("\(JSONObjectWriter.escape(key)):\(object?.render() ?? "null")")
    }
    mutating func add(_ key: String, dictionary: [String: Float]) {
        var w = JSONObjectWriter()
        for k in dictionary.keys.sorted() { w.add(k, dictionary[k]) }
        add(key, object: w)
    }

    func render() -> String { "{" + parts.joined(separator: ",") + "}" }
}

/// Produces the per-sample JSON object written into samples.json.
enum JSONExporter {

    static func sampleObject(_ s: FaceSample, sampleIndex: Int, recordingStartTimestamp: Double) -> String {
        var w = JSONObjectWriter()
        w.add("sample_index", sampleIndex)
        w.add("frame_index", s.frameIndex)
        w.add("timestamp_s", s.timestamp)
        w.add("recording_time_s", s.timestamp - recordingStartTimestamp)
        w.add("wall_clock_unix_s", s.wallClock.timeIntervalSince1970)
        w.add("frame_interval_s", s.frameInterval)
        w.add("dropped_frames_est", s.droppedFrameEstimate)
        w.add("face_anchor_present", s.faceAnchorPresent)
        w.add("face_tracked", s.faceTracked)
        w.add("active_marker", s.activeMarker)

        var cam = JSONObjectWriter()
        cam.add("tracking_state", s.camera.trackingState.rawValue)
        cam.add("limited_reason", s.camera.limitedReason)
        cam.add("transform", mat: s.camera.transform)
        let k = s.camera.intrinsics
        cam.add("intrinsics_fx_fy_cx_cy", floats: [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y])
        cam.add("image_width", Int(s.camera.imageResolution.width))
        cam.add("image_height", Int(s.camera.imageResolution.height))
        cam.add("exposure_duration_s", s.camera.exposureDuration)
        cam.add("exposure_offset", s.camera.exposureOffset)
        cam.add("depth_data_available", s.camera.depthDataAvailable)
        cam.add("depth_data_timestamp_s", s.camera.depthDataTimestamp)
        var exif = JSONObjectWriter()
        for key in s.camera.exif.keys.sorted() { exif.add(key, s.camera.exif[key]) }
        cam.add("exif", object: exif)
        w.add("camera", object: cam)

        if let l = s.light {
            var lw = JSONObjectWriter()
            lw.add("ambient_intensity", l.ambientIntensity)
            lw.add("ambient_color_temperature_k", l.ambientColorTemperature)
            lw.add("primary_light_intensity", l.primaryLightIntensity)
            lw.add("primary_light_direction", vec: l.primaryLightDirection)
            w.add("light", object: lw)
        } else { w.add("light", object: nil) }

        if s.faceTracked {
            var bs = JSONObjectWriter()
            for id in s.blendShapes.keys.sorted() { bs.add(id, s.blendShapes[id]) }
            w.add("blend_shapes", object: bs)
        } else { w.add("blend_shapes", object: nil) }

        if let h = s.head {
            var hw = JSONObjectWriter()
            hw.add("world_transform", mat: h.worldTransform)
            hw.add("world_position_m", vec: h.worldPosition)
            hw.add("world_euler_rad_pitch_yaw_roll", vec: h.worldEuler)
            hw.add("view_transform", mat: h.viewTransform)
            hw.add("view_position_m", vec: h.viewPosition)
            hw.add("view_euler_rad_pitch_yaw_roll", vec: h.viewEuler)
            hw.add("distance_to_camera_m", h.distanceToCamera)
            hw.add("relative_position_m", vec: h.relativePosition)
            hw.add("relative_euler_rad", vec: h.relativeEuler)
            hw.add("angular_velocity_rad_s", vec: h.angularVelocity)
            hw.add("angular_acceleration_rad_s2", vec: h.angularAcceleration)
            hw.add("linear_velocity_m_s", vec: h.linearVelocity)
            w.add("head", object: hw)
        } else { w.add("head", object: nil) }

        if let e = s.eyes {
            var ew = JSONObjectWriter()
            ew.add("left_transform", mat: e.leftTransform)
            ew.add("right_transform", mat: e.rightTransform)
            ew.add("left_position_m", vec: e.leftPosition)
            ew.add("right_position_m", vec: e.rightPosition)
            ew.add("left_forward_anchor", vec: e.leftForwardAnchor)
            ew.add("right_forward_anchor", vec: e.rightForwardAnchor)
            ew.add("left_euler_rad", vec: e.leftEulerAnchor)
            ew.add("right_euler_rad", vec: e.rightEulerAnchor)
            ew.add("look_at_point_m", vec: e.lookAtPointAnchor)
            ew.add("gaze_direction_anchor", vec: e.gazeDirectionAnchor)
            ew.add("gaze_direction_view", vec: e.gazeDirectionView)
            ew.add("gaze_direction_world", vec: e.gazeDirectionWorld)
            ew.add("gaze_yaw_deg", e.gazeYawDegrees)
            ew.add("gaze_pitch_deg", e.gazePitchDegrees)
            ew.add("left_yaw_deg", e.leftYawDegrees)
            ew.add("left_pitch_deg", e.leftPitchDegrees)
            ew.add("right_yaw_deg", e.rightYawDegrees)
            ew.add("right_pitch_deg", e.rightPitchDegrees)
            ew.add("left_right_divergence_deg", e.leftRightDivergenceDegrees)
            ew.add("gaze_plane_hit_m", vec2: e.gazePlaneHit)
            ew.add("gaze_angular_speed_deg_s", e.gazeAngularSpeed)
            w.add("eyes", object: ew)
        } else { w.add("eyes", object: nil) }

        if let g = s.geometry {
            var gw = JSONObjectWriter()
            gw.add("vertex_count", g.vertexCount)
            gw.add("triangle_count", g.triangleCount)
            gw.add("texture_coordinate_count", g.textureCoordinateCount)
            gw.add("bounding_box_min_m", vec: g.boundingBoxMin)
            gw.add("bounding_box_max_m", vec: g.boundingBoxMax)
            gw.add("mean_vertex_displacement_m", g.meanVertexDisplacement)
            gw.add("max_vertex_displacement_m", g.maxVertexDisplacement)
            w.add("geometry", object: gw)
        } else { w.add("geometry", object: nil) }

        if let d = s.derived {
            var dw = JSONObjectWriter()
            if let t = d.temporal {
                var tw = JSONObjectWriter()
                tw.add("facial_activity", t.facialActivity)
                tw.add("total_variation", t.totalVariation)
                tw.add("movement_amplitude", t.movementAmplitude)
                tw.add("movement_frequency_hz", t.movementFrequencyHz)
                tw.add("mean_activation", t.meanActivation)
                tw.add("activation_std", t.activationStd)
                tw.add("activation_variance", t.activationVariance)
                tw.add("transition_rate", t.transitionRate)
                tw.add("active_coefficients", t.activeCoefficientCount)
                tw.add("low_activity", t.lowActivity)
                tw.add("low_activity_duration_s", t.lowActivityDuration)
                dw.add("temporal", object: tw)
            } else { dw.add("temporal", object: nil) }
            dw.add("blink_in_progress", d.blinkInProgress)
            dw.add("blink_count", d.blinkCount)
            dw.add("blink_rate_per_min", d.blinkRatePerMinute)
            dw.add("asymmetry", dictionary: d.asymmetry)
            dw.add("head_speed_rad_s", d.headSpeed)
            dw.add("head_movement_amplitude_rad", d.headMovementAmplitude)
            dw.add("head_movement_frequency_hz", d.headMovementFrequencyHz)
            dw.add("head_variability_rad", d.headVariability)
            dw.add("head_stability", d.headStability)
            dw.add("gaze_variability_deg", d.gazeVariability)
            dw.add("quality_score", d.qualityScore)
            w.add("derived", object: dw)
        } else { w.add("derived", object: nil) }

        return w.render()
    }
}

// MARK: - Session manifest (session.json)

struct SessionManifest: Codable {
    struct AppInfo: Codable { var name: String; var version: String; var build: String }
    struct DeviceInfo: Codable { var model: String; var systemName: String; var systemVersion: String }
    struct TrackingSetup: Codable {
        var videoFormat: String
        var framesPerSecond: Int
        var lightEstimationEnabled: Bool
        var expectedFrameIntervalSeconds: Double
        var supportsWorldTracking: Bool
        var supportedNumberOfTrackedFaces: Int
    }
    struct PauseInterval: Codable { var startTimestamp: Double; var endTimestamp: Double }
    struct CoefficientSummary: Codable { var minimum: Float; var maximum: Float; var mean: Float; var standardDeviation: Float; var count: Int }
    struct MarkerRecord: Codable {
        var id: String
        var label: String
        var kind: String
        var startTimestamp: Double
        var endTimestamp: Double?
        var recordingStartTime: Double?
        var recordingEndTime: Double?
        var startFrameIndex: Int
        var endFrameIndex: Int?
        var wallClock: Date
        var note: String?
    }
    struct BlinkRecord: Codable {
        var startTimestamp: Double
        var endTimestamp: Double
        var recordingStartTime: Double?
        var durationSeconds: Double
        var peakLeft: Float
        var peakRight: Float
        var peakAsymmetry: Float
        var onsetLagSeconds: Double?
        var bilateral: Bool
        var kind: String
        var interBlinkIntervalSeconds: Double?
    }
    struct LowActivityRecord: Codable { var startTimestamp: Double; var endTimestamp: Double?; var durationSeconds: Double }
    struct LifecycleRecord: Codable { var date: Date; var kind: String; var detail: String }
    struct Summary: Codable {
        var averageFPS: Double
        var trackedSampleFraction: Double
        var interruptions: Int
        var blinkCount: Int
        var closureCount: Int
        var activationEvents: Int
        var lowActivityPeriods: Int
        var unknownBlendShapeKeysSeen: Int
    }

    var formatVersion: Int = 1
    var id: String
    var app: AppInfo
    var device: DeviceInfo
    var createdAt: Date
    var endedAt: Date?
    var recordingStartTimestamp: Double?
    var recordingEndTimestamp: Double?
    var durationSeconds: Double
    var configuration: RecordingConfiguration
    var tracking: TrackingSetup
    var sampleCount: Int
    var trackedSampleCount: Int
    var framesSeen: Int
    var framesSkippedByRateLimit: Int
    var droppedFramesEstimate: Int
    var pauses: [PauseInterval]
    var blendShapeIdentifiers: [String]
    var blendShapeFriendlyNames: [String: String]
    var columns: [ExportColumn]
    var coefficientStatistics: [String: CoefficientSummary]
    var markers: [MarkerRecord]
    var blinkEvents: [BlinkRecord]
    var lowActivityPeriods: [LowActivityRecord]
    var lifecycle: [LifecycleRecord]
    var summary: Summary
    var files: [String]
    var notes: [String]

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
