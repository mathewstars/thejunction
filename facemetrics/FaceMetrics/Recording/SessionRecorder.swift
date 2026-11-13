import Foundation
import UIKit
import simd

struct RecordingConfiguration: Codable, Equatable {
    /// Target samples per second. Frames arriving faster than this are skipped, never averaged.
    var targetSampleRate: Double = 30
    /// Also stream every sample into samples.json (larger file, structured).
    var writeJSONSamples: Bool = true
    /// Opt-in: store the full face mesh per sample in geometry.bin. Identifiable; off by default.
    var includeFaceGeometry: Bool = false
    /// Store the mesh only for every Nth kept sample when geometry is on.
    var geometryEveryNthSample: Int = 1
    var participantLabel: String = ""
    var notes: String = ""
}

enum RecordingState: String {
    case idle, recording, paused
}

struct RecordingProgress {
    var state: RecordingState = .idle
    var sessionID: String?
    var startDate: Date?
    var sampleCount: Int = 0
    var recordedSeconds: Double = 0
    var bytesWritten: Int64 = 0
    var framesSkippedByRate: Int = 0
    var geometryRecords: Int = 0
    var folderURL: URL?
}

/// Data the view model passes in at stop time so the manifest can be completed.
struct RecordingFinalizationInput {
    var markers: [ExperimentMarker]
    var blinkEvents: [BlinkEvent]
    var lowActivityPeriods: [LowActivityPeriod]
    var lifecycle: [SessionLifecycleEvent]
    var activationEventCount: Int
    var interruptionCount: Int
    var averageFPS: Double
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case cannotCreateFolder(String)
    case cannotOpenFile(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already running."
        case .notRecording: return "No recording is running."
        case .cannotCreateFolder(let p): return "Could not create the session folder at \(p)."
        case .cannotOpenFile(let p): return "Could not open \(p) for writing."
        }
    }
}

/// Buffered appender around FileHandle. Flushes when the buffer passes `flushThreshold`.
final class BufferedFileWriter {
    let url: URL
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var bytesWritten: Int64 = 0
    var flushThreshold = 64 * 1024

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw RecorderError.cannotOpenFile(url.lastPathComponent) }
        self.handle = h
        buffer.reserveCapacity(flushThreshold * 2)
    }

    func write(_ string: String) {
        buffer.append(contentsOf: Array(string.utf8))
        if buffer.count >= flushThreshold { flush() }
    }

    func write(_ data: Data) {
        buffer.append(data)
        if buffer.count >= flushThreshold { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            bytesWritten += Int64(buffer.count)
        } catch {
            // Keep going; the manifest will report bytes actually written.
        }
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        guard !closed else { return }
        closed = true
        flush()
        try? handle.close()
    }

    private var closed = false

    deinit { close() }
}

/// Writes recorded sessions to Documents/FaceMetricsSessions/<id>/ on a serial utility queue.
/// `ingest` is called from the tracking queue and only enqueues; all file work happens here.
final class SessionRecorder {

    private let queue = DispatchQueue(label: "facemetrics.recorder", qos: .utility)
    private let stateLock = NSLock()
    private var _state: RecordingState = .idle
    var state: RecordingState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    private func setState(_ s: RecordingState) {
        stateLock.lock(); _state = s; stateLock.unlock()
    }

    /// Called on the main queue roughly twice a second while recording.
    var onProgress: ((RecordingProgress) -> Void)?

    // Everything below is touched only on `queue`.
    private final class Context {
        let id: String
        let folder: URL
        let configuration: RecordingConfiguration
        let setup: SessionManifest.TrackingSetup
        let device: SessionManifest.DeviceInfo
        let startDate = Date()
        var identifiers: [String]
        var csv: CSVExporter?
        var csvWriter: BufferedFileWriter?
        var jsonWriter: BufferedFileWriter?
        var geometryWriter: BufferedFileWriter?
        var geometryTriangles: [Int16]?
        var geometryVertexCount: Int = 0
        var geometryRecords: Int = 0
        var headerWritten = false
        var pending: [FaceSample] = []
        var sampleCount = 0
        var trackedSampleCount = 0
        var framesSeen = 0
        var skippedByRate = 0
        var droppedEstimate = 0
        var jsonRowsWritten = 0
        var lastKeptTimestamp: Double?
        var recordingStartTimestamp: Double?
        var lastTimestamp: Double?
        var pauseStart: Double?
        var pauses: [SessionManifest.PauseInterval] = []
        var stats: [String: RunningStatistics] = [:]
        var unknownKeys = Set<String>()
        var lastProgressReport: Double = 0

        init(id: String, folder: URL, configuration: RecordingConfiguration, setup: SessionManifest.TrackingSetup,
             device: SessionManifest.DeviceInfo, identifiers: [String]) {
            self.id = id
            self.folder = folder
            self.configuration = configuration
            self.setup = setup
            self.device = device
            self.identifiers = identifiers
        }
    }
    private var context: Context?

    static var sessionsRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("FaceMetricsSessions", isDirectory: true)
    }

    // MARK: Control

    /// Starts a new recording. `knownIdentifiers` fixes the blend-shape column order; if empty the
    /// columns are taken from the first tracked sample and earlier samples are buffered.
    func start(configuration: RecordingConfiguration, setup: SessionManifest.TrackingSetup, knownIdentifiers: [String]) throws -> (id: String, folder: URL) {
        guard state == .idle else { throw RecorderError.alreadyRecording }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let id = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        let folder = SessionRecorder.sessionsRootURL.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.cannotCreateFolder(folder.path)
        }
        // UIDevice is read here, on the caller's (main) thread, and stored for the manifest.
        let device = SessionManifest.DeviceInfo(model: UIDevice.current.model,
                                                systemName: UIDevice.current.systemName,
                                                systemVersion: UIDevice.current.systemVersion)
        let ctx = Context(id: id, folder: folder, configuration: configuration, setup: setup,
                          device: device, identifiers: knownIdentifiers.sorted())
        do {
            ctx.csvWriter = try BufferedFileWriter(url: folder.appendingPathComponent("samples.csv"))
            if configuration.writeJSONSamples {
                ctx.jsonWriter = try BufferedFileWriter(url: folder.appendingPathComponent("samples.json"))
                ctx.jsonWriter?.write("[\n")
            }
            if configuration.includeFaceGeometry {
                ctx.geometryWriter = try BufferedFileWriter(url: folder.appendingPathComponent("geometry.bin"))
            }
        } catch {
            // Do not leave a half-made session folder behind.
            ctx.csvWriter?.close()
            ctx.jsonWriter?.close()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // The context must be visible on the recorder queue before any frame can pass the state gate.
        queue.async {
            self.context = ctx
            self.reportProgress(ctx, force: true)
        }
        setState(.recording)
        return (id, folder)
    }

    func pause() {
        guard state == .recording else { return }
        setState(.paused)
        queue.async {
            guard let ctx = self.context else { return }
            ctx.pauseStart = ctx.lastTimestamp
            ctx.csvWriter?.flush()
            ctx.jsonWriter?.flush()
            ctx.geometryWriter?.flush()
            self.reportProgress(ctx, force: true)
        }
    }

    func resume() {
        guard state == .paused else { return }
        setState(.recording)
        // The pause interval is closed by the first frame that arrives after resuming (see process),
        // because no frame timestamps advance while paused.
        queue.async {
            guard let ctx = self.context else { return }
            self.reportProgress(ctx, force: true)
        }
    }

    /// Finishes the recording and writes session.json. Completion runs on the main queue.
    func stop(finalization: RecordingFinalizationInput, completion: @escaping (Result<URL, Error>) -> Void) {
        guard state != .idle else {
            DispatchQueue.main.async { completion(.failure(RecorderError.notRecording)) }
            return
        }
        setState(.idle)
        queue.async {
            guard let ctx = self.context else {
                DispatchQueue.main.async { completion(.failure(RecorderError.notRecording)) }
                return
            }
            self.context = nil
            // Samples buffered before any face appeared: write them with whatever identifiers we have.
            if !ctx.headerWritten {
                self.writeHeader(ctx, identifiers: ctx.identifiers)
            }
            // A pause that was never resumed ends with the recording; its length is unknown
            // (no frames arrived), so it is not added to the pause list.
            ctx.pauseStart = nil
            ctx.csvWriter?.close()
            if let jw = ctx.jsonWriter {
                jw.write("\n]\n")
                jw.close()
            }
            ctx.geometryWriter?.close()
            let result: Result<URL, Error>
            do {
                try self.writeGeometryHeader(ctx)
                try self.writeManifest(ctx, finalization: finalization)
                result = .success(ctx.folder)
            } catch {
                result = .failure(error)
            }
            var progress = RecordingProgress()
            progress.state = .idle
            DispatchQueue.main.async {
                self.onProgress?(progress)
                completion(result)
            }
        }
    }

    // MARK: Ingest (tracking queue -> recorder queue)

    func ingest(_ sample: FaceSample) {
        guard state == .recording else { return }
        queue.async { self.process(sample) }
    }

    private func process(_ sample: FaceSample) {
        // Frames already enqueued when pause/stop flipped the state are still written: `ingest` gates new ones.
        guard let ctx = context else { return }
        ctx.framesSeen += 1
        ctx.lastTimestamp = sample.timestamp
        ctx.droppedEstimate += sample.droppedFrameEstimate
        if let ps = ctx.pauseStart {
            // First frame after a resume closes the pause interval.
            ctx.pauses.append(.init(startTimestamp: ps, endTimestamp: sample.timestamp))
            ctx.pauseStart = nil
            ctx.lastKeptTimestamp = nil
        }

        let period = ctx.configuration.targetSampleRate > 0 ? 1.0 / ctx.configuration.targetSampleRate : 0
        if let last = ctx.lastKeptTimestamp, period > 0, sample.timestamp - last < period * 0.9 {
            ctx.skippedByRate += 1
            return
        }
        ctx.lastKeptTimestamp = sample.timestamp
        if ctx.recordingStartTimestamp == nil { ctx.recordingStartTimestamp = sample.timestamp }

        if !ctx.headerWritten {
            if ctx.identifiers.isEmpty, !sample.blendShapes.isEmpty {
                ctx.identifiers = sample.blendShapes.keys.sorted()
            }
            if ctx.identifiers.isEmpty {
                // No face seen yet and no known identifiers: hold the row until the schema is known.
                ctx.pending.append(sample)
                if ctx.pending.count > 3000 { ctx.pending.removeFirst() }
                return
            }
            writeHeader(ctx, identifiers: ctx.identifiers)
        }
        writeRow(ctx, sample)
        reportProgress(ctx, force: false)
    }

    private func writeHeader(_ ctx: Context, identifiers: [String]) {
        let csv = CSVExporter(blendShapeIdentifiers: identifiers)
        ctx.csv = csv
        ctx.csvWriter?.write(csv.headerLine)
        ctx.headerWritten = true
        let pending = ctx.pending
        ctx.pending.removeAll()
        for s in pending { writeRow(ctx, s) }
    }

    private func writeRow(_ ctx: Context, _ sample: FaceSample) {
        guard let csv = ctx.csv, let start = ctx.recordingStartTimestamp else { return }
        let index = ctx.sampleCount
        ctx.csvWriter?.write(csv.row(for: sample, sampleIndex: index, recordingStartTimestamp: start))
        if let jw = ctx.jsonWriter {
            if ctx.jsonRowsWritten > 0 { jw.write(",\n") }
            jw.write(JSONExporter.sampleObject(sample, sampleIndex: index, recordingStartTimestamp: start))
            ctx.jsonRowsWritten += 1
        }
        if sample.faceTracked {
            ctx.trackedSampleCount += 1
            for (id, v) in sample.blendShapes {
                if ctx.stats[id] == nil {
                    ctx.stats[id] = RunningStatistics()
                    if !ctx.identifiers.contains(id) { ctx.unknownKeys.insert(id) }
                }
                ctx.stats[id]!.add(v)
            }
            if let gw = ctx.geometryWriter, let mesh = sample.mesh,
               ctx.configuration.geometryEveryNthSample <= 1 || index % ctx.configuration.geometryEveryNthSample == 0 {
                if ctx.geometryTriangles == nil { ctx.geometryTriangles = mesh.triangleIndices }
                ctx.geometryVertexCount = mesh.vertices.count
                gw.write(SessionRecorder.geometryRecord(timestamp: sample.timestamp, sampleIndex: index, vertices: mesh.vertices))
                ctx.geometryRecords += 1
            }
        }
        ctx.sampleCount += 1
    }

    /// Record layout (little-endian): Float64 timestamp, Int32 sample_index, Int32 vertex_count, then vertex_count * 3 Float32 (x, y, z).
    static func geometryRecord(timestamp: Double, sampleIndex: Int, vertices: [SIMD3<Float>]) -> Data {
        var data = Data(capacity: 16 + vertices.count * 12)
        var t = timestamp.bitPattern.littleEndian
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        var si = Int32(sampleIndex).littleEndian
        withUnsafeBytes(of: &si) { data.append(contentsOf: $0) }
        var vc = Int32(vertices.count).littleEndian
        withUnsafeBytes(of: &vc) { data.append(contentsOf: $0) }
        var floats = [Float](repeating: 0, count: vertices.count * 3)
        for (i, v) in vertices.enumerated() {
            floats[i * 3] = v.x; floats[i * 3 + 1] = v.y; floats[i * 3 + 2] = v.z
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func writeGeometryHeader(_ ctx: Context) throws {
        guard ctx.configuration.includeFaceGeometry else { return }
        let header: [String: Any] = [
            "file": "geometry.bin",
            "record_layout": "little-endian: float64 timestamp_s, int32 sample_index, int32 vertex_count, then vertex_count x (float32 x, float32 y, float32 z) in face-anchor space, metres",
            "record_count": ctx.geometryRecords,
            "vertex_count": ctx.geometryVertexCount,
            "every_nth_sample": ctx.configuration.geometryEveryNthSample,
            "triangle_indices": (ctx.geometryTriangles ?? []).map { Int($0) },
            "privacy": "Face geometry is identifiable. It was recorded because the researcher opted in for this session."
        ]
        let data = try JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: ctx.folder.appendingPathComponent("geometry.json"))
    }

    private func writeManifest(_ ctx: Context, finalization: RecordingFinalizationInput) throws {
        let start = ctx.recordingStartTimestamp
        func rel(_ t: Double?) -> Double? {
            guard let t, let start else { return nil }
            return t - start
        }
        let markers = finalization.markers
            .filter { m in
                guard let start, let end = ctx.lastTimestamp else { return true }
                return m.startTimestamp >= start - 0.5 && m.startTimestamp <= end + 0.5
            }
            .map { m in
                SessionManifest.MarkerRecord(
                    id: m.id.uuidString, label: m.label, kind: m.kind.rawValue,
                    startTimestamp: m.startTimestamp, endTimestamp: m.endTimestamp,
                    recordingStartTime: rel(m.startTimestamp), recordingEndTime: rel(m.endTimestamp),
                    startFrameIndex: m.startFrameIndex, endFrameIndex: m.endFrameIndex,
                    wallClock: m.wallClock, note: m.note)
            }
        let blinks = finalization.blinkEvents
            .filter { b in
                guard let start, let end = ctx.lastTimestamp else { return true }
                return b.startTime >= start && b.startTime <= end
            }
            .map { b in
                SessionManifest.BlinkRecord(
                    startTimestamp: b.startTime, endTimestamp: b.endTime, recordingStartTime: rel(b.startTime),
                    durationSeconds: b.duration, peakLeft: b.peakLeft, peakRight: b.peakRight,
                    peakAsymmetry: b.peakAsymmetry, onsetLagSeconds: b.onsetLag, bilateral: b.bilateral,
                    kind: b.kind, interBlinkIntervalSeconds: b.interBlinkInterval)
            }
        let lows = finalization.lowActivityPeriods.map {
            SessionManifest.LowActivityRecord(startTimestamp: $0.start, endTimestamp: $0.end, durationSeconds: $0.duration)
        }
        let lifecycle = finalization.lifecycle
            .filter { $0.date >= ctx.startDate.addingTimeInterval(-1) }
            .map { SessionManifest.LifecycleRecord(date: $0.date, kind: $0.kind.rawValue, detail: $0.detail) }

        var stats: [String: SessionManifest.CoefficientSummary] = [:]
        for (id, s) in ctx.stats where s.hasValues {
            stats[id] = .init(minimum: s.minimum, maximum: s.maximum, mean: Float(s.mean),
                              standardDeviation: Float(s.standardDeviation), count: s.count)
        }
        var names: [String: String] = [:]
        for id in ctx.identifiers { names[id] = BlendShapeCatalog.friendlyName(for: id) }

        var files = ["samples.csv", "session.json"]
        if ctx.jsonWriter != nil { files.append("samples.json") }
        if ctx.geometryWriter != nil { files.append("geometry.bin"); files.append("geometry.json") }

        let info = Bundle.main.infoDictionary ?? [:]
        let duration: Double
        if let start, let end = ctx.lastTimestamp {
            let paused = ctx.pauses.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) }
            duration = max(0, end - start - paused)
        } else { duration = 0 }

        let manifest = SessionManifest(
            id: ctx.id,
            app: .init(name: "FaceMetrics",
                       version: info["CFBundleShortVersionString"] as? String ?? "",
                       build: info["CFBundleVersion"] as? String ?? ""),
            device: ctx.device,
            createdAt: ctx.startDate,
            endedAt: Date(),
            recordingStartTimestamp: start,
            recordingEndTimestamp: ctx.lastTimestamp,
            durationSeconds: duration,
            configuration: ctx.configuration,
            tracking: ctx.setup,
            sampleCount: ctx.sampleCount,
            trackedSampleCount: ctx.trackedSampleCount,
            framesSeen: ctx.framesSeen,
            framesSkippedByRateLimit: ctx.skippedByRate,
            droppedFramesEstimate: ctx.droppedEstimate,
            pauses: ctx.pauses,
            blendShapeIdentifiers: ctx.identifiers,
            blendShapeFriendlyNames: names,
            columns: ctx.csv?.columns ?? CSVExporter.buildColumns(blendShapeIdentifiers: ctx.identifiers),
            coefficientStatistics: stats,
            markers: markers,
            blinkEvents: blinks,
            lowActivityPeriods: lows,
            lifecycle: lifecycle,
            summary: .init(
                averageFPS: finalization.averageFPS,
                trackedSampleFraction: ctx.sampleCount > 0 ? Double(ctx.trackedSampleCount) / Double(ctx.sampleCount) : 0,
                interruptions: finalization.interruptionCount,
                blinkCount: blinks.filter { $0.kind == "blink" }.count,
                closureCount: blinks.filter { $0.kind == "closure" }.count,
                activationEvents: finalization.activationEventCount,
                lowActivityPeriods: lows.count,
                unknownBlendShapeKeysSeen: ctx.unknownKeys.count),
            files: files,
            notes: [
                "All values were computed on-device from ARKit face tracking. No camera images were stored.",
                "Columns with origin 'arkit' are copied from the SDK; 'derived' columns are computed by the app and are not emotions or clinical indicators.",
                "Empty CSV cells and JSON nulls mean the measurement was unavailable on that frame; they are never zero-filled.",
                "Eye gaze values are ARKit estimates without calibration. They are not screen-accurate and do not track pupils.",
                "Timestamps use the device uptime clock (ARFrame.timestamp); wall_clock_unix_s gives the matching wall time.",
                TrackingQualityReport.qualityScoreFormula
            ]
        )
        let data = try SessionManifest.encoder().encode(manifest)
        try data.write(to: ctx.folder.appendingPathComponent("session.json"))
    }

    // MARK: Progress

    private func reportProgress(_ ctx: Context, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - ctx.lastProgressReport >= 0.5 else { return }
        ctx.lastProgressReport = now
        var p = RecordingProgress()
        p.state = state
        p.sessionID = ctx.id
        p.startDate = ctx.startDate
        p.sampleCount = ctx.sampleCount
        if let s = ctx.recordingStartTimestamp, let e = ctx.lastTimestamp {
            let paused = ctx.pauses.reduce(0) { $0 + ($1.endTimestamp - $1.startTimestamp) }
            p.recordedSeconds = max(0, e - s - paused)
        }
        p.bytesWritten = (ctx.csvWriter?.bytesWritten ?? 0) + (ctx.jsonWriter?.bytesWritten ?? 0) + (ctx.geometryWriter?.bytesWritten ?? 0)
        p.framesSkippedByRate = ctx.skippedByRate
        p.geometryRecords = ctx.geometryRecords
        p.folderURL = ctx.folder
        DispatchQueue.main.async { self.onProgress?(p) }
    }
}
