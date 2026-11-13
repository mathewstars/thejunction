import Foundation
import simd

/// One exported column with its documentation, written into the session manifest so a reader
/// of the CSV knows the unit and the origin (raw ARKit vs. application-derived) of each value.
struct ExportColumn: Codable {
    let name: String
    let unit: String
    let origin: String      // "arkit" or "derived"
    let description: String
}

/// Builds the CSV header and one row per FaceSample. Missing values are written as empty cells,
/// never as zero.
final class CSVExporter {

    let blendShapeIdentifiers: [String]
    let columns: [ExportColumn]

    init(blendShapeIdentifiers: [String]) {
        self.blendShapeIdentifiers = blendShapeIdentifiers
        self.columns = CSVExporter.buildColumns(blendShapeIdentifiers: blendShapeIdentifiers)
    }

    var headerLine: String {
        columns.map { $0.name }.joined(separator: ",") + "\n"
    }

    // MARK: Formatting helpers

    @inline(__always) static func f(_ v: Float?) -> String {
        guard let v, v.isFinite else { return "" }
        return "\(v)"
    }
    @inline(__always) static func d(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return "\(v)"
    }
    @inline(__always) static func i(_ v: Int?) -> String { v.map { String($0) } ?? "" }
    @inline(__always) static func b(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "" }
    static func s(_ v: String?) -> String {
        guard let v else { return "" }
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
    static func vec3(_ v: SIMD3<Float>?, into out: inout [String]) {
        if let v { out.append(f(v.x)); out.append(f(v.y)); out.append(f(v.z)) }
        else { out.append(""); out.append(""); out.append("") }
    }
    static func mat4(_ m: simd_float4x4?, into out: inout [String]) {
        if let m { for x in MathSupport.rowMajor(m) { out.append(f(x)) } }
        else { for _ in 0..<16 { out.append("") } }
    }

    // MARK: Row

    func row(for sample: FaceSample, sampleIndex: Int, recordingStartTimestamp: Double) -> String {
        var out: [String] = []
        out.reserveCapacity(columns.count)
        let h = sample.head
        let e = sample.eyes
        let dm = sample.derived
        let t = dm?.temporal

        out.append(String(sampleIndex))
        out.append(String(sample.frameIndex))
        out.append(CSVExporter.d(sample.timestamp))
        out.append(CSVExporter.d(sample.timestamp - recordingStartTimestamp))
        out.append(CSVExporter.d(sample.wallClock.timeIntervalSince1970))
        out.append(CSVExporter.d(sample.frameInterval))
        out.append(String(sample.droppedFrameEstimate))
        out.append(CSVExporter.b(sample.faceAnchorPresent))
        out.append(CSVExporter.b(sample.faceTracked))
        out.append(sample.camera.trackingState.rawValue)
        out.append(CSVExporter.s(sample.camera.limitedReason))
        out.append(CSVExporter.s(sample.activeMarker))

        // Head
        CSVExporter.mat4(h?.worldTransform, into: &out)
        CSVExporter.vec3(h?.worldPosition, into: &out)
        CSVExporter.vec3(h?.worldEuler, into: &out)
        CSVExporter.vec3(h?.viewPosition, into: &out)
        CSVExporter.vec3(h?.viewEuler, into: &out)
        out.append(CSVExporter.f(h?.distanceToCamera))
        CSVExporter.vec3(h?.relativePosition, into: &out)
        CSVExporter.vec3(h?.relativeEuler, into: &out)
        CSVExporter.vec3(h?.angularVelocity, into: &out)
        CSVExporter.vec3(h?.angularAcceleration, into: &out)
        CSVExporter.vec3(h?.linearVelocity, into: &out)

        // Eyes
        CSVExporter.mat4(e?.leftTransform, into: &out)
        CSVExporter.mat4(e?.rightTransform, into: &out)
        CSVExporter.vec3(e?.leftForwardAnchor, into: &out)
        CSVExporter.vec3(e?.rightForwardAnchor, into: &out)
        out.append(CSVExporter.f(e?.leftYawDegrees))
        out.append(CSVExporter.f(e?.leftPitchDegrees))
        out.append(CSVExporter.f(e?.rightYawDegrees))
        out.append(CSVExporter.f(e?.rightPitchDegrees))
        CSVExporter.vec3(e?.lookAtPointAnchor, into: &out)
        CSVExporter.vec3(e?.gazeDirectionAnchor, into: &out)
        CSVExporter.vec3(e?.gazeDirectionView, into: &out)
        CSVExporter.vec3(e?.gazeDirectionWorld, into: &out)
        out.append(CSVExporter.f(e?.gazeYawDegrees))
        out.append(CSVExporter.f(e?.gazePitchDegrees))
        out.append(CSVExporter.f(e?.leftRightDivergenceDegrees))
        out.append(CSVExporter.f(e?.gazePlaneHit?.x))
        out.append(CSVExporter.f(e?.gazePlaneHit?.y))
        out.append(CSVExporter.f(e?.gazeAngularSpeed))

        // Blend shapes
        for id in blendShapeIdentifiers {
            out.append(CSVExporter.f(sample.blendShapes[id]))
        }

        // Derived
        out.append(CSVExporter.f(t?.facialActivity))
        out.append(CSVExporter.f(t?.totalVariation))
        out.append(CSVExporter.f(t?.movementAmplitude))
        out.append(CSVExporter.f(t?.movementFrequencyHz))
        out.append(CSVExporter.f(t?.meanActivation))
        out.append(CSVExporter.f(t?.activationStd))
        out.append(CSVExporter.f(t?.activationVariance))
        out.append(CSVExporter.f(t?.transitionRate))
        out.append(CSVExporter.i(t?.activeCoefficientCount))
        out.append(CSVExporter.b(t?.lowActivity))
        out.append(CSVExporter.b(dm?.blinkInProgress))
        out.append(CSVExporter.i(dm?.blinkCount))
        out.append(CSVExporter.f(dm?.blinkRatePerMinute))
        for g in CSVExporter.asymmetryGroups {
            out.append(CSVExporter.f(dm?.asymmetry[g]))
        }
        out.append(CSVExporter.f(dm?.headSpeed))
        out.append(CSVExporter.f(dm?.headMovementAmplitude))
        out.append(CSVExporter.f(dm?.headMovementFrequencyHz))
        out.append(CSVExporter.f(dm?.headVariability))
        out.append(CSVExporter.f(dm?.headStability))
        out.append(CSVExporter.f(dm?.gazeVariability))
        out.append(CSVExporter.f(dm?.qualityScore))

        // Geometry summary
        out.append(CSVExporter.i(sample.geometry?.vertexCount))
        out.append(CSVExporter.f(sample.geometry?.meanVertexDisplacement))
        out.append(CSVExporter.f(sample.geometry?.maxVertexDisplacement))

        // Environment and camera
        out.append(CSVExporter.f(sample.light?.ambientIntensity))
        out.append(CSVExporter.f(sample.light?.ambientColorTemperature))
        out.append(CSVExporter.f(sample.light?.primaryLightIntensity))
        CSVExporter.vec3(sample.light?.primaryLightDirection, into: &out)
        out.append(CSVExporter.d(sample.camera.exposureDuration))
        out.append(CSVExporter.f(sample.camera.exposureOffset))
        out.append(CSVExporter.b(sample.camera.depthDataAvailable))
        out.append(CSVExporter.d(sample.camera.depthDataTimestamp))
        out.append(CSVExporter.d(sample.camera.exif["ExposureTime"]))
        out.append(CSVExporter.d(sample.camera.exif["ISOSpeedRatings"]))
        out.append(CSVExporter.d(sample.camera.exif["BrightnessValue"]))
        let k = sample.camera.intrinsics
        out.append(CSVExporter.f(k.columns.0.x))
        out.append(CSVExporter.f(k.columns.1.y))
        out.append(CSVExporter.f(k.columns.2.x))
        out.append(CSVExporter.f(k.columns.2.y))
        out.append(String(Int(sample.camera.imageResolution.width)))
        out.append(String(Int(sample.camera.imageResolution.height)))

        assert(out.count == columns.count, "CSV row has \(out.count) cells for \(columns.count) columns")
        return out.joined(separator: ",") + "\n"
    }

    static let asymmetryGroups = ["smile", "brow", "eye", "cheek", "mouth", "nose", "overall"]

    // MARK: Schema

    static func buildColumns(blendShapeIdentifiers: [String]) -> [ExportColumn] {
        var c: [ExportColumn] = []
        func add(_ name: String, _ unit: String, _ origin: String, _ desc: String) {
            c.append(ExportColumn(name: name, unit: unit, origin: origin, description: desc))
        }
        func addVec3(_ prefix: String, _ unit: String, _ origin: String, _ desc: String) {
            for axis in ["x", "y", "z"] { add("\(prefix)_\(axis)", unit, origin, desc) }
        }
        func addEuler(_ prefix: String, _ origin: String, _ desc: String) {
            add("\(prefix)_pitch_rad", "rad", origin, desc + " Pitch is rotation about X.")
            add("\(prefix)_yaw_rad", "rad", origin, desc + " Yaw is rotation about Y.")
            add("\(prefix)_roll_rad", "rad", origin, desc + " Roll is rotation about Z.")
        }
        func addMat4(_ prefix: String, _ origin: String, _ desc: String) {
            for r in 0..<4 { for col in 0..<4 { add("\(prefix)_m\(r)\(col)", "", origin, desc + " Row-major element m\(r)\(col).") } }
        }

        add("sample_index", "", "app", "Index of this row in the recording (0-based).")
        add("frame_index", "", "app", "Index of the ARFrame since tracking started.")
        add("timestamp_s", "s", "arkit", "ARFrame.timestamp, device uptime clock.")
        add("recording_time_s", "s", "derived", "timestamp_s minus the first recorded sample's timestamp.")
        add("wall_clock_unix_s", "s", "app", "Wall-clock time when the frame was processed, Unix epoch.")
        add("frame_interval_s", "s", "derived", "Seconds since the previous ARFrame (empty for the first frame).")
        add("dropped_frames_est", "", "derived", "round(frame_interval / expected_interval) - 1 when the interval was long, else 0.")
        add("face_anchor_present", "0/1", "arkit", "An ARFaceAnchor existed on this frame.")
        add("face_tracked", "0/1", "arkit", "ARFaceAnchor.isTracked. Face columns are empty when 0.")
        add("camera_tracking_state", "", "arkit", "ARCamera.trackingState: notAvailable, limited, normal.")
        add("camera_limited_reason", "", "arkit", "ARCamera.TrackingState.Reason when limited.")
        add("active_marker", "", "app", "Label of the researcher's held interval marker at this sample, if any.")

        addMat4("head_world", "arkit", "ARFaceAnchor.transform in ARKit world space (gravity-aligned).")
        addVec3("head_world_pos", "m", "arkit", "Translation of the face anchor in world space.")
        addEuler("head_world", "derived", "Euler angles decomposed from the world transform.")
        addVec3("head_view_pos", "m", "derived", "Face position in portrait camera view space (+X right, +Y up, camera looks down -Z).")
        addEuler("head_view", "derived", "Euler angles of the face relative to the portrait camera view.")
        add("head_distance_m", "m", "derived", "Distance from camera to face anchor origin.")
        addVec3("head_rel_pos", "m", "derived", "View-space position minus the baseline pose captured at start or reset.")
        addEuler("head_rel", "derived", "View-space Euler minus the baseline pose.")
        addVec3("head_ang_vel", "rad/s", "derived", "Finite difference of view-space Euler angles.")
        addVec3("head_ang_acc", "rad/s^2", "derived", "Finite difference of angular velocity.")
        addVec3("head_lin_vel", "m/s", "derived", "Finite difference of view-space position.")

        addMat4("eye_left", "arkit", "ARFaceAnchor.leftEyeTransform, relative to the face anchor.")
        addMat4("eye_right", "arkit", "ARFaceAnchor.rightEyeTransform, relative to the face anchor.")
        addVec3("eye_left_fwd", "", "derived", "+Z axis of the left eye transform (viewing direction) in face-anchor space.")
        addVec3("eye_right_fwd", "", "derived", "+Z axis of the right eye transform in face-anchor space.")
        add("eye_left_yaw_deg", "deg", "derived", "Left eye forward direction yaw in camera view space (0 = toward camera).")
        add("eye_left_pitch_deg", "deg", "derived", "Left eye forward direction pitch in camera view space.")
        add("eye_right_yaw_deg", "deg", "derived", "Right eye forward direction yaw in camera view space.")
        add("eye_right_pitch_deg", "deg", "derived", "Right eye forward direction pitch in camera view space.")
        addVec3("look_at", "m", "arkit", "ARFaceAnchor.lookAtPoint in face-anchor space.")
        addVec3("gaze_anchor", "", "derived", "Unit vector from eye midpoint to lookAtPoint, face-anchor space.")
        addVec3("gaze_view", "", "derived", "Gaze direction in portrait camera view space.")
        addVec3("gaze_world", "", "derived", "Gaze direction in ARKit world space.")
        add("gaze_yaw_deg", "deg", "derived", "Gaze yaw in camera view space (0 = toward camera, positive = toward +X).")
        add("gaze_pitch_deg", "deg", "derived", "Gaze pitch in camera view space (positive = up).")
        add("gaze_divergence_deg", "deg", "derived", "Angle between left and right eye forward vectors.")
        add("gaze_plane_hit_x_m", "m", "derived", "Where the gaze ray crosses the camera plane (z=0), metres right of the camera. Approximate.")
        add("gaze_plane_hit_y_m", "m", "derived", "Where the gaze ray crosses the camera plane, metres above the camera. Approximate.")
        add("gaze_speed_deg_s", "deg/s", "derived", "Angular speed of the gaze direction.")

        for id in blendShapeIdentifiers {
            add("bs_\(id)", "0-1", "arkit", "ARFaceAnchor.blendShapes[\(id)] (\(BlendShapeCatalog.friendlyName(for: id))).")
        }

        add("facial_activity", "1/s", "derived", "Mean |d/dt| across all blend-shape coefficients.")
        add("total_variation", "", "derived", "Sum of |delta| across coefficients for this frame.")
        add("movement_amplitude", "", "derived", "Mean over coefficients of (window max - window min).")
        add("movement_frequency_hz", "Hz", "derived", "Zero-crossing rate of the mean-removed mean-activation signal in the window.")
        add("mean_activation", "", "derived", "Mean of all coefficient values on this frame.")
        add("activation_std", "", "derived", "Std of the mean-activation signal in the window.")
        add("activation_variance", "", "derived", "Variance of the mean-activation signal in the window.")
        add("transition_rate", "1/s", "derived", "Hysteresis activation onsets per second in the window.")
        add("active_coefficients", "", "derived", "Coefficients currently above the activation threshold.")
        add("low_activity", "0/1", "derived", "Inside a low-activity period.")
        add("blink_in_progress", "0/1", "derived", "A blink event is open on this frame.")
        add("blink_count", "", "derived", "Cumulative blinks detected since tracking started.")
        add("blink_rate_per_min", "1/min", "derived", "Blinks per minute over the rate window.")
        for g in asymmetryGroups {
            add("asym_\(g)", "", "derived", g == "overall" ? "Mean |left - right| across all pairs." : "Mean (left - right) over the \(g) coefficient pairs.")
        }
        add("head_speed_rad_s", "rad/s", "derived", "|angular velocity| of the head.")
        add("head_amplitude_rad", "rad", "derived", "Mean over pitch/yaw/roll of window range.")
        add("head_frequency_hz", "Hz", "derived", "Zero-crossing rate of mean-removed yaw+pitch in the window.")
        add("head_variability_rad", "rad", "derived", "Mean std of pitch/yaw/roll in the window.")
        add("head_stability", "0-1", "derived", "1 - clamp(variability / 0.05 rad).")
        add("gaze_variability_deg", "deg", "derived", "Mean std of gaze yaw and pitch in the window.")
        add("quality_score", "0-1", "derived", TrackingQualityReport.qualityScoreFormula)

        add("mesh_vertex_count", "", "arkit", "ARFaceGeometry.vertexCount.")
        add("mesh_mean_displacement_m", "m", "derived", "Mean vertex displacement since the previous frame.")
        add("mesh_max_displacement_m", "m", "derived", "Largest vertex displacement since the previous frame.")

        add("light_ambient_intensity", "lumen", "arkit", "ARLightEstimate.ambientIntensity (1000 = neutral).")
        add("light_color_temperature_k", "K", "arkit", "ARLightEstimate.ambientColorTemperature.")
        add("light_primary_intensity", "lumen", "arkit", "ARDirectionalLightEstimate.primaryLightIntensity.")
        addVec3("light_primary_dir", "", "arkit", "ARDirectionalLightEstimate.primaryLightDirection.")
        add("camera_exposure_duration_s", "s", "arkit", "ARCamera.exposureDuration.")
        add("camera_exposure_offset", "EV", "arkit", "ARCamera.exposureOffset.")
        add("depth_data_available", "0/1", "arkit", "ARFrame.capturedDepthData was non-nil (not stored).")
        add("depth_data_timestamp_s", "s", "arkit", "ARFrame.capturedDepthDataTimestamp.")
        add("exif_exposure_time", "s", "arkit", "ARFrame.exifData ExposureTime.")
        add("exif_iso", "", "arkit", "ARFrame.exifData ISOSpeedRatings.")
        add("exif_brightness", "", "arkit", "ARFrame.exifData BrightnessValue.")
        add("camera_fx", "px", "arkit", "ARCamera.intrinsics focal length x.")
        add("camera_fy", "px", "arkit", "ARCamera.intrinsics focal length y.")
        add("camera_cx", "px", "arkit", "ARCamera.intrinsics principal point x.")
        add("camera_cy", "px", "arkit", "ARCamera.intrinsics principal point y.")
        add("image_width", "px", "arkit", "ARCamera.imageResolution width.")
        add("image_height", "px", "arkit", "ARCamera.imageResolution height.")
        return c
    }
}
