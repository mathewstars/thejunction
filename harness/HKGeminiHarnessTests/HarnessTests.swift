import XCTest
@testable import HKGeminiHarness

/// Unit tests for the pure modules: CSV import, time alignment, statistics, facial features, the
/// health summary builder, the XML importer and the response validator. No HealthKit or network.
/// Run on a Mac: Product ▸ Test (⌘U) with any iPhone simulator selected.
final class HarnessTests: XCTestCase {

    // MARK: Fixtures

    /// A FaceMetrics-shaped CSV with a reduced column set (the importer reads the header, so a subset
    /// is a valid export) and 10 s at 30 fps with a blink every 3 s and a smile marker in the middle.
    func makeCSV(wallClockStart: Double = 1_794_600_000, uptimeStart: Double = 5000.0, blinkEvery: Double = 3) -> URL {
        var header = ["sample_index", "frame_index", "timestamp_s", "recording_time_s", "wall_clock_unix_s", "frame_interval_s",
                      "dropped_frames_est", "face_anchor_present", "face_tracked", "camera_tracking_state", "camera_limited_reason", "active_marker"]
        for r in 0..<4 { for c in 0..<4 { header.append("head_world_m\(r)\(c)") } }
        header += ["head_world_pos_x", "head_world_pos_y", "head_world_pos_z", "look_at_x", "look_at_y", "look_at_z"]
        let bs = ["browInnerUp", "eyeBlink_L", "eyeBlink_R", "jawOpen", "mouthSmile_L", "mouthSmile_R"]
        header += bs.map { "bs_\($0)" }
        header += ["quality_score", "blink_rate_per_min", "mesh_vertex_count", "light_ambient_intensity", "light_color_temperature_k",
                   "camera_exposure_duration_s", "camera_exposure_offset", "depth_data_available", "depth_data_timestamp_s", "future_column_xyz"]
        var lines = [header.joined(separator: ",")]
        let n = 300
        for i in 0..<n {
            let t = Double(i) / 30
            let uptime = uptimeStart + t
            let tracked = i >= 15 // first half second untracked
            let blinkPhase = t.truncatingRemainder(dividingBy: blinkEvery)
            let blink = (blinkPhase >= 1.0 && blinkPhase < 1.12) ? 0.9 : 0.05
            let smile = (t >= 4 && t < 7) ? 0.7 : 0.05
            let yaw = 0.1 * sin(2 * Double.pi * 0.5 * t)
            var cells: [String] = [String(i), String(i + 10), "\(uptime)", "\(t)", "\(wallClockStart + t)", i == 0 ? "" : "0.0333", "0", "1",
                                   tracked ? "1" : "0", "normal", "", (t >= 4 && t < 7) ? "Smile" : ""]
            if tracked {
                // Rotation about Y by yaw, translation (0, 0.05, -0.4).
                let m: [Double] = [cos(yaw), 0, sin(yaw), 0, 0, 1, 0, 0.05, -sin(yaw), 0, cos(yaw), -0.4, 0, 0, 0, 1]
                cells += m.map { "\($0)" }
                cells += ["0", "0.05", "-0.4", "0.02", "0.01", "0.5"]
                cells += [String(0.1), "\(blink)", "\(blink * 0.95)", "0.02", "\(smile)", "\(smile * 0.9)"]
            } else {
                cells += Array(repeating: "", count: 16 + 6 + bs.count)
            }
            cells += ["0.95", "20", tracked ? "1220" : "", "980", "4500", "0.0167", "0.1", "1", "\(uptime)", "42"]
            XCTAssertEqual(cells.count, header.count)
            lines.append(cells.joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID().uuidString).csv")
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeManifest(createdAtUnix: Double = 1_794_600_000, startUptime: Double = 5000.0) -> URL {
        let json = """
        {"formatVersion":1,"id":"20261114-101640-abc123","app":{"name":"FaceMetrics","version":"0.1.0","build":"1"},
         "device":{"model":"iPhone16,1","systemName":"iOS","systemVersion":"17.5"},
         "createdAt":"\(ISO8601.string(from: Date(timeIntervalSince1970: createdAtUnix)))",
         "endedAt":"\(ISO8601.string(from: Date(timeIntervalSince1970: createdAtUnix + 10)))",
         "recordingStartTimestamp":\(startUptime),"recordingEndTimestamp":\(startUptime + 9.9667),"durationSeconds":9.9667,
         "configuration":{"targetSampleRate":30,"writeJSONSamples":false,"includeFaceGeometry":false,"geometryEveryNthSample":1,"participantLabel":"P01","notes":""},
         "tracking":{"videoFormat":"1280x720 @ 30 fps","framesPerSecond":30,"lightEstimationEnabled":true,"expectedFrameIntervalSeconds":0.0333,"supportsWorldTracking":false,"supportedNumberOfTrackedFaces":1},
         "sampleCount":300,"trackedSampleCount":285,"framesSeen":300,"framesSkippedByRateLimit":0,"droppedFramesEstimate":0,"pauses":[],
         "blendShapeIdentifiers":["browInnerUp","eyeBlink_L","eyeBlink_R","jawOpen","mouthSmile_L","mouthSmile_R"],"blendShapeFriendlyNames":{},
         "columns":[{"name":"timestamp_s","unit":"s","origin":"arkit","description":"ARFrame.timestamp, device uptime clock."},{"name":"quality_score","unit":"0-1","origin":"derived","description":"app score"}],
         "coefficientStatistics":{},"markers":[{"id":"m1","label":"Smile","kind":"interval","startTimestamp":\(startUptime + 4),"endTimestamp":\(startUptime + 7),"recordingStartTime":4,"recordingEndTime":7,"startFrameIndex":130,"endFrameIndex":220,"wallClock":"\(ISO8601.string(from: Date(timeIntervalSince1970: createdAtUnix + 4)))"}],
         "blinkEvents":[],"lowActivityPeriods":[],
         "lifecycle":[{"date":"\(ISO8601.string(from: Date(timeIntervalSince1970: createdAtUnix - 1)))","kind":"started","detail":""},{"date":"\(ISO8601.string(from: Date(timeIntervalSince1970: createdAtUnix)))","kind":"faceAnchorAdded","detail":""}],
         "summary":{"averageFPS":30,"trackedSampleFraction":0.95,"interruptions":0,"blinkCount":3,"closureCount":0,"activationEvents":2,"lowActivityPeriods":0,"unknownBlendShapeKeysSeen":0},
         "files":["samples.csv","session.json"],"notes":[]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: CSV import

    func testCSVImportReadsHeaderDrivenColumns() throws {
        let importer = ARKitDatasetImporter()
        let s = try importer.importARKitCSV(file: makeCSV())
        XCTAssertEqual(s.frames.count, 300)
        XCTAssertEqual(s.blendShapeIdentifiers, ["browInnerUp", "eyeBlink_L", "eyeBlink_R", "jawOpen", "mouthSmile_L", "mouthSmile_R"])
        XCTAssertEqual(s.frames[0].faceTracked, false)
        XCTAssertEqual(s.frames[20].faceTracked, true)
        XCTAssertEqual(s.frames[20].headWorldTransform?.count, 16)
        XCTAssertEqual(s.frames[20].lookAtPoint, [0.02, 0.01, 0.5])
        XCTAssertEqual(s.frames[20].blendShapes["jawOpen"], 0.02)
        XCTAssertNil(s.frames[0].blendShapes["jawOpen"], "untracked frames must have no coefficients, not zeros")
        // Unknown column kept as raw value and reported.
        let unknown = s.columns.first { $0.name == "future_column_xyz" }
        XCTAssertNotNil(unknown)
        XCTAssertFalse(unknown!.recognised)
        XCTAssertEqual(s.frames[5].values[unknown!.index], 42)
        XCTAssertEqual(s.validation?.unknownColumns, ["future_column_xyz"])
        // Marker text preserved.
        XCTAssertEqual(s.frames[150].activeMarker, "Smile")
        XCTAssertEqual(s.frames[150].textValues.count, 2) // camera_tracking_state + active_marker
    }

    func testValidationNumbers() throws {
        let s = try ARKitDatasetImporter().importARKitCSV(file: makeCSV())
        let v = s.validation!
        XCTAssertEqual(v.frameCount, 300)
        XCTAssertEqual(v.trackedFrameCount, 285)
        XCTAssertEqual(v.recordingDurationSeconds, 299.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(v.effectiveFrameRate!, 30, accuracy: 0.01)
        XCTAssertEqual(v.missingFramesEstimate, 0)
        XCTAssertEqual(v.gapCount, 0)
        XCTAssertEqual(v.blendShapeMissingFraction, 0)
        XCTAssertEqual(v.cameraStateDistribution["normal"]!, 1, accuracy: 1e-9)
        XCTAssertEqual(v.faceLostEvents, 0)
        XCTAssertFalse(v.geometryAvailable)
    }

    // MARK: Alignment

    func testAlignmentPrefersManifestAndCrossChecksCSV() throws {
        let importer = ARKitDatasetImporter()
        var s = try importer.importARKitCSV(file: makeCSV(wallClockStart: 1_794_600_000, uptimeStart: 5000))
        XCTAssertEqual(s.alignment?.method, .csvWallClock, "without session.json the CSV wall clock is the only anchor")
        XCTAssertEqual(s.alignment!.uptimeToUnixOffsetSeconds!, 1_794_600_000 - 5000, accuracy: 1e-6)

        let m = try importer.importSessionJSON(file: makeManifest(createdAtUnix: 1_794_600_000, startUptime: 5000))
        importer.attach(manifest: m, fileName: "session.json", to: &s)
        XCTAssertEqual(s.id, "20261114-101640-abc123")
        XCTAssertEqual(s.alignment?.method, .sessionManifest)
        XCTAssertEqual(s.alignment!.uptimeToUnixOffsetSeconds!, 1_794_600_000 - 5000, accuracy: 1e-6)
        XCTAssertEqual(s.alignment!.crossCheckResidualMedianSeconds!, 0, accuracy: 1e-6)
        XCTAssertEqual(s.alignment!.recordingStartWallClock!.timeIntervalSince1970, 1_794_600_000, accuracy: 1e-6)
        XCTAssertTrue(s.alignment!.warnings.isEmpty, "\(s.alignment!.warnings)")
        // Manifest column docs applied.
        XCTAssertEqual(s.columns.first { $0.name == "quality_score" }?.origin, "derived")
    }

    func testAlignmentWarnsWhenClocksDisagree() throws {
        let importer = ARKitDatasetImporter()
        var s = try importer.importARKitCSV(file: makeCSV(wallClockStart: 1_794_600_000, uptimeStart: 5000))
        // Manifest says the recording started 10 s later than the per-row wall clock claims.
        let m = try importer.importSessionJSON(file: makeManifest(createdAtUnix: 1_794_600_010, startUptime: 5000))
        importer.attach(manifest: m, fileName: "session.json", to: &s)
        XCTAssertEqual(s.alignment?.method, .sessionManifest, "manifest stays the anchor")
        XCTAssertEqual(s.alignment!.crossCheckResidualMedianSeconds!, -10, accuracy: 1e-6)
        XCTAssertTrue(s.alignment!.warnings.contains { $0.contains("disagrees") })
    }

    func testUnalignedWithoutAnyAnchor() throws {
        // Strip the wall clock column.
        let url = makeCSV()
        var text = try String(contentsOf: url)
        var lines = text.components(separatedBy: "\n")
        let header = lines[0].components(separatedBy: ",")
        let idx = header.firstIndex(of: "wall_clock_unix_s")!
        lines = lines.map { line in
            guard !line.isEmpty else { return line }
            var c = line.components(separatedBy: ","); c.remove(at: idx); return c.joined(separator: ",")
        }
        text = lines.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let s = try ARKitDatasetImporter().importARKitCSV(file: url)
        XCTAssertEqual(s.alignment?.method, .unaligned)
        XCTAssertNil(s.alignment?.uptimeToUnixOffsetSeconds)
        XCTAssertTrue(s.validation!.issues.contains { $0.severity == "error" })
    }

    // MARK: Facial features

    func testBlinkAndMarkerFeatures() throws {
        let s = try ARKitDatasetImporter().importARKitCSV(file: makeCSV())
        let analyzer = FacialFeatureAnalyzer()
        let whole = analyzer.sessionLevelWindow(session: s)!
        // Blinks at t = 1, 4, 7 s (t = 10 is outside). Tracking starts at 0.5 s so all three are visible.
        XCTAssertEqual(whole.blink?.count, 3)
        XCTAssertEqual(whole.blink!.ratePerMinute!, 3 / (284.0 / 30) * 60, accuracy: 0.5)
        XCTAssertEqual(whole.blink!.meanDurationSeconds!, 0.1, accuracy: 0.04)
        XCTAssertEqual(whole.trackingQuality.trackedFraction, 0.95, accuracy: 1e-9)
        XCTAssertTrue(whole.supportingMeasurements.contains("bs_eyeBlink_L"))
        XCTAssertTrue(whole.supportingMeasurements.contains("head_world_m00"))
        XCTAssertEqual(whole.headMovement!.amplitudeRad["yaw"]!, 0.2, accuracy: 0.01, "yaw oscillates ±0.1 rad")
        XCTAssertEqual(whole.headMovement!.frequencyHz!, 0.5, accuracy: 0.15)
        XCTAssertEqual(whole.asymmetry!.pairCount, 2)
        XCTAssertEqual(whole.exportedDerivedMeans["quality_score"]!, 0.95, accuracy: 1e-9)

        let windows = analyzer.windows(session: s, windowSeconds: 5)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[1].markers, ["Smile"])
        XCTAssertGreaterThan(windows[1].blendShapeDynamics["mouthSmile_L"]!.mean!, windows[0].blendShapeDynamics["mouthSmile_L"]!.mean!)
        XCTAssertNotNil(windows[0].startWallClock, "no manifest: CSV wall clock still gives a date")
    }

    func testEulerDecomposition() {
        let yaw = 0.3
        let m: [Double] = [cos(yaw), 0, sin(yaw), 0, 0, 1, 0, 0, -sin(yaw), 0, cos(yaw), 0, 0, 0, 0, 1]
        let e = FacialFeatureAnalyzer.eulerAngles(rowMajor: m)
        XCTAssertEqual(e.yaw, 0.3, accuracy: 1e-9)
        XCTAssertEqual(e.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(e.roll, 0, accuracy: 1e-9)
    }

    // MARK: Statistics

    func testDescriptiveStatistics() {
        let d = LocalStatistics.describe([1, 2, 3, 4, 100])
        XCTAssertEqual(d.median, 3)
        XCTAssertEqual(d.mean!, 22, accuracy: 1e-9)
        XCTAssertEqual(d.medianAbsoluteDeviation, 1)
        XCTAssertEqual(d.interquartileRange!, 2, accuracy: 1e-9)
        XCTAssertEqual(LocalStatistics.spearman([1, 2, 3, 4, 5], [10, 20, 30, 40, 1000])!, 1, accuracy: 1e-9)
        XCTAssertEqual(LocalStatistics.pearson([1, 2, 3], [2, 4, 6])!, 1, accuracy: 1e-9)
        XCTAssertNil(LocalStatistics.standardDeviation([5]))
        XCTAssertEqual(LocalStatistics.zeroCrossingRate([1, -1, 1, -1, 1], durationSeconds: 2)!, 1, accuracy: 1e-9)
        let rolled = LocalStatistics.rollingMean([2, 4, 6, 8], window: 2)
        XCTAssertEqual(rolled, [2, 3, 5, 7])
    }

    func testSamplingFrequencyFlagsSparseHRV() {
        let base = Date(timeIntervalSince1970: 1_763_000_000)
        let dates = (0..<20).map { base.addingTimeInterval(Double($0) * 8 * 3600) } // every 8 h
        let f = LocalStatistics.samplingFrequency(dates)
        XCTAssertFalse(f.isContinuous)
        XCTAssertEqual(f.samplesPerDay!, 3, accuracy: 0.3)
    }

    // MARK: Health summary

    func testSleepAttributedToWakeDayAndLargestSourceWins() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        let night = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 23))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 7))!
        let watch = HealthSample(id: "a", kind: .category, typeIdentifier: "HKCategoryTypeIdentifierSleepAnalysis", displayName: "Sleep",
                                 startDate: night, endDate: morning, categoryValue: 3, categoryLabel: "asleepCore", sourceName: "Watch", origin: .healthKit)
        let phone = HealthSample(id: "b", kind: .category, typeIdentifier: "HKCategoryTypeIdentifierSleepAnalysis", displayName: "Sleep",
                                 startDate: night, endDate: morning.addingTimeInterval(-3600), categoryValue: 1, categoryLabel: "asleepUnspecified", sourceName: "iPhone", origin: .healthKit)
        let range = DateRange(start: cal.date(byAdding: .day, value: -10, to: morning)!, end: morning.addingTimeInterval(3600))
        let summary = HealthSummaryBuilder(range: range, calendar: cal).build(samples: [watch, phone])
        let sleep = summary.metrics.first { $0.typeIdentifier == "HKCategoryTypeIdentifierSleepAnalysis" }!
        XCTAssertEqual(sleep.daily.count, 1)
        XCTAssertEqual(sleep.daily[0].day, "2026-11-14", "night ending on the 14th belongs to the 14th")
        XCTAssertEqual(LocalStatistics.dailyValue(sleep.daily[0])!, 8, accuracy: 1e-9, "longest source (8 h) wins, not 8 + 7")
        XCTAssertTrue(summary.emptyTypes.contains("HKQuantityTypeIdentifierHeartRate"))
        XCTAssertTrue(summary.notes.contains { $0.contains("wake-up day") })
    }

    func testCumulativeSumsPreferDailyStatistics() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_763_000_000))
        let raw = (0..<4).map { i in
            HealthSample(id: "s\(i)", kind: .quantity, typeIdentifier: "HKQuantityTypeIdentifierStepCount", displayName: "Steps",
                         startDate: day.addingTimeInterval(Double(i) * 3600), endDate: day.addingTimeInterval(Double(i) * 3600 + 60),
                         value: 1000, unit: "count", sourceName: i % 2 == 0 ? "iPhone" : "Watch", origin: .healthKit)
        }
        let stat = HealthSample(id: "d", kind: .quantity, typeIdentifier: "HKQuantityTypeIdentifierStepCount", displayName: "Steps",
                                startDate: day, endDate: day.addingTimeInterval(86400), value: 2500, unit: "count", sourceName: "iPhone+Watch", origin: .derived)
        let range = DateRange(start: day, end: day.addingTimeInterval(86400))
        let withStats = HealthSummaryBuilder(range: range, calendar: cal).build(samples: raw, dailyStatistics: [stat])
        XCTAssertEqual(LocalStatistics.dailyValue(withStats.metrics[0].daily[0]), 2500)
        let without = HealthSummaryBuilder(range: range, calendar: cal).build(samples: raw)
        XCTAssertEqual(LocalStatistics.dailyValue(without.metrics[0].daily[0]), 2000, "largest single source, not the 4000 double count")
    }

    // MARK: XML import

    func testAppleHealthXMLImport() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_FI">
         <ExportDate value="2026-11-14 09:00:00 +0200"/>
         <Me HKCharacteristicTypeIdentifierDateOfBirth="1990-01-01" HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexNotSet"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" sourceVersion="10.5" device="&lt;&lt;HKDevice: 0x1&gt;, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch6,1&gt;" unit="count/min" creationDate="2026-11-13 10:00:05 +0200" startDate="2026-11-13 10:00:00 +0200" endDate="2026-11-13 10:00:00 +0200" value="62">
          <MetadataEntry key="HKMetadataKeyHeartRateMotionContext" value="1"/>
         </Record>
         <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" sourceName="iPhone" unit="km" startDate="2026-11-13 10:00:00 +0200" endDate="2026-11-13 10:10:00 +0200" value="0.5"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" startDate="2026-11-12 23:30:00 +0200" endDate="2026-11-13 06:30:00 +0200" value="HKCategoryValueSleepAnalysisAsleepCore"/>
         <Record type="HKQuantityTypeIdentifierSomethingNew" sourceName="X" unit="count" startDate="2026-11-13 10:00:00 +0200" endDate="2026-11-13 10:00:00 +0200" value="1"/>
         <Workout workoutActivityType="HKWorkoutActivityTypeWalking" duration="30" durationUnit="min" totalDistance="2.5" totalDistanceUnit="km" totalEnergyBurned="150" totalEnergyBurnedUnit="kcal" sourceName="Apple Watch" startDate="2026-11-13 17:00:00 +0200" endDate="2026-11-13 17:30:00 +0200"/>
        </HealthData>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        var out: [HealthSample] = []
        let result = try AppleHealthXMLImporter { out.append($0) }.run(file: url)
        XCTAssertEqual(result.recordCount, 4)
        XCTAssertEqual(result.workoutCount, 1)
        XCTAssertEqual(result.skippedUnknownTypes["HKQuantityTypeIdentifierSomethingNew"], 1)
        XCTAssertTrue(result.parseErrors.isEmpty, "\(result.parseErrors)")
        let hr = out.first { $0.typeIdentifier == "HKQuantityTypeIdentifierHeartRate" }!
        XCTAssertEqual(hr.value, 62); XCTAssertEqual(hr.deviceName, "Apple Watch"); XCTAssertEqual(hr.metadata["HKMetadataKeyHeartRateMotionContext"], .string("1"))
        XCTAssertEqual(hr.startDate.timeIntervalSince1970, 1_794_556_800, accuracy: 1) // 2026-11-13 08:00 UTC
        let dist = out.first { $0.typeIdentifier == "HKQuantityTypeIdentifierDistanceWalkingRunning" }!
        XCTAssertEqual(dist.value!, 500, accuracy: 1e-9); XCTAssertEqual(dist.unit, "m")
        let sleep = out.first { $0.kind == .category }!
        XCTAssertEqual(sleep.categoryValue, 3); XCTAssertEqual(sleep.categoryLabel, "asleepCore")
        let w = out.first { $0.kind == .workout }!
        XCTAssertEqual(w.value, 1800); XCTAssertEqual(w.workoutTotalDistanceM, 2500); XCTAssertEqual(w.workoutActivityType, "walking")
    }

    // MARK: Validator

    func makeRequest() -> GeminiAnalysisRequest {
        let payload: JSONValue = .object(["metrics": .array([.object(["metric": .string("HeartRateVariabilitySDNN"), "median": .number(42.37), "coverage": .number(0.82)])])])
        return GeminiAnalysisRequest(id: "r1", experiment: .healthKitOnly, model: "gemini-4-carbon", createdAt: Date(), systemInstruction: "", userPrompt: "",
                                     payload: payload, responseSchema: GeminiSchema.responseSchema(experiment: .healthKitOnly), thinkingLevel: "medium",
                                     inputDataRange: nil, dataCategories: [], payloadBytes: 0)
    }

    func validReply(observation: String, kind: String = "direct_observation") -> String {
        """
        {"experiment_type":"healthkit","baseline_summary":{"HRV":"median 42.37 ms"},
         "health_observations":[{"observation":"\(observation)","supporting_measurements":["HeartRateVariabilitySDNN.median = 42.37"],
           "time_range":{"start":"2026-10-01","end":"2026-11-14"},"kind":"\(kind)","data_quality":"coverage 82%","limitations":"sparse"}],
         "facial_behavior_observations":[],"cross_modal_patterns":[],"longitudinal_changes":[],"potential_confounders":[],
         "data_quality":{"overall":"ok"},"uncertainties":[],"recommended_tracking":[],"plain_language_explanation":"HRV median was 42.4 ms."}
        """
    }

    func testValidatorAcceptsNumbersFromPayloadWithRoundingAndPercent() {
        let (a, r) = GeminiResponseValidator.validate(rawText: validReply(observation: "Median HRV was 42.4 ms with 82% coverage."), request: makeRequest())
        XCTAssertNotNil(a)
        XCTAssertTrue(r.isValid, "\(r)")
        XCTAssertEqual(r.observationCount, 1)
        XCTAssertTrue(r.unsupportedNumbers.isEmpty, "\(r.unsupportedNumbers)")
    }

    func testValidatorRejectsInventedNumbers() {
        let (_, r) = GeminiResponseValidator.validate(rawText: validReply(observation: "Median HRV was 57.9 ms."), request: makeRequest())
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.unsupportedNumbers.filter { $0.severity == "error" }.count, 1)
    }

    func testValidatorRejectsWrongExperimentAndBadKind() {
        let (_, r) = GeminiResponseValidator.validate(rawText: validReply(observation: "x", kind: "fact"), request: makeRequest())
        XCTAssertFalse(r.isValid)
        XCTAssertTrue(r.schemaErrors.contains { $0.location.hasSuffix(".kind") })
        let (a2, r2) = GeminiResponseValidator.validate(rawText: "```json\n{\"experiment_type\":\"combined\"}\n```", request: makeRequest())
        XCTAssertNil(a2); XCTAssertFalse(r2.isValid)
    }

    func testValidatorFlagsEmotionVocabulary() {
        let (_, r) = GeminiResponseValidator.validate(rawText: validReply(observation: "The person seems depressed."), request: makeRequest())
        XCTAssertEqual(r.forbiddenTerms.count, 1)
        XCTAssertTrue(r.isValid, "vocabulary is a warning by default")
    }

    // MARK: Combined

    func testCombinedDailyRowsAndCorrelations() throws {
        let importer = ARKitDatasetImporter()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        var summaries: [ARKitSessionSummary] = []
        var hrv: [HealthSample] = []
        for d in 0..<10 {
            let date = day0.addingTimeInterval(Double(d) * 86400)
            var s = try importer.importARKitCSV(file: makeCSV(wallClockStart: date.timeIntervalSince1970, uptimeStart: 1000, blinkEvery: 1.5 + Double(d) * 0.4))
            let m = try importer.importSessionJSON(file: makeManifest(createdAtUnix: date.timeIntervalSince1970, startUptime: 1000))
            importer.attach(manifest: m, fileName: "session.json", to: &s)
            s.id = "s\(d)"
            summaries.append(importer.generateARKitSummary(s))
            hrv.append(HealthSample(id: "h\(d)", kind: .quantity, typeIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", displayName: "HRV",
                                    startDate: date.addingTimeInterval(-3600 * 6), endDate: date.addingTimeInterval(-3600 * 6), value: 40 + Double(d), unit: "ms", sourceName: "Watch", origin: .healthKit))
        }
        let range = DateRange(start: day0.addingTimeInterval(-86400), end: day0.addingTimeInterval(10 * 86400))
        let health = HealthSummaryBuilder(range: range, calendar: cal).build(samples: hrv)
        let ds = CombinedDatasetBuilder(calendar: cal).buildCombinedDataset(healthData: health, arKitData: summaries, healthSamples: hrv)
        XCTAssertEqual(ds.dailyRows.count, 10)
        XCTAssertEqual(ds.dailyRows[0].health["HeartRateVariabilitySDNN"], 40)
        XCTAssertEqual(ds.dailyRows[1].previousDayHealth["HeartRateVariabilitySDNN"], 40)
        XCTAssertNotNil(ds.dailyRows[0].facial["blinkRatePerMinute"])
        XCTAssertEqual(ds.dailyRows[0].arKitSessionIDs, ["s0"])
        let c = ds.correlations.first { $0.metricA == "HeartRateVariabilitySDNN" && $0.metricB == "blinkRatePerMinute" && $0.lagDays == 0 }!
        XCTAssertEqual(c.pairedPoints, 10)
        XCTAssertNotNil(c.spearmanRho)
        XCTAssertFalse(ds.bins.isEmpty)
        let baseline = BaselineBuilder(calendar: cal).build(health: health, arKit: summaries)
        XCTAssertEqual(baseline.healthReferences.first?.median, 44.5)
        XCTAssertFalse(baseline.facialReferences.isEmpty)
    }

    func testPayloadBuilderStripsIdentifiersAndWindowsTables() throws {
        let importer = ARKitDatasetImporter()
        var s = try importer.importARKitCSV(file: makeCSV())
        importer.attach(manifest: try importer.importSessionJSON(file: makeManifest()), fileName: "session.json", to: &s)
        let summary = importer.generateARKitSummary(s)
        let (payload, _, _) = try GeminiPayloadBuilder().arKitPayload([summary])
        let text = payload.description
        XCTAssertFalse(text.contains("P01"), "participant label must not be in the payload")
        XCTAssertFalse(text.contains("iPhone16,1"), "device model is not needed by the model")
        XCTAssertTrue(text.contains("session_level_features"))
        XCTAssertTrue(payload["sessions"]![0]!["windows"]!["60s"] != nil)
    }

    // MARK: Engine adapters

    func testFaceRawBuilderMapsNamesResamplesAndMarksUntracked() throws {
        let importer = ARKitDatasetImporter()
        var s = try importer.importARKitCSV(file: makeCSV())
        importer.attach(manifest: try importer.importSessionJSON(file: makeManifest()), fileName: "session.json", to: &s)
        let (raw, report) = try FaceRawBuilder().build(session: s)
        XCTAssertEqual(raw.rateHz, 30)
        XCTAssertEqual(Array(raw.channels.suffix(3)), ["headPitch", "headYaw", "headRoll"])
        XCTAssertTrue(raw.channels.contains("eyeBlinkLeft") && raw.channels.contains("mouthSmileRight"))
        XCTAssertFalse(raw.channels.contains("eyeBlink_L"), "engine spelling, not ARKit raw identifiers")
        XCTAssertEqual(raw.channels.count, 6 + 3)
        XCTAssertEqual(raw.samples.count, 300, "10 s at 30 Hz: 299 intervals + 1 grid point")
        XCTAssertEqual(raw.samples[0].count, raw.channels.count)
        let tracked = raw.tracked!
        XCTAssertEqual(tracked.prefix(15).reduce(0, +), 0, "first half second untracked")
        XCTAssertEqual(tracked.suffix(100).reduce(0, +), 100)
        XCTAssertEqual(raw.samples[0], [Double](repeating: 0, count: 9), "untracked rows are zeros")
        let yawIndex = raw.channels.firstIndex(of: "headYaw")!
        XCTAssertEqual(raw.samples[45][yawIndex], 0.1 * sin(2 * Double.pi * 0.5 * 1.5) * 180 / .pi, accuracy: 0.6, "t = 1.5 s: yaw ≈ −5.7°")
        XCTAssertTrue(report.headAngleSource.contains("head_world"), "fixture has no head_view columns")
        XCTAssertEqual(report.trackedFraction, 285.0 / 300, accuracy: 0.01)
        XCTAssertTrue(raw.samples.allSatisfy { row in row.prefix(6).allSatisfy { $0 >= 0 && $0 <= 1 } })
    }

    func testFaceRawBuilderLowersRateToFitSampleLimit() throws {
        // 500 s at 30 Hz would be 15 001 samples; the builder must drop the rate.
        var header = ["timestamp_s", "face_tracked", "bs_eyeBlink_L", "bs_eyeBlink_R", "bs_mouthSmile_L", "bs_mouthSmile_R"]
        for r in 0..<4 { for c in 0..<4 { header.append("head_world_m\(r)\(c)") } }
        var lines = [header.joined(separator: ",")]
        for i in 0..<15000 {
            lines.append(["\(1000 + Double(i) / 30)", "1", "0.05", "0.05", "0.1", "0.1", "1", "0", "0", "0", "0", "1", "0", "0", "0", "0", "1", "-0.4", "0", "0", "0", "1"].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID().uuidString).csv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let s = try ARKitDatasetImporter().importARKitCSV(file: url)
        let (raw, report) = try FaceRawBuilder().build(session: s)
        XCTAssertLessThanOrEqual(raw.samples.count, EngineFaceRaw.maxSamples)
        XCTAssertLessThan(raw.rateHz, 30)
        XCTAssertGreaterThanOrEqual(raw.rateHz, 5)
        XCTAssertTrue(report.warnings.contains { $0.contains("lowered") })
        XCTAssertNil(raw.tracked, "all frames tracked: tracked omitted")
    }

    func testEngineActivityBuilderAndClientID() throws {
        let importer = ARKitDatasetImporter()
        var s = try importer.importARKitCSV(file: makeCSV())
        importer.attach(manifest: try importer.importSessionJSON(file: makeManifest()), fileName: "session.json", to: &s)
        let (raw, _) = try FaceRawBuilder().build(session: s)
        let a = try EngineActivityBuilder.activity(for: s, faceRaw: raw, kind: .breathing)
        XCTAssertEqual(a.type, "breathing")
        XCTAssertEqual(a.id, "fm-20261114-101640-abc123")
        XCTAssertEqual(a.startedAt, "2026-11-13T20:00:00Z", "manifest createdAt 1_794_600_000")
        XCTAssertEqual(a.durationS, 10.0, accuracy: 0.11)
        XCTAssertNotNil(a.timePlayedS); XCTAssertNil(a.correctTaps)
        let data = try JSONValue.encoder(pretty: false).encode(a)
        let json = try JSONValue.decoder().decode(JSONValue.self, from: data)
        XCTAssertNil(json["correct_taps"], "nil optionals must not be encoded (engine forbids extra keys)")
        XCTAssertNil(json["suggestion_id"])
        XCTAssertNotNil(json["face_raw"]?["samples"])
        XCTAssertEqual(EngineActivity.clientID(from: "fm/20261114 101640.abc"), "fm-20261114-101640-abc")
        XCTAssertEqual(EngineActivity.clientID(from: "ab").count, 8)
        var unaligned = try importer.importARKitCSV(file: makeCSV())
        unaligned.alignment = nil
        XCTAssertThrowsError(try EngineActivityBuilder.activity(for: unaligned, faceRaw: raw, kind: .breathing))
    }

    func testDailyRecordBuilderRequiresSteps() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_794_528_000))
        func q(_ id: String, _ v: Double, _ offset: Int, unit: String) -> HealthSample {
            let d = day.addingTimeInterval(Double(offset) * 86400 + 3600 * 12)
            return HealthSample(id: UUID().uuidString, kind: .quantity, typeIdentifier: id, displayName: id, startDate: d, endDate: d, value: v, unit: unit, sourceName: "W", origin: .healthKit)
        }
        let samples = [q("HKQuantityTypeIdentifierStepCount", 8000, 0, unit: "count"), q("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", 41.26, 0, unit: "ms"),
                       q("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", 50, 1, unit: "ms")]
        let range = DateRange(start: day, end: day.addingTimeInterval(2 * 86400))
        let summary = HealthSummaryBuilder(range: range, calendar: cal).build(samples: samples)
        let r = DailyRecordBuilder.build(from: summary)
        XCTAssertEqual(r.days.count, 1)
        XCTAssertEqual(r.days[0].steps, 8000)
        XCTAssertEqual(r.days[0].hrvMs, 41.3)
        XCTAssertNil(r.days[0].sleepH)
        XCTAssertEqual(r.skippedDays.count, 1, "the HRV-only day has no steps and is skipped")
        let data = try! JSONValue.encoder(pretty: false).encode(EngineDailyIn(days: r.days))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"hrv_ms\":41.3") && text.contains("\"steps\":8000"))
        XCTAssertFalse(text.contains("sleep_h"), "nil optionals omitted")
    }
}
