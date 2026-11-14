"""Generates a synthetic FaceMetrics session folder (samples.csv, session.json, geometry.bin, geometry.json).

The column list is transcribed from facemetrics/FaceMetrics/Recording/CSVExporter.swift (buildColumns), so the
header matches a real export cell for cell. Values are synthetic: a face that blinks every ~3.2 s, smiles during
a marker interval, moves its head gently, and looks around. It contains no measurement of a real person.

    python3 make_example_arkit_session.py --out arkit-session-synthetic --seconds 120 --fps 30 --seed 7 \
        --start-unix 1794604800 --start-uptime 73421.5

The relationship between uptime and wall clock is deliberately non-trivial (uptime 73421.5 s = phone booted ~20 h
earlier) so the alignment code has something to do.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import struct
from datetime import datetime, timedelta, timezone

# Alphabetical, like BlendShapeCatalog.sortedIdentifiers. The 52 ARKit identifiers (BlendShapeLocation.rawValue).
BLEND_SHAPES = sorted([
    "browDown_L", "browDown_R", "browInnerUp", "browOuterUp_L", "browOuterUp_R",
    "cheekPuff", "cheekSquint_L", "cheekSquint_R",
    "eyeBlink_L", "eyeBlink_R", "eyeLookDown_L", "eyeLookDown_R", "eyeLookIn_L", "eyeLookIn_R", "eyeLookOut_L", "eyeLookOut_R",
    "eyeLookUp_L", "eyeLookUp_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimple_L", "mouthDimple_R", "mouthFrown_L", "mouthFrown_R", "mouthFunnel", "mouthLeft", "mouthLowerDown_L",
    "mouthLowerDown_R", "mouthPress_L", "mouthPress_R", "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper",
    "mouthShrugLower", "mouthShrugUpper", "mouthSmile_L", "mouthSmile_R", "mouthStretch_L", "mouthStretch_R", "mouthUpperUp_L", "mouthUpperUp_R",
    "noseSneer_L", "noseSneer_R", "tongueOut",
])
assert len(BLEND_SHAPES) == 52

ASYM_GROUPS = ["smile", "brow", "eye", "cheek", "mouth", "nose", "overall"]


def build_columns() -> list[dict]:
    c: list[dict] = []

    def add(name, unit, origin, desc):
        c.append({"name": name, "unit": unit, "origin": origin, "description": desc})

    def vec3(prefix, unit, origin, desc):
        for a in "xyz":
            add(f"{prefix}_{a}", unit, origin, desc)

    def euler(prefix, origin, desc):
        add(f"{prefix}_pitch_rad", "rad", origin, desc + " Pitch is rotation about X.")
        add(f"{prefix}_yaw_rad", "rad", origin, desc + " Yaw is rotation about Y.")
        add(f"{prefix}_roll_rad", "rad", origin, desc + " Roll is rotation about Z.")

    def mat4(prefix, origin, desc):
        for r in range(4):
            for col in range(4):
                add(f"{prefix}_m{r}{col}", "", origin, desc + f" Row-major element m{r}{col}.")

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
    mat4("head_world", "arkit", "ARFaceAnchor.transform in ARKit world space (gravity-aligned).")
    vec3("head_world_pos", "m", "arkit", "Translation of the face anchor in world space.")
    euler("head_world", "derived", "Euler angles decomposed from the world transform.")
    vec3("head_view_pos", "m", "derived", "Face position in portrait camera view space.")
    euler("head_view", "derived", "Euler angles of the face relative to the portrait camera view.")
    add("head_distance_m", "m", "derived", "Distance from camera to face anchor origin.")
    vec3("head_rel_pos", "m", "derived", "View-space position minus the baseline pose.")
    euler("head_rel", "derived", "View-space Euler minus the baseline pose.")
    vec3("head_ang_vel", "rad/s", "derived", "Finite difference of view-space Euler angles.")
    vec3("head_ang_acc", "rad/s^2", "derived", "Finite difference of angular velocity.")
    vec3("head_lin_vel", "m/s", "derived", "Finite difference of view-space position.")
    mat4("eye_left", "arkit", "ARFaceAnchor.leftEyeTransform, relative to the face anchor.")
    mat4("eye_right", "arkit", "ARFaceAnchor.rightEyeTransform, relative to the face anchor.")
    vec3("eye_left_fwd", "", "derived", "+Z axis of the left eye transform in face-anchor space.")
    vec3("eye_right_fwd", "", "derived", "+Z axis of the right eye transform in face-anchor space.")
    add("eye_left_yaw_deg", "deg", "derived", "Left eye yaw in camera view space.")
    add("eye_left_pitch_deg", "deg", "derived", "Left eye pitch in camera view space.")
    add("eye_right_yaw_deg", "deg", "derived", "Right eye yaw in camera view space.")
    add("eye_right_pitch_deg", "deg", "derived", "Right eye pitch in camera view space.")
    vec3("look_at", "m", "arkit", "ARFaceAnchor.lookAtPoint in face-anchor space.")
    vec3("gaze_anchor", "", "derived", "Unit vector from eye midpoint to lookAtPoint, face-anchor space.")
    vec3("gaze_view", "", "derived", "Gaze direction in portrait camera view space.")
    vec3("gaze_world", "", "derived", "Gaze direction in ARKit world space.")
    add("gaze_yaw_deg", "deg", "derived", "Gaze yaw in camera view space.")
    add("gaze_pitch_deg", "deg", "derived", "Gaze pitch in camera view space.")
    add("gaze_divergence_deg", "deg", "derived", "Angle between left and right eye forward vectors.")
    add("gaze_plane_hit_x_m", "m", "derived", "Gaze ray crossing of the camera plane, x.")
    add("gaze_plane_hit_y_m", "m", "derived", "Gaze ray crossing of the camera plane, y.")
    add("gaze_speed_deg_s", "deg/s", "derived", "Angular speed of the gaze direction.")
    for bs in BLEND_SHAPES:
        add(f"bs_{bs}", "0-1", "arkit", f"ARFaceAnchor.blendShapes[{bs}].")
    add("facial_activity", "1/s", "derived", "Mean |d/dt| across all blend-shape coefficients.")
    add("total_variation", "", "derived", "Sum of |delta| across coefficients for this frame.")
    add("movement_amplitude", "", "derived", "Mean over coefficients of (window max - window min).")
    add("movement_frequency_hz", "Hz", "derived", "Zero-crossing rate of the mean activation signal.")
    add("mean_activation", "", "derived", "Mean of all coefficient values on this frame.")
    add("activation_std", "", "derived", "Std of the mean-activation signal in the window.")
    add("activation_variance", "", "derived", "Variance of the mean-activation signal in the window.")
    add("transition_rate", "1/s", "derived", "Activation onsets per second in the window.")
    add("active_coefficients", "", "derived", "Coefficients currently above the activation threshold.")
    add("low_activity", "0/1", "derived", "Inside a low-activity period.")
    add("blink_in_progress", "0/1", "derived", "A blink event is open on this frame.")
    add("blink_count", "", "derived", "Cumulative blinks detected since tracking started.")
    add("blink_rate_per_min", "1/min", "derived", "Blinks per minute over the rate window.")
    for g in ASYM_GROUPS:
        add(f"asym_{g}", "", "derived", "Asymmetry group value.")
    add("head_speed_rad_s", "rad/s", "derived", "|angular velocity| of the head.")
    add("head_amplitude_rad", "rad", "derived", "Mean over pitch/yaw/roll of window range.")
    add("head_frequency_hz", "Hz", "derived", "Zero-crossing rate of mean-removed yaw+pitch.")
    add("head_variability_rad", "rad", "derived", "Mean std of pitch/yaw/roll in the window.")
    add("head_stability", "0-1", "derived", "1 - clamp(variability / 0.05 rad).")
    add("gaze_variability_deg", "deg", "derived", "Mean std of gaze yaw and pitch in the window.")
    add("quality_score", "0-1", "derived", "0.5*trackedFraction + 0.3*(1-droppedFraction) + 0.2*cameraStateWeight.")
    add("mesh_vertex_count", "", "arkit", "ARFaceGeometry.vertexCount.")
    add("mesh_mean_displacement_m", "m", "derived", "Mean vertex displacement since the previous frame.")
    add("mesh_max_displacement_m", "m", "derived", "Largest vertex displacement since the previous frame.")
    add("light_ambient_intensity", "lumen", "arkit", "ARLightEstimate.ambientIntensity (1000 = neutral).")
    add("light_color_temperature_k", "K", "arkit", "ARLightEstimate.ambientColorTemperature.")
    add("light_primary_intensity", "lumen", "arkit", "ARDirectionalLightEstimate.primaryLightIntensity.")
    vec3("light_primary_dir", "", "arkit", "ARDirectionalLightEstimate.primaryLightDirection.")
    add("camera_exposure_duration_s", "s", "arkit", "ARCamera.exposureDuration.")
    add("camera_exposure_offset", "EV", "arkit", "ARCamera.exposureOffset.")
    add("depth_data_available", "0/1", "arkit", "ARFrame.capturedDepthData was non-nil.")
    add("depth_data_timestamp_s", "s", "arkit", "ARFrame.capturedDepthDataTimestamp.")
    add("exif_exposure_time", "s", "arkit", "ARFrame.exifData ExposureTime.")
    add("exif_iso", "", "arkit", "ARFrame.exifData ISOSpeedRatings.")
    add("exif_brightness", "", "arkit", "ARFrame.exifData BrightnessValue.")
    add("camera_fx", "px", "arkit", "Intrinsics focal length x.")
    add("camera_fy", "px", "arkit", "Intrinsics focal length y.")
    add("camera_cx", "px", "arkit", "Principal point x.")
    add("camera_cy", "px", "arkit", "Principal point y.")
    add("image_width", "px", "arkit", "ARCamera.imageResolution width.")
    add("image_height", "px", "arkit", "ARCamera.imageResolution height.")
    return c


def rot_y(a):
    return [[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]]


def rot_x(a):
    return [[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]]


def rot_z(a):
    return [[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def mat4_row_major(r, t):
    return [r[0][0], r[0][1], r[0][2], t[0], r[1][0], r[1][1], r[1][2], t[1], r[2][0], r[2][1], r[2][2], t[2], 0.0, 0.0, 0.0, 1.0]


def f(v):
    # Six significant digits, like a Float printed by Swift, keeps the file a reasonable size.
    return "" if v is None else format(float(v), ".6g")


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def generate(out: str, seconds: float, fps: int, seed: int, start_unix: float, start_uptime: float, geometry_every: int) -> dict:
    rnd = random.Random(seed)
    cols = build_columns()
    names = [c["name"] for c in cols]
    idx = {n: i for i, n in enumerate(names)}
    os.makedirs(out, exist_ok=True)

    n = int(seconds * fps)
    dt = 1.0 / fps
    # Markers as fractions of the recording: neutral 8–33 %, smile 42–58 %, look left 67–75 %, look right 75–83 %.
    S = seconds
    markers = [("Neutral face", 0.08 * S, 0.33 * S), ("Smile", 0.42 * S, 0.58 * S), ("Look left", 0.67 * S, 0.75 * S), ("Look right", 0.75 * S, 0.83 * S)]
    # Tracking lost for 1.5 s at 37.5 %; a dropped-frame burst at 21 %; a 3 s recorder pause at 86 % (recordings over 60 s).
    lost = (0.375 * S, 0.375 * S + 1.5)
    drop_at = 0.21 * S
    pause = (0.86 * S, 0.86 * S + 3.0) if seconds > 60 else None
    jaw_window = (0.58 * S, 0.67 * S)
    blink_times = []
    t = 1.0
    while t < seconds:
        blink_times.append(t)
        t += rnd.uniform(2.2, 4.4)
    blink_dur = 0.13

    rows = []
    lifecycle = []
    uptime = start_uptime
    wall = start_unix
    frame_index = 120
    blink_count = 0
    geometry_records = []
    tracked_count = 0
    prev_uptime = None
    t = 0.0
    sample_index = 0
    paused_total = 0.0
    while t < seconds:
        if pause and pause[0] <= t < pause[1]:
            # Recorder paused: no rows; clocks keep running.
            t += dt
            uptime += dt
            wall += dt
            frame_index += 1
            paused_total += dt
            continue
        interval = dt
        dropped = 0
        if drop_at <= t < drop_at + 0.2 and rnd.random() < 0.5:
            dropped = 2
            interval = dt * 3
        tracked = not (lost[0] <= t < lost[1])
        cells = [""] * len(names)
        cells[idx["sample_index"]] = str(sample_index)
        cells[idx["frame_index"]] = str(frame_index)
        cells[idx["timestamp_s"]] = repr(round(uptime, 6))
        cells[idx["recording_time_s"]] = repr(round(uptime - start_uptime, 6))
        cells[idx["wall_clock_unix_s"]] = repr(round(wall, 6))
        cells[idx["frame_interval_s"]] = "" if prev_uptime is None else repr(round(uptime - prev_uptime, 6))
        cells[idx["dropped_frames_est"]] = str(dropped)
        cells[idx["face_anchor_present"]] = "1"
        cells[idx["face_tracked"]] = "1" if tracked else "0"
        limited = lost[0] <= t < lost[1] + 0.5
        cells[idx["camera_tracking_state"]] = "limited" if limited else "normal"
        cells[idx["camera_limited_reason"]] = "insufficientFeatures" if limited else ""
        marker = next((m[0] for m in markers if m[1] <= t < m[2]), "")
        cells[idx["active_marker"]] = marker

        if tracked:
            tracked_count += 1
            yaw = 0.06 * math.sin(2 * math.pi * 0.25 * t) + rnd.gauss(0, 0.004)
            pitch = 0.03 * math.sin(2 * math.pi * 0.17 * t + 1) + rnd.gauss(0, 0.003)
            roll = 0.015 * math.sin(2 * math.pi * 0.11 * t) + rnd.gauss(0, 0.002)
            if marker == "Look left":
                yaw += 0.12
            if marker == "Look right":
                yaw -= 0.12
            R = matmul(rot_z(roll), matmul(rot_y(yaw), rot_x(pitch)))
            pos = [0.01 * math.sin(0.3 * t) + rnd.gauss(0, 0.001), 0.04 + rnd.gauss(0, 0.001), -0.42 + 0.01 * math.sin(0.2 * t)]
            for k, v in enumerate(mat4_row_major(R, pos)):
                cells[idx[f"head_world_m{k // 4}{k % 4}"]] = f(v)
            for a, v in zip("xyz", pos):
                cells[idx[f"head_world_pos_{a}"]] = f(v)
            cells[idx["head_world_pitch_rad"]] = f(pitch)
            cells[idx["head_world_yaw_rad"]] = f(yaw)
            cells[idx["head_world_roll_rad"]] = f(roll)
            cells[idx["head_distance_m"]] = f(math.sqrt(sum(p * p for p in pos)))
            # Eyes: identity rotation, offset ±0.032 m, slight vergence.
            gaze_yaw = 0.15 * math.sin(2 * math.pi * 0.08 * t) + (0.35 if marker == "Look left" else -0.35 if marker == "Look right" else 0)
            gaze_pitch = 0.08 * math.sin(2 * math.pi * 0.05 * t + 2)
            for side, sx in (("left", 0.032), ("right", -0.032)):
                Re = matmul(rot_y(gaze_yaw), rot_x(gaze_pitch))
                for k, v in enumerate(mat4_row_major(Re, [sx, 0.03, 0.02])):
                    cells[idx[f"eye_{side}_m{k // 4}{k % 4}"]] = f(v)
            look = [0.5 * math.sin(gaze_yaw), 0.5 * math.sin(gaze_pitch) + 0.03, 0.5 * math.cos(gaze_yaw)]
            for a, v in zip("xyz", look):
                cells[idx[f"look_at_{a}"]] = f(v)
            cells[idx["gaze_yaw_deg"]] = f(math.degrees(gaze_yaw))
            cells[idx["gaze_pitch_deg"]] = f(math.degrees(gaze_pitch))

            bs = {name: max(0.0, rnd.gauss(0.03, 0.015)) for name in BLEND_SHAPES}
            if marker == "Neutral face":
                for k in bs:
                    bs[k] *= 0.4   # quieter resting face; blinks below are added afterwards at full size
            in_blink = any(bt <= t < bt + blink_dur for bt in blink_times)
            if in_blink:
                phase = min(((t - bt) / blink_dur) for bt in blink_times if bt <= t < bt + blink_dur)
                closure = math.sin(math.pi * phase)
                bs["eyeBlink_L"] = 0.15 + 0.85 * closure
                bs["eyeBlink_R"] = 0.12 + 0.86 * closure
                bs["eyeSquint_L"] = 0.2 * closure
                bs["eyeSquint_R"] = 0.2 * closure
            if marker == "Smile":
                s = 0.55 + 0.1 * math.sin(2 * math.pi * 0.3 * t)
                bs["mouthSmile_L"] = s + 0.03
                bs["mouthSmile_R"] = s - 0.03
                bs["cheekSquint_L"] = 0.3 * s
                bs["cheekSquint_R"] = 0.28 * s
                bs["mouthDimple_L"] = 0.2 * s
                bs["mouthDimple_R"] = 0.2 * s
            bs["eyeLookOut_L" if gaze_yaw > 0 else "eyeLookIn_L"] = min(1.0, abs(gaze_yaw) * 1.5)
            bs["eyeLookIn_R" if gaze_yaw > 0 else "eyeLookOut_R"] = min(1.0, abs(gaze_yaw) * 1.5)
            bs["jawOpen"] = max(0.0, 0.05 + 0.1 * math.sin(2 * math.pi * 0.9 * t)) if jaw_window[0] <= t < jaw_window[1] else bs["jawOpen"]
            for name in BLEND_SHAPES:
                cells[idx[f"bs_{name}"]] = f(min(1.0, bs[name]))
            if in_blink and not getattr(generate, "_blink_open", False):
                blink_count += 1
            generate._blink_open = in_blink
            cells[idx["blink_in_progress"]] = "1" if in_blink else "0"
            cells[idx["blink_count"]] = str(blink_count)
            cells[idx["blink_rate_per_min"]] = f(blink_count / max(1e-3, (uptime - start_uptime)) * 60) if uptime - start_uptime > 5 else ""
            mean_act = sum(bs.values()) / len(bs)
            cells[idx["mean_activation"]] = f(mean_act)
            cells[idx["active_coefficients"]] = str(sum(1 for v in bs.values() if v > 0.25))
            cells[idx["asym_smile"]] = f(bs["mouthSmile_L"] - bs["mouthSmile_R"])
            cells[idx["asym_overall"]] = f(sum(abs(bs[k] - bs[k[:-2] + "_R"]) for k in BLEND_SHAPES if k.endswith("_L")) / 23)
            cells[idx["quality_score"]] = f(0.5 + 0.3 + (0.2 if not limited else 0.1))
            cells[idx["mesh_vertex_count"]] = "1220"
            if geometry_every > 0 and sample_index % geometry_every == 0:
                geometry_records.append((uptime, sample_index, yaw, pitch, rnd.random()))
        else:
            cells[idx["quality_score"]] = f(0.3 + (0.2 if not limited else 0.1))

        amb = 850 + 120 * math.sin(0.05 * t) + rnd.gauss(0, 10)
        cells[idx["light_ambient_intensity"]] = f(amb)
        cells[idx["light_color_temperature_k"]] = f(4800 + rnd.gauss(0, 40))
        cells[idx["light_primary_intensity"]] = f(amb * 1.1)
        for a, v in zip("xyz", (0.2, -0.7, -0.68)):
            cells[idx[f"light_primary_dir_{a}"]] = f(v)
        cells[idx["camera_exposure_duration_s"]] = f(1 / 60)
        cells[idx["camera_exposure_offset"]] = f(rnd.gauss(0.1, 0.02))
        cells[idx["depth_data_available"]] = "1"
        cells[idx["depth_data_timestamp_s"]] = repr(round(uptime - 0.004, 6))
        cells[idx["exif_exposure_time"]] = f(1 / 60)
        cells[idx["exif_iso"]] = "400"
        cells[idx["exif_brightness"]] = f(2.1 + rnd.gauss(0, 0.05))
        cells[idx["camera_fx"]] = "1023.4"
        cells[idx["camera_fy"]] = "1023.4"
        cells[idx["camera_cx"]] = "639.5"
        cells[idx["camera_cy"]] = "359.5"
        cells[idx["image_width"]] = "1280"
        cells[idx["image_height"]] = "720"

        rows.append(",".join(cells))
        prev_uptime = uptime
        t += interval
        uptime += interval
        wall += interval
        frame_index += 1 + dropped
        sample_index += 1

    with open(os.path.join(out, "samples.csv"), "w", newline="\n", encoding="utf-8") as fh:
        fh.write(",".join(names) + "\n")
        fh.write("\n".join(rows) + "\n")

    created = datetime.fromtimestamp(start_unix, tz=timezone.utc)
    last_uptime = prev_uptime
    ended = datetime.fromtimestamp(wall + 0.8, tz=timezone.utc)
    lifecycle = [
        {"date": iso(created - timedelta(seconds=2)), "kind": "configured", "detail": "ARFaceTrackingConfiguration"},
        {"date": iso(created - timedelta(seconds=1.5)), "kind": "started", "detail": ""},
        {"date": iso(created - timedelta(seconds=0.4)), "kind": "faceAnchorAdded", "detail": ""},
        {"date": iso(created + timedelta(seconds=lost[0])), "kind": "faceAnchorRemoved", "detail": ""},
        {"date": iso(created + timedelta(seconds=lost[0])), "kind": "cameraTrackingChanged", "detail": "limited(insufficientFeatures)"},
        {"date": iso(created + timedelta(seconds=lost[1])), "kind": "faceAnchorAdded", "detail": ""},
        {"date": iso(created + timedelta(seconds=lost[1] + 0.5)), "kind": "cameraTrackingChanged", "detail": "normal"},
    ]
    pauses = []
    if pause:
        pauses.append({"startTimestamp": start_uptime + pause[0], "endTimestamp": start_uptime + pause[1]})
        lifecycle.append({"date": iso(created + timedelta(seconds=pause[0])), "kind": "paused", "detail": "recorder pause"})
    marker_records = []
    for i, (label, a, b) in enumerate(markers):
        marker_records.append({
            "id": f"0000000{i}-0000-4000-8000-00000000000{i}", "label": label, "kind": "interval",
            "startTimestamp": start_uptime + a, "endTimestamp": start_uptime + b, "recordingStartTime": float(a), "recordingEndTime": float(b),
            "startFrameIndex": int(120 + a * fps), "endFrameIndex": int(120 + b * fps),
            "wallClock": iso(created + timedelta(seconds=a)), "note": None,
        })
    blink_records = []
    prev = None
    for bt in blink_times:
        if lost[0] <= bt < lost[1] or (pause and pause[0] <= bt < pause[1]):
            continue
        blink_records.append({
            "startTimestamp": start_uptime + bt, "endTimestamp": start_uptime + bt + blink_dur, "recordingStartTime": bt,
            "durationSeconds": blink_dur, "peakLeft": 1.0, "peakRight": 0.98, "peakAsymmetry": 0.02, "onsetLagSeconds": 0.0,
            "bilateral": True, "kind": "blink", "interBlinkIntervalSeconds": None if prev is None else bt - prev,
        })
        prev = bt
    manifest = {
        "formatVersion": 1,
        "id": created.strftime("%Y%m%d-%H%M%S") + "-synth01",
        "app": {"name": "FaceMetrics", "version": "0.1.0", "build": "1"},
        "device": {"model": "iPhone16,1", "systemName": "iOS", "systemVersion": "17.6.1"},
        "createdAt": iso(created),
        "endedAt": iso(ended),
        "recordingStartTimestamp": start_uptime,
        "recordingEndTimestamp": last_uptime,
        "durationSeconds": round(last_uptime - start_uptime - paused_total, 4),
        "configuration": {"targetSampleRate": fps, "writeJSONSamples": False, "includeFaceGeometry": geometry_every > 0,
                          "geometryEveryNthSample": geometry_every, "participantLabel": "SYNTHETIC", "notes": "Generated by make_example_arkit_session.py; not a real person."},
        "tracking": {"videoFormat": f"1280x720 @ {fps} fps", "framesPerSecond": fps, "lightEstimationEnabled": True,
                     "expectedFrameIntervalSeconds": round(1 / fps, 6), "supportsWorldTracking": False, "supportedNumberOfTrackedFaces": 1},
        "sampleCount": len(rows),
        "trackedSampleCount": tracked_count,
        "framesSeen": frame_index - 120,
        "framesSkippedByRateLimit": 0,
        "droppedFramesEstimate": sum(int(r.split(",")[idx["dropped_frames_est"]]) for r in rows),
        "pauses": pauses,
        "blendShapeIdentifiers": BLEND_SHAPES,
        "blendShapeFriendlyNames": {b: (b[:-2] + "Left" if b.endswith("_L") else b[:-2] + "Right" if b.endswith("_R") else b) for b in BLEND_SHAPES},
        "columns": cols,
        "coefficientStatistics": {},
        "markers": marker_records,
        "blinkEvents": blink_records,
        "lowActivityPeriods": [],
        "lifecycle": lifecycle,
        "summary": {"averageFPS": fps, "trackedSampleFraction": round(tracked_count / len(rows), 4), "interruptions": 0,
                    "blinkCount": len(blink_records), "closureCount": 0, "activationEvents": 0, "lowActivityPeriods": 0, "unknownBlendShapeKeysSeen": 0},
        "files": ["samples.csv", "session.json"] + (["geometry.bin", "geometry.json"] if geometry_every > 0 else []),
        "notes": ["SYNTHETIC DATA for pipeline testing. Blend shapes, head pose and gaze are generated functions plus noise.",
                  "timestamp_s is device uptime; createdAt + recordingStartTimestamp give the wall-clock anchor."],
    }
    with open(os.path.join(out, "session.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)

    if geometry_every > 0:
        # Fixed topology: 1220 vertices on an ellipsoid patch, a few hundred triangles.
        vc = 1220
        base = []
        for k in range(vc):
            u = (k % 40) / 39.0 * math.pi - math.pi / 2
            v = (k // 40) / 30.0 * math.pi / 2 - math.pi / 4
            base.append((0.075 * math.sin(u) * math.cos(v), 0.095 * math.sin(v), 0.06 * math.cos(u) * math.cos(v)))
        tris = []
        for r in range(29):
            for c in range(39):
                a = r * 40 + c
                tris += [a, a + 1, a + 40, a + 1, a + 41, a + 40]
        with open(os.path.join(out, "geometry.bin"), "wb") as fh:
            for (ts, si, yaw, pitch, jitter) in geometry_records:
                fh.write(struct.pack("<dii", ts, si, vc))
                for (x, y, z) in base:
                    # Small mouth-region displacement so inter-record displacement is non-zero.
                    dy = -0.004 * jitter if y < -0.03 else 0.0
                    fh.write(struct.pack("<fff", x, y + dy, z))
        with open(os.path.join(out, "geometry.json"), "w", encoding="utf-8", newline="\n") as fh:
            json.dump({
                "file": "geometry.bin",
                "record_layout": "little-endian: float64 timestamp_s, int32 sample_index, int32 vertex_count, then vertex_count x (float32 x, float32 y, float32 z) in face-anchor space, metres",
                "record_count": len(geometry_records), "vertex_count": vc, "every_nth_sample": geometry_every,
                "triangle_indices": tris,
                "privacy": "Face geometry is identifiable. It was recorded because the researcher opted in for this session.",
            }, fh, indent=2, sort_keys=True)

    return {"rows": len(rows), "columns": len(names), "tracked": tracked_count, "blinks_in_manifest": len(blink_records),
            "geometry_records": len(geometry_records), "duration_s": manifest["durationSeconds"], "id": manifest["id"]}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="arkit-session-synthetic")
    ap.add_argument("--seconds", type=float, default=45)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--start-unix", type=float, default=1794636000.0)   # 2026-11-14T06:00:00Z
    ap.add_argument("--start-uptime", type=float, default=73421.5)
    ap.add_argument("--geometry-every", type=int, default=300)          # one mesh every 10 s at 30 fps
    a = ap.parse_args()
    info = generate(a.out, a.seconds, a.fps, a.seed, a.start_unix, a.start_uptime, a.geometry_every)
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
