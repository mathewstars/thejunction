import SwiftUI
import UniformTypeIdentifiers

struct ARKitImportScreen: View {
    @EnvironmentObject var state: AppState
    @State private var importKind: ImportKind?
    @State private var targetSessionID: String?
    @State private var geometryWarning = false

    enum ImportKind: Identifiable { case csv, folder, sessionJSON, geometry; var id: Int { hashValue } }

    var body: some View {
        NavigationStack {
            List {
                Section("Import FaceMetrics exports") {
                    Button("Import samples.csv") { importKind = .csv }
                    Button("Import a whole session folder (csv + session.json)") { importKind = .folder }
                    Text("session.json and geometry are attached to a session from its detail page. Geometry is identifiable and off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(state.busy != nil)

                Section("Sessions (\(state.arKitSessions.count))") {
                    if state.arKitSessions.isEmpty { Text("Nothing imported yet.").foregroundStyle(.secondary) }
                    ForEach(state.arKitSessions) { s in
                        NavigationLink { SessionDetail(sessionID: s.id, importKind: $importKind, targetSessionID: $targetSessionID, geometryWarning: $geometryWarning) } label: {
                            sessionRow(s)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { state.removeSession(s.id) } }
                    }
                }
                ExportFooter()
            }
            .navigationTitle("ARKit Import")
            .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let u = urls.first, let kind = importKind else { importKind = nil; return }
                importKind = nil
                Task {
                    switch kind {
                    case .csv: await state.importCSV(u)
                    case .folder: await state.importSessionFolder(u)
                    case .sessionJSON: if let id = targetSessionID { await state.importSessionJSON(u, into: id) }
                    case .geometry: if let id = targetSessionID { await state.importGeometry(u, into: id) }
                    }
                }
            }
            .alert("Load face geometry?", isPresented: $geometryWarning) {
                Button("Load", role: .destructive) { importKind = .geometry }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("geometry.bin holds the identifiable face mesh. It stays on this device; only aggregate numbers derived from it can be sent, and only in the separate geometry experiment.")
            }
        }
    }

    private var allowedTypes: [UTType] {
        switch importKind {
        case .csv: return [.commaSeparatedText, .plainText, .data]
        case .folder: return [.folder]
        case .sessionJSON: return [.json]
        case .geometry: return [.data, .json]
        case .none: return [.data]
        }
    }

    private func sessionRow(_ s: ARKitSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.id).font(.callout.monospaced()).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { state.selectedSessionIDs.contains(s.id) },
                                         set: { on in if on { state.selectedSessionIDs.insert(s.id) } else { state.selectedSessionIDs.remove(s.id) } }))
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                Text("\(s.frames.count) frames · \(Fmt.num(s.validation?.recordingDurationSeconds, 0)) s · \(s.blendShapeIdentifiers.count) bs")
                StatusBadge(text: s.manifest == nil ? "no session.json" : "session.json", tone: s.manifest == nil ? .warn : .good)
                StatusBadge(text: s.alignment?.method.rawValue ?? "unaligned", tone: (s.alignment?.method ?? .unaligned) == .unaligned ? .bad : .good)
                if s.geometry != nil { StatusBadge(text: "geometry", tone: .neutral) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SessionDetail: View {
    @EnvironmentObject var state: AppState
    let sessionID: String
    @Binding var importKind: ARKitImportScreen.ImportKind?
    @Binding var targetSessionID: String?
    @Binding var geometryWarning: Bool
    @State private var windowLength: Double = 30
    @State private var featureKey = "blinkRatePerMinute"

    private var session: ARKitSession? { state.arKitSessions.first { $0.id == sessionID } }

    var body: some View {
        if let s = session {
            List {
                Section("Attach") {
                    Button("Attach session.json") { targetSessionID = s.id; importKind = .sessionJSON }
                    Button("Load geometry.bin (identifiable, optional)") { targetSessionID = s.id; geometryWarning = true }
                    Button("Export normalized JSON") { state.exportNormalized(s) }
                }
                .disabled(state.busy != nil)

                if let v = s.validation { validationSection(v) }
                if let a = s.alignment { alignmentSection(a) }
                if let m = s.manifest { manifestSection(m) }
                featuresSection(s)
                rawSection(s)
            }
            .navigationTitle(s.id)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("Session removed.")
        }
    }

    private func validationSection(_ v: ARKitValidationReport) -> some View {
        Section("Validation") {
            KV("Frames", v.frameCount); KV("Tracked frames", v.trackedFrameCount)
            KV("Duration (minus pauses)", v.recordingDurationSeconds, digits: 1, unit: "s")
            KV("Effective fps", v.effectiveFrameRate, digits: 2); KV("Expected fps", v.expectedFrameRate, digits: 0)
            KV("Median interval", v.medianFrameIntervalSeconds.map { $0 * 1000 }, digits: 1, unit: "ms")
            KV("Missing frames (est.)", v.missingFramesEstimate); KV("Gaps > 1 s", v.gapCount); KV("Largest gap", v.largestGapSeconds, digits: 2, unit: "s")
            KV("Pauses", v.pauseCount); KV("Paused", v.pausedSeconds, digits: 1, unit: "s")
            KV("Interruptions", v.interruptionCount); KV("Face lost events", v.faceLostEvents)
            KV("Blend-shape columns", v.blendShapeColumns); KV("Missing bs cells", Fmt.pct(v.blendShapeMissingFraction))
            KV("Camera states", v.cameraStateDistribution.map { "\($0.key) \(Fmt.pct($0.value))" }.sorted().joined(separator: ", "))
            if !v.limitedReasons.isEmpty { KV("Limited reasons", v.limitedReasons.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")) }
            KV("Ambient light (mean)", v.ambientIntensity?.mean, digits: 0, unit: "lm"); KV("Colour temp (mean)", v.colorTemperatureK?.mean, digits: 0, unit: "K")
            KV("Exposure (mean)", v.exposureDurationS?.mean.map { $0 * 1000 }, digits: 1, unit: "ms")
            KV("Geometry", v.geometryAvailable ? "\(v.geometryRecords) records" : "none")
            if !v.unknownColumns.isEmpty { KV("Unknown columns", "\(v.unknownColumns.count)") }
            ForEach(Array(v.issues.enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top) { StatusBadge(text: i.severity, tone: i.severity == "error" ? .bad : (i.severity == "warning" ? .warn : .neutral)); Text(i.message).font(.caption) }
            }
        }
    }

    private func alignmentSection(_ a: TimestampAlignment) -> some View {
        Section("Time alignment (uptime → wall clock)") {
            KV("Method", a.method.rawValue)
            KV("Offset", a.uptimeToUnixOffsetSeconds, digits: 3, unit: "s")
            KV("Recording start", a.recordingStartWallClock); KV("Recording end", a.recordingEndWallClock)
            KV("Cross-check rows", a.crossCheckRows)
            KV("Residual median", a.crossCheckResidualMedianSeconds, digits: 3, unit: "s"); KV("Residual max", a.crossCheckResidualMaxSeconds, digits: 3, unit: "s")
            ForEach(a.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func manifestSection(_ m: ARKitSessionManifest) -> some View {
        Section("session.json") {
            KV("Created", m.createdAt); KV("Ended", m.endedAt)
            KV("Device", m.device?.model ?? "–"); KV("iOS", m.device?.systemVersion ?? "–")
            KV("Video", m.tracking?.videoFormat ?? "–"); KV("Camera fps", m.tracking?.framesPerSecond)
            KV("Target sample rate", m.configuration?.targetSampleRate, digits: 0)
            KV("Manifest samples", m.sampleCount); KV("Frames seen", m.framesSeen); KV("Skipped by rate limit", m.framesSkippedByRateLimit)
            KV("Markers", m.markers?.count ?? 0); KV("Recorder blink events", m.blinkEvents?.count ?? 0)
            KV("Lifecycle events", m.lifecycle?.count ?? 0)
            if let lc = m.lifecycle, !lc.isEmpty {
                DisclosureGroup("Lifecycle") {
                    ForEach(Array(lc.enumerated()), id: \.offset) { _, e in
                        Text("\(Fmt.dateTime(e.date))  \(e.kind)  \(e.detail ?? "")").font(.caption2.monospaced())
                    }
                }
            }
            if let mk = m.markers, !mk.isEmpty {
                DisclosureGroup("Markers") {
                    ForEach(Array(mk.enumerated()), id: \.offset) { _, e in
                        Text("\(e.label)  \(Fmt.num(e.recordingStartTime, 2))–\(Fmt.num(e.recordingEndTime, 2)) s").font(.caption2.monospaced())
                    }
                }
            }
        }
    }

    private func featuresSection(_ s: ARKitSession) -> some View {
        Section("Facial features") {
            Picker("Window", selection: $windowLength) { ForEach(FacialFeatureAnalyzer.standardWindows, id: \.self) { Text("\(Int($0)) s").tag($0) } }
                .pickerStyle(.segmented)
            Picker("Feature", selection: $featureKey) { ForEach(CombinedDatasetBuilder.facialKeys, id: \.self) { Text($0).tag($0) } }
            let summary = state.summary(for: s)
            let windows = summary.windowsBySeconds[String(Int(windowLength))] ?? []
            WindowChart(windows: windows, key: featureKey)
            KV("Windows", windows.count)
            if let w = summary.sessionLevelFeatures {
                DisclosureGroup("Whole-session features") {
                    if let b = w.blink { KV("Blinks", b.count); KV("Blink rate", b.ratePerMinute, digits: 1, unit: "/min"); KV("Blink duration", b.meanDurationSeconds.map { $0 * 1000 }, digits: 0, unit: "ms"); KV("Left-only / right-only", "\(b.leftOnlyCount) / \(b.rightOnlyCount)") }
                    if let e = w.eyeOpenness { KV("Eye openness mean", e.mean, digits: 3) }
                    if let h = w.headMovement { KV("Head amplitude (mean)", h.meanAmplitudeRad.map { $0 * 180 / .pi }, digits: 1, unit: "°"); KV("Head frequency", h.frequencyHz, digits: 2, unit: "Hz"); KV("Head pose variability", h.poseVariabilityRad.map { $0 * 180 / .pi }, digits: 2, unit: "°") }
                    if let f = w.facialMovement { KV("Facial amplitude", f.amplitude, digits: 3); KV("Facial variability", f.variability, digits: 3); KV("Activity", f.activityPerSecond, digits: 3, unit: "/s"); KV("Most active", f.mostActiveCoefficients.joined(separator: ", ")) }
                    if let a = w.asymmetry { KV("Asymmetry |L−R| overall", a.overallMeanAbsoluteDifference, digits: 3); KV("Pairs", a.pairCount) }
                    if let g = w.gaze { KV("Gaze direction changes", g.directionChangeCount); KV("Gaze speed", g.meanAngularSpeedDegPerS, digits: 1, unit: "°/s") }
                    KV("Tracked fraction", Fmt.pct(w.trackingQuality.trackedFraction))
                    KV("Missing bs fraction", Fmt.pct(w.missingBlendShapeFraction))
                    DisclosureGroup("Supporting columns (\(w.supportingMeasurements.count))") { Text(w.supportingMeasurements.joined(separator: ", ")).font(.caption2) }
                    DisclosureGroup("Recorder's own derived means") { ForEach(w.exportedDerivedMeans.sorted(by: { $0.key < $1.key }), id: \.key) { KV($0.key, $0.value, digits: 3) } }
                }
            }
            if let g = summary.geometryFeatures {
                DisclosureGroup("Geometry-derived features") {
                    KV("Records", g.recordCount); KV("Vertices", g.vertexCount)
                    KV("Mean displacement", g.meanInterRecordDisplacementM.map { $0 * 1000 }, digits: 2, unit: "mm")
                    KV("Max displacement", g.maxInterRecordDisplacementM.map { $0 * 1000 }, digits: 2, unit: "mm")
                    KV("Symmetry error", g.leftRightSymmetryError.map { $0 * 1000 }, digits: 2, unit: "mm")
                }
            }
        }
    }

    private func rawSection(_ s: ARKitSession) -> some View {
        Section("Raw measurements") {
            KV("Columns", s.columns.count); KV("Blend shapes", s.blendShapeIdentifiers.joined(separator: ", "))
            NavigationLink("Columns and fill rates") {
                List(s.columns) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack { Text(c.name).font(.caption.monospaced()); Spacer(); if !c.recognised { StatusBadge(text: "unknown", tone: .neutral) }; Text(c.origin ?? "").font(.caption2).foregroundStyle(.secondary) }
                        Text("\(c.numericCount) numeric · \(c.emptyCount) empty\(c.unit.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                        if let d = c.description { Text(d).font(.caption2).foregroundStyle(.secondary) }
                    }
                }.navigationTitle("Columns")
            }
            NavigationLink("First 200 frames") {
                List(s.frames.prefix(200)) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("#\(f.rowIndex) t=\(Fmt.num(f.timestampUptime, 3)) tracked=\(f.faceTracked == true ? "1" : "0") cam=\(f.cameraTrackingState ?? "–")").font(.caption2.monospaced())
                        Text("blink L/R \(Fmt.num(f.blendShapes["eyeBlink_L"], 2))/\(Fmt.num(f.blendShapes["eyeBlink_R"], 2)) · smile L/R \(Fmt.num(f.blendShapes["mouthSmile_L"], 2))/\(Fmt.num(f.blendShapes["mouthSmile_R"], 2)) · pos \(f.headWorldPosition.map { $0.map { Fmt.num($0, 3) }.joined(separator: ",") } ?? "–")").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }.navigationTitle("Frames")
            }
        }
    }
}
