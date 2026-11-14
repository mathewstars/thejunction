import Foundation

/// Reads the files the FaceMetrics ARKit app already writes: `samples.csv`, `session.json`, and the
/// optional `geometry.bin` + `geometry.json`. It does not track faces and does not change the data.
///
/// Column handling: the CSV header is read as-is. Known columns are mapped onto `ARKitFrame`'s typed
/// fields; every cell, known or not, is also kept in `ARKitFrame.values` in header order. Blend shapes
/// are discovered from the `bs_` prefix, never from a fixed list.
public final class ARKitDatasetImporter {

    public enum ImportError: LocalizedError {
        case missingColumn(String)
        case noRows
        case geometryLayout(String)
        case notJSONObject
        public var errorDescription: String? {
            switch self {
            case .missingColumn(let c): return "CSV header has no '\(c)' column; this does not look like a FaceMetrics export."
            case .noRows: return "CSV has a header but no rows."
            case .geometryLayout(let s): return "geometry.bin layout problem: \(s)"
            case .notJSONObject: return "session.json is not a JSON object."
            }
        }
    }

    public init() {}

    // MARK: CSV

    /// Parses a FaceMetrics `samples.csv`. Alignment falls back to the CSV wall-clock column until a
    /// `session.json` is attached with `importSessionJSON`.
    public func importARKitCSV(file: URL, progress: ((Int) -> Void)? = nil) throws -> ARKitSession {
        let needsStop = file.startAccessingSecurityScopedResource()
        defer { if needsStop { file.stopAccessingSecurityScopedResource() } }

        var header: [String] = []
        var index: [String: Int] = [:]
        var frames: [ARKitFrame] = []
        var numericCount: [Int] = []
        var emptyCount: [Int] = []
        var blendShapeColumns: [(id: String, col: Int)] = []
        var rowIndex = 0

        func col(_ name: String) -> Int? { index[name] }
        func mat(_ prefix: String) -> [Int]? {
            var out: [Int] = []
            for r in 0..<4 { for c in 0..<4 { guard let i = index["\(prefix)_m\(r)\(c)"] else { return nil }; out.append(i) } }
            return out
        }
        func vec(_ prefix: String) -> [Int]? {
            guard let x = index["\(prefix)_x"], let y = index["\(prefix)_y"], let z = index["\(prefix)_z"] else { return nil }
            return [x, y, z]
        }

        var cTimestamp = -1, cFrame: Int?, cRecTime: Int?, cWall: Int?, cInterval: Int?, cDropped: Int?
        var cAnchor: Int?, cTracked: Int?, cCamState: Int?, cLimited: Int?, cMarker: Int?
        var headM: [Int]?, headPos: [Int]?, eyeL: [Int]?, eyeR: [Int]?, lookAt: [Int]?
        var cMesh: Int?, cAmbient: Int?, cColorTemp: Int?, cExpDur: Int?, cExpOff: Int?, cDepthAvail: Int?, cDepthTs: Int?

        let reader = CSVReader(url: file)
        try reader.read(onHeader: { h in
            header = h
            for (i, name) in h.enumerated() { index[name] = i }
            guard let t = index["timestamp_s"] else { throw ImportError.missingColumn("timestamp_s") }
            cTimestamp = t
            cFrame = col("frame_index"); cRecTime = col("recording_time_s"); cWall = col("wall_clock_unix_s")
            cInterval = col("frame_interval_s"); cDropped = col("dropped_frames_est")
            cAnchor = col("face_anchor_present"); cTracked = col("face_tracked")
            cCamState = col("camera_tracking_state"); cLimited = col("camera_limited_reason"); cMarker = col("active_marker")
            headM = mat("head_world"); headPos = vec("head_world_pos"); eyeL = mat("eye_left"); eyeR = mat("eye_right"); lookAt = vec("look_at")
            cMesh = col("mesh_vertex_count"); cAmbient = col("light_ambient_intensity"); cColorTemp = col("light_color_temperature_k")
            cExpDur = col("camera_exposure_duration_s"); cExpOff = col("camera_exposure_offset")
            cDepthAvail = col("depth_data_available"); cDepthTs = col("depth_data_timestamp_s")
            blendShapeColumns = h.enumerated().filter { $0.element.hasPrefix("bs_") }.map { (String($0.element.dropFirst(3)), $0.offset) }
            numericCount = Array(repeating: 0, count: h.count)
            emptyCount = Array(repeating: 0, count: h.count)
        }, onRow: { cells in
            var values = [Double?](repeating: nil, count: header.count)
            var text: [Int: String] = [:]
            for i in 0..<min(cells.count, header.count) {
                let c = cells[i]
                if c.isEmpty { emptyCount[i] += 1; continue }
                if let d = Double(c) { values[i] = d; numericCount[i] += 1 } else { text[i] = c }
            }
            guard let ts = values[cTimestamp] else { return true } // a row without a timestamp is unusable; skip

            func d(_ i: Int?) -> Double? { i.flatMap { values[$0] } }
            func b(_ i: Int?) -> Bool? { d(i).map { $0 != 0 } }
            func s(_ i: Int?) -> String? { i.flatMap { text[$0] } }
            func arr(_ idx: [Int]?) -> [Double]? {
                guard let idx else { return nil }
                var out: [Double] = []
                out.reserveCapacity(idx.count)
                for i in idx { guard let v = values[i] else { return nil }; out.append(v) }
                return out
            }

            var bs: [String: Double] = [:]
            for (id, c) in blendShapeColumns { if let v = values[c] { bs[id] = v } }

            frames.append(ARKitFrame(
                rowIndex: rowIndex, frameIndex: d(cFrame).map { Int($0) }, timestampUptime: ts, recordingTime: d(cRecTime),
                wallClockUnix: d(cWall), frameInterval: d(cInterval), droppedFramesEstimate: d(cDropped).map { Int($0) },
                faceAnchorPresent: b(cAnchor), faceTracked: b(cTracked), cameraTrackingState: s(cCamState),
                cameraLimitedReason: s(cLimited), activeMarker: s(cMarker),
                headWorldTransform: arr(headM), headWorldPosition: arr(headPos), eyeLeftTransform: arr(eyeL),
                eyeRightTransform: arr(eyeR), lookAtPoint: arr(lookAt), blendShapes: bs,
                meshVertexCount: d(cMesh).map { Int($0) }, ambientIntensity: d(cAmbient), ambientColorTemperature: d(cColorTemp),
                exposureDuration: d(cExpDur), exposureOffset: d(cExpOff), depthDataAvailable: b(cDepthAvail),
                depthDataTimestamp: d(cDepthTs), values: values, textValues: text))
            rowIndex += 1
            if rowIndex % 2000 == 0 { progress?(rowIndex) }
            return true
        })

        guard !frames.isEmpty else { throw ImportError.noRows }
        frames.sort { $0.timestampUptime < $1.timestampUptime }

        let recognised = Self.recognisedColumnNames(blendShapeIdentifiers: blendShapeColumns.map { $0.id })
        let columns = header.enumerated().map { i, name in
            ARKitColumnInfo(name: name, index: i, unit: nil, origin: nil, description: nil,
                            recognised: recognised.contains(name), numericCount: numericCount[i], emptyCount: emptyCount[i])
        }

        var session = ARKitSession(
            id: file.deletingLastPathComponent().lastPathComponent.isEmpty ? file.deletingPathExtension().lastPathComponent
                : file.deletingLastPathComponent().lastPathComponent,
            csvFileName: file.lastPathComponent, sessionJSONFileName: nil, geometryFileName: nil, importedAt: Date(),
            columns: columns, blendShapeIdentifiers: blendShapeColumns.map { $0.id }.sorted(), frames: frames,
            manifest: nil, geometry: nil, alignment: nil, validation: nil)
        session.alignment = TimestampAligner.align(session: session)
        session.validation = validateARKitDataset(session)
        return session
    }

    /// Column names this importer understands, used to flag unknown columns for forward compatibility.
    static func recognisedColumnNames(blendShapeIdentifiers: [String]) -> Set<String> {
        var s: Set<String> = ["sample_index", "frame_index", "timestamp_s", "recording_time_s", "wall_clock_unix_s", "frame_interval_s",
                              "dropped_frames_est", "face_anchor_present", "face_tracked", "camera_tracking_state", "camera_limited_reason",
                              "active_marker", "mesh_vertex_count", "mesh_mean_displacement_m", "mesh_max_displacement_m",
                              "light_ambient_intensity", "light_color_temperature_k", "light_primary_intensity",
                              "camera_exposure_duration_s", "camera_exposure_offset", "depth_data_available", "depth_data_timestamp_s",
                              "exif_exposure_time", "exif_iso", "exif_brightness", "camera_fx", "camera_fy", "camera_cx", "camera_cy",
                              "image_width", "image_height", "head_distance_m", "eye_left_yaw_deg", "eye_left_pitch_deg",
                              "eye_right_yaw_deg", "eye_right_pitch_deg", "gaze_yaw_deg", "gaze_pitch_deg", "gaze_divergence_deg",
                              "gaze_plane_hit_x_m", "gaze_plane_hit_y_m", "gaze_speed_deg_s", "facial_activity", "total_variation",
                              "movement_amplitude", "movement_frequency_hz", "mean_activation", "activation_std", "activation_variance",
                              "transition_rate", "active_coefficients", "low_activity", "blink_in_progress", "blink_count",
                              "blink_rate_per_min", "head_speed_rad_s", "head_amplitude_rad", "head_frequency_hz",
                              "head_variability_rad", "head_stability", "gaze_variability_deg", "quality_score"]
        for g in ["smile", "brow", "eye", "cheek", "mouth", "nose", "overall"] { s.insert("asym_\(g)") }
        for p in ["head_world", "eye_left", "eye_right"] { for r in 0..<4 { for c in 0..<4 { s.insert("\(p)_m\(r)\(c)") } } }
        for p in ["head_world_pos", "head_view_pos", "head_rel_pos", "head_ang_vel", "head_ang_acc", "head_lin_vel", "eye_left_fwd",
                  "eye_right_fwd", "look_at", "gaze_anchor", "gaze_view", "gaze_world", "light_primary_dir"] {
            for a in ["x", "y", "z"] { s.insert("\(p)_\(a)") }
        }
        for p in ["head_world", "head_view", "head_rel"] { for a in ["pitch_rad", "yaw_rad", "roll_rad"] { s.insert("\(p)_\(a)") } }
        for id in blendShapeIdentifiers { s.insert("bs_\(id)") }
        return s
    }

    // MARK: session.json

    public func importSessionJSON(file: URL) throws -> ARKitSessionManifest {
        let needsStop = file.startAccessingSecurityScopedResource()
        defer { if needsStop { file.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: file)
        let raw = try JSONValue.decoder().decode(JSONValue.self, from: data)
        guard raw.objectValue != nil else { throw ImportError.notJSONObject }
        var manifest = try JSONValue.decoder().decode(ARKitSessionManifest.self, from: data)
        manifest.raw = raw
        return manifest
    }

    /// Attaches a manifest to a session: column documentation, id, alignment and validation are refreshed.
    public func attach(manifest: ARKitSessionManifest, fileName: String, to session: inout ARKitSession) {
        session.manifest = manifest
        session.sessionJSONFileName = fileName
        if let id = manifest.id { session.id = id }
        if let docs = manifest.columns {
            let byName = Dictionary(docs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for i in session.columns.indices {
                if let d = byName[session.columns[i].name] {
                    session.columns[i].unit = d.unit; session.columns[i].origin = d.origin; session.columns[i].description = d.description
                }
            }
        }
        session.alignment = TimestampAligner.align(session: session)
        session.validation = validateARKitDataset(session)
    }

    // MARK: Geometry

    /// Reads `geometry.json` (layout + triangle indices) and `geometry.bin` (records). Pass either file;
    /// the sibling is looked up in the same folder. Raw vertices stay in the returned value and are
    /// never placed in `ARKitSession`.
    public func importGeometryFile(file: URL, maxRecords: Int = .max) throws -> ARKitGeometryData {
        let needsStop = file.startAccessingSecurityScopedResource()
        defer { if needsStop { file.stopAccessingSecurityScopedResource() } }
        let folder = file.deletingLastPathComponent()
        let jsonURL = file.pathExtension == "json" ? file : folder.appendingPathComponent("geometry.json")
        let binURL = file.pathExtension == "bin" ? file : folder.appendingPathComponent("geometry.bin")

        var triangles: [Int] = []
        var everyNth: Int? = nil
        var layout: String? = nil
        var declaredVertexCount: Int? = nil
        if let data = try? Data(contentsOf: jsonURL), let header = try? JSONValue.decoder().decode(JSONValue.self, from: data) {
            triangles = header["triangle_indices"]?.arrayValue?.compactMap { $0.intValue } ?? []
            everyNth = header["every_nth_sample"]?.intValue
            layout = header["record_layout"]?.stringValue
            declaredVertexCount = header["vertex_count"]?.intValue
        }

        let bin = try Data(contentsOf: binURL)
        var records: [ARKitGeometryRecord] = []
        var offset = 0
        func readLE<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= bin.count else { throw ImportError.geometryLayout("truncated record at byte \(offset)") }
            var v: T = 0
            withUnsafeMutableBytes(of: &v) { bin.copyBytes(to: $0, from: offset..<offset + MemoryLayout<T>.size) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: v)
        }
        while offset < bin.count, records.count < maxRecords {
            let ts = Double(bitPattern: try readLE(UInt64.self))
            let sampleIndex = Int(Int32(bitPattern: try readLE(UInt32.self)))
            let n = Int(Int32(bitPattern: try readLE(UInt32.self)))
            guard n > 0, n < 100_000 else { throw ImportError.geometryLayout("implausible vertex count \(n) at byte \(offset)") }
            let bytes = n * 3 * 4
            guard offset + bytes <= bin.count else { throw ImportError.geometryLayout("truncated vertex block at byte \(offset)") }
            var verts = [Float](repeating: 0, count: n * 3)
            _ = verts.withUnsafeMutableBytes { bin.copyBytes(to: $0, from: offset..<offset + bytes) }
            offset += bytes
            records.append(ARKitGeometryRecord(timestampUptime: ts, sampleIndex: sampleIndex, vertices: verts))
        }
        let vertexCount = records.first?.vertices.count ?? (declaredVertexCount.map { $0 * 3 } ?? 0)
        let summary = ARKitGeometrySummary(recordCount: records.count, vertexCount: vertexCount / 3, triangleCount: triangles.count / 3,
                                           everyNthSample: everyNth, firstTimestampUptime: records.first?.timestampUptime,
                                           lastTimestampUptime: records.last?.timestampUptime, fileBytes: Int64(bin.count), layout: layout)
        return ARKitGeometryData(summary: summary, triangleIndices: triangles, records: records)
    }

    public func attach(geometry: ARKitGeometryData, fileName: String, to session: inout ARKitSession) {
        session.geometry = geometry.summary
        session.geometryFileName = fileName
        session.validation = validateARKitDataset(session)
    }

    /// Convenience: a whole FaceMetrics session folder (samples.csv + session.json [+ geometry]).
    public func importSessionFolder(_ folder: URL, includeGeometry: Bool = false) throws -> (ARKitSession, ARKitGeometryData?) {
        let csv = folder.appendingPathComponent("samples.csv")
        var session = try importARKitCSV(file: csv)
        let manifestURL = folder.appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            attach(manifest: try importSessionJSON(file: manifestURL), fileName: "session.json", to: &session)
        }
        var geometry: ARKitGeometryData? = nil
        let binURL = folder.appendingPathComponent("geometry.bin")
        if includeGeometry, FileManager.default.fileExists(atPath: binURL.path) {
            geometry = try importGeometryFile(file: binURL)
            attach(geometry: geometry!, fileName: "geometry.bin", to: &session)
        } else if FileManager.default.fileExists(atPath: binURL.path) {
            // Note availability without reading the identifiable mesh.
            let size = (try? binURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            session.geometry = ARKitGeometrySummary(recordCount: 0, vertexCount: 0, triangleCount: 0, everyNthSample: nil,
                                                    firstTimestampUptime: nil, lastTimestampUptime: nil, fileBytes: Int64(size),
                                                    layout: "present, not loaded")
            session.geometryFileName = "geometry.bin"
            session.validation = validateARKitDataset(session)
        }
        return (session, geometry)
    }

    // MARK: Validation

    public func validateARKitDataset(_ s: ARKitSession) -> ARKitValidationReport {
        var issues: [ARKitValidationReport.Issue] = []
        let frames = s.frames
        let n = frames.count
        let tracked = frames.filter { $0.faceTracked == true }.count
        let pauses = s.manifest?.pauses ?? []
        let pausedSeconds = pauses.reduce(0) { $0 + max(0, $1.endTimestamp - $1.startTimestamp) }
        let rawDuration = n >= 2 ? frames[n - 1].timestampUptime - frames[0].timestampUptime : 0
        let duration = max(0, rawDuration - pausedSeconds)

        let expectedFPS: Double? = {
            let target = s.manifest?.configuration?.targetSampleRate
            let camera = s.manifest?.tracking?.framesPerSecond.map { Double($0) }
            switch (target, camera) {
            case let (t?, c?): return min(t, c)
            case let (t?, nil): return t
            case let (nil, c?): return c
            default: return nil
            }
        }()

        var intervals: [Double] = []
        var missing = 0
        var gaps = 0
        var largestGap = 0.0
        if n >= 2 {
            intervals.reserveCapacity(n - 1)
            for i in 1..<n {
                let a = frames[i - 1].timestampUptime, b = frames[i].timestampUptime
                let dt = b - a
                let inPause = pauses.contains { p in a <= p.endTimestamp + 0.05 && b >= p.startTimestamp - 0.05 }
                if inPause { continue }
                intervals.append(dt)
                if dt > largestGap { largestGap = dt }
                if dt > 1.0 { gaps += 1 }
            }
        }
        let medianInterval = LocalStatistics.median(intervals)
        let expectedInterval = expectedFPS.map { 1 / $0 } ?? medianInterval
        if let ei = expectedInterval, ei > 0 {
            for dt in intervals where dt > 1.5 * ei { missing += max(0, Int((dt / ei).rounded()) - 1) }
        }
        let effectiveFPS: Double? = duration > 0 && n >= 2 ? Double(n - 1) / duration : nil

        // Blend shape completeness: only tracked frames are expected to have coefficients.
        let bsCount = s.blendShapeIdentifiers.count
        var missingCells = 0
        var framesWithMissing = 0
        var trackedCells = 0
        for f in frames where f.faceTracked == true {
            trackedCells += bsCount
            let present = f.blendShapes.count
            if present < bsCount { missingCells += bsCount - present; framesWithMissing += 1 }
        }
        let bsMissingFraction = trackedCells > 0 ? Double(missingCells) / Double(trackedCells) : 0

        var camStates: [String: Int] = [:]
        var limited: [String: Int] = [:]
        for f in frames {
            camStates[f.cameraTrackingState ?? "unknown", default: 0] += 1
            if let r = f.cameraLimitedReason, !r.isEmpty { limited[r, default: 0] += 1 }
        }
        let camDist = camStates.mapValues { n > 0 ? Double($0) / Double(n) : 0 }

        let lifecycle = s.manifest?.lifecycle ?? []
        let interruptions = lifecycle.filter { $0.kind == "interrupted" }.count
        var faceLost = lifecycle.filter { $0.kind == "faceAnchorRemoved" }.count
        var csvLost = 0
        for i in 1..<max(1, n) where frames[i - 1].faceTracked == true && frames[i].faceTracked != true { csvLost += 1 }
        faceLost = max(faceLost, csvLost)

        let unknown = s.columns.filter { !$0.recognised }.map { $0.name }
        let manifestMatches: Bool? = s.manifest?.sampleCount.map { $0 == n }

        if n == 0 { issues.append(.init(severity: "error", message: "No frames.")) }
        if n > 0, Double(tracked) / Double(n) < 0.8 {
            issues.append(.init(severity: "warning", message: "Face tracked in only \(Int(100 * Double(tracked) / Double(n)))% of frames."))
        }
        if let e = expectedFPS, let f = effectiveFPS, f < 0.8 * e {
            issues.append(.init(severity: "warning", message: String(format: "Effective frame rate %.1f fps is below the expected %.0f fps.", f, e)))
        }
        if gaps > 0 { issues.append(.init(severity: "warning", message: "\(gaps) gap(s) over 1 s outside recorded pauses; largest \(String(format: "%.2f", largestGap)) s.")) }
        if bsMissingFraction > 0.01 { issues.append(.init(severity: "warning", message: String(format: "%.1f%% of blend-shape cells missing on tracked frames.", bsMissingFraction * 100))) }
        if let m = manifestMatches, !m { issues.append(.init(severity: "warning", message: "Manifest sampleCount \(s.manifest?.sampleCount ?? -1) differs from CSV rows \(n).")) }
        if s.manifest == nil { issues.append(.init(severity: "info", message: "No session.json attached: pauses, lifecycle and the preferred time anchor are unknown.")) }
        if !unknown.isEmpty { issues.append(.init(severity: "info", message: "\(unknown.count) column(s) not recognised; kept as raw values: \(unknown.prefix(8).joined(separator: ", "))\(unknown.count > 8 ? "…" : "")")) }
        if let a = s.alignment { for w in a.warnings { issues.append(.init(severity: a.method == .unaligned ? "error" : "info", message: w)) } }
        if interruptions > 0 { issues.append(.init(severity: "info", message: "\(interruptions) ARSession interruption(s) recorded.")) }
        if (camDist["limited"] ?? 0) > 0.2 { issues.append(.init(severity: "warning", message: "Camera tracking limited in \(Int((camDist["limited"] ?? 0) * 100))% of frames: \(limited.keys.sorted().joined(separator: ", ")).")) }

        return ARKitValidationReport(
            frameCount: n, trackedFrameCount: tracked, recordingDurationSeconds: duration, effectiveFrameRate: effectiveFPS,
            expectedFrameRate: expectedFPS, medianFrameIntervalSeconds: medianInterval, missingFramesEstimate: missing,
            gapCount: gaps, largestGapSeconds: intervals.isEmpty ? nil : largestGap, pauseCount: pauses.count, pausedSeconds: pausedSeconds,
            interruptionCount: interruptions, faceLostEvents: faceLost, blendShapeColumns: bsCount,
            blendShapeMissingFraction: bsMissingFraction, framesWithAnyMissingBlendShape: framesWithMissing,
            cameraStateDistribution: camDist, limitedReasons: limited,
            ambientIntensity: Self.stats(frames.compactMap { $0.ambientIntensity }),
            colorTemperatureK: Self.stats(frames.compactMap { $0.ambientColorTemperature }),
            exposureDurationS: Self.stats(frames.compactMap { $0.exposureDuration }),
            geometryAvailable: s.geometry != nil, geometryRecords: s.geometry?.recordCount ?? 0,
            unknownColumns: unknown, manifestSampleCountMatches: manifestMatches, issues: issues)
    }

    private static func stats(_ x: [Double]) -> DescriptiveStatistics? { x.isEmpty ? nil : LocalStatistics.describe(x) }

    // MARK: Summary, features, export

    public func extractFacialFeatureWindows(_ session: ARKitSession, windowSeconds: [Double] = FacialFeatureAnalyzer.standardWindows) -> [Double: [FacialFeatureWindow]] {
        let analyzer = FacialFeatureAnalyzer()
        var out: [Double: [FacialFeatureWindow]] = [:]
        for w in windowSeconds { out[w] = analyzer.windows(session: session, windowSeconds: w) }
        return out
    }

    /// Numbers only. This is the object that may be sent to Gemini for Experiment B and C.
    public func generateARKitSummary(_ session: ARKitSession, geometry: ARKitGeometryData? = nil,
                                     windowSeconds: [Double] = FacialFeatureAnalyzer.standardWindows,
                                     includeWindows: Bool = true) -> ARKitSessionSummary {
        let analyzer = FacialFeatureAnalyzer()
        var windows: [String: [FacialFeatureWindow]] = [:]
        if includeWindows {
            for w in windowSeconds { windows[String(Int(w))] = analyzer.windows(session: session, windowSeconds: w) }
        }
        let whole = analyzer.sessionLevelWindow(session: session)
        var bsStats: [String: DescriptiveStatistics] = [:]
        let tracked = session.frames.filter { $0.faceTracked == true }
        for id in session.blendShapeIdentifiers {
            bsStats[id] = LocalStatistics.describe(tracked.compactMap { $0.blendShapes[id] })
        }
        var derivedMeans: [String: Double] = [:]
        for c in session.columns where c.origin == "derived" || Self.exportedDerivedColumns.contains(c.name) {
            let vals = session.frames.compactMap { $0.values[c.index] }
            if let m = LocalStatistics.mean(vals) { derivedMeans[c.name] = m }
        }
        let markers = Array(Set(session.frames.compactMap { $0.activeMarker })).sorted()
        return ARKitSessionSummary(
            id: session.id, recordedStart: session.alignment?.recordingStartWallClock,
            recordedEnd: session.alignment?.recordingEndWallClock, alignmentMethod: session.alignment?.method ?? .unaligned,
            durationSeconds: session.validation?.recordingDurationSeconds ?? session.recordingDurationSeconds,
            frameCount: session.frames.count,
            trackedFraction: session.frames.isEmpty ? 0 : Double(tracked.count) / Double(session.frames.count),
            effectiveFrameRate: session.validation?.effectiveFrameRate, videoFormat: session.manifest?.tracking?.videoFormat,
            deviceModel: session.manifest?.device?.model, markers: markers, validation: session.validation,
            windowsBySeconds: windows, sessionLevelFeatures: whole, blendShapeStatistics: bsStats,
            exportedDerivedColumnMeans: derivedMeans,
            geometryFeatures: geometry.map { GeometryFeatureExtractor.features($0) })
    }

    static let exportedDerivedColumns: Set<String> = ["facial_activity", "movement_amplitude", "movement_frequency_hz", "blink_rate_per_min",
                                                      "head_amplitude_rad", "head_frequency_hz", "head_variability_rad", "head_stability",
                                                      "gaze_variability_deg", "quality_score", "asym_overall"]

    /// Writes the session as JSON: typed frames with wall-clock time where aligned, raw cells untouched,
    /// plus manifest, alignment and validation. Blend shapes keep their ARKit identifiers.
    @discardableResult
    public func exportNormalizedARKitData(_ session: ARKitSession, includeRawCells: Bool = true) throws -> URL {
        struct NormalizedFrame: Encodable {
            var rowIndex: Int; var timestampUptime: Double; var wallClock: Date?; var faceTracked: Bool?
            var cameraTrackingState: String?; var headWorldPosition: [Double]?; var headEulerRad: [String: Double]?
            var lookAtPoint: [Double]?; var blendShapes: [String: Double]; var activeMarker: String?
            var raw: [String: Double]?
        }
        struct Export: Encodable {
            var session: ARKitSession
            var normalizedFrames: [NormalizedFrame]
        }
        let a = session.alignment
        let names = session.columns.map { $0.name }
        let frames = session.frames.map { f -> NormalizedFrame in
            var raw: [String: Double]? = nil
            if includeRawCells {
                var r: [String: Double] = [:]
                for (i, v) in f.values.enumerated() where v != nil { r[names[i]] = v }
                raw = r
            }
            let euler = f.headWorldTransform.map { FacialFeatureAnalyzer.eulerAngles(rowMajor: $0) }
            return NormalizedFrame(rowIndex: f.rowIndex, timestampUptime: f.timestampUptime, wallClock: a?.wallClock(forUptime: f.timestampUptime),
                                   faceTracked: f.faceTracked, cameraTrackingState: f.cameraTrackingState, headWorldPosition: f.headWorldPosition,
                                   headEulerRad: euler.map { ["pitch": $0.pitch, "yaw": $0.yaw, "roll": $0.roll] },
                                   lookAtPoint: f.lookAtPoint, blendShapes: f.blendShapes, activeMarker: f.activeMarker, raw: raw)
        }
        var slim = session
        slim.frames = [] // frames are written once, in normalized form
        return try FileExport.writeJSON(Export(session: slim, normalizedFrames: frames), name: "arkit-\(session.id)-normalized.json")
    }
}
