import Foundation

// MARK: - Common

public struct DateRange: Codable, Hashable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public func contains(_ d: Date) -> Bool { d >= start && d <= end }
    public func overlaps(_ other: DateRange) -> Bool { start <= other.end && other.start <= end }
}

/// Where a measurement came from. Kept on every record so nothing is mistaken for a device reading.
public enum SampleOrigin: String, Codable {
    case healthKit = "healthkit"
    case appleHealthXML = "apple_health_xml"
    case arKitCSV = "arkit_csv"
    case arKitSessionJSON = "arkit_session_json"
    case arKitGeometry = "arkit_geometry"
    case derived = "derived"
}

// MARK: - Statistics (filled by LocalStatistics; Gemini only reads these)

public struct DescriptiveStatistics: Codable, Hashable {
    public var count: Int
    public var mean: Double?
    public var median: Double?
    public var standardDeviation: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var percentile5: Double?
    public var percentile25: Double?
    public var percentile75: Double?
    public var percentile95: Double?
    public var interquartileRange: Double?
    public var medianAbsoluteDeviation: Double?
    public var sum: Double?
    public init(count: Int = 0) { self.count = count }
}

public struct DailyAggregate: Codable, Hashable, Identifiable {
    public var id: String { day }
    /// Calendar day as yyyy-MM-dd in the configured time zone.
    public var day: String
    public var count: Int
    public var sum: Double?
    public var mean: Double?
    public var median: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var standardDeviation: Double?
}

public struct WeeklyAggregate: Codable, Hashable, Identifiable {
    public var id: String { weekStart }
    public var weekStart: String
    public var days: Int
    public var mean: Double?
    public var median: Double?
    public var standardDeviation: Double?
    public var sum: Double?
}

public struct SamplingFrequencyReport: Codable, Hashable {
    public var sampleCount: Int
    public var spanSeconds: Double
    public var medianIntervalSeconds: Double?
    public var meanIntervalSeconds: Double?
    public var samplesPerDay: Double?
    public var largestGapSeconds: Double?
    public var largestGapStart: Date?
    public var isContinuous: Bool
    public var note: String
}

public struct CoverageReport: Codable, Hashable {
    public var rangeStart: Date
    public var rangeEnd: Date
    public var daysInRange: Int
    public var daysWithData: Int
    public var coverageFraction: Double
    public var missingDays: [String]
}

public struct OutlierReport: Codable, Hashable {
    public var method: String
    public var threshold: Double
    public var outlierCount: Int
    public var outlierDays: [String]
}

public struct LongitudinalChange: Codable, Hashable {
    public var metric: String
    public var unit: String?
    public var firstPeriod: String
    public var firstPeriodMedian: Double?
    public var lastPeriod: String
    public var lastPeriodMedian: Double?
    public var absoluteChange: Double?
    public var relativeChange: Double?
    public var slopePerDay: Double?
    public var daysCovered: Int
}

public struct CorrelationResult: Codable, Hashable, Identifiable {
    public var id: String { "\(metricA)|\(metricB)|\(lagDays)" }
    public var metricA: String
    public var metricB: String
    public var lagDays: Int
    public var pairedPoints: Int
    public var pearsonR: Double?
    public var spearmanRho: Double?
    public var note: String
}

// MARK: - HealthKit

public struct HealthSample: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable { case quantity, category, workout, correlation }

    public var id: String
    public var kind: Kind
    /// Raw HealthKit identifier, e.g. HKQuantityTypeIdentifierHeartRate.
    public var typeIdentifier: String
    public var displayName: String
    public var startDate: Date
    public var endDate: Date
    /// Quantity value in `unit`; workout duration in seconds for workouts; nil for categories.
    public var value: Double?
    public var unit: String?
    public var categoryValue: Int?
    public var categoryLabel: String?
    public var sourceName: String?
    public var sourceBundleIdentifier: String?
    public var sourceVersion: String?
    public var deviceName: String?
    public var deviceModel: String?
    public var metadata: [String: JSONValue]
    public var origin: SampleOrigin
    public var workoutActivityType: String?
    public var workoutTotalEnergyKcal: Double?
    public var workoutTotalDistanceM: Double?

    public init(id: String, kind: Kind, typeIdentifier: String, displayName: String, startDate: Date, endDate: Date,
                value: Double? = nil, unit: String? = nil, categoryValue: Int? = nil, categoryLabel: String? = nil,
                sourceName: String? = nil, sourceBundleIdentifier: String? = nil, sourceVersion: String? = nil,
                deviceName: String? = nil, deviceModel: String? = nil, metadata: [String: JSONValue] = [:],
                origin: SampleOrigin, workoutActivityType: String? = nil, workoutTotalEnergyKcal: Double? = nil,
                workoutTotalDistanceM: Double? = nil) {
        self.id = id; self.kind = kind; self.typeIdentifier = typeIdentifier; self.displayName = displayName
        self.startDate = startDate; self.endDate = endDate; self.value = value; self.unit = unit
        self.categoryValue = categoryValue; self.categoryLabel = categoryLabel; self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier; self.sourceVersion = sourceVersion
        self.deviceName = deviceName; self.deviceModel = deviceModel; self.metadata = metadata; self.origin = origin
        self.workoutActivityType = workoutActivityType; self.workoutTotalEnergyKcal = workoutTotalEnergyKcal
        self.workoutTotalDistanceM = workoutTotalDistanceM
    }

    public var durationSeconds: Double { endDate.timeIntervalSince(startDate) }
}

/// How daily values of a metric are formed from its samples.
public enum AggregationMethod: String, Codable {
    /// Steps, energy, distance: add up the day's samples.
    case sum
    /// Heart rate, HRV, weight: average the day's samples.
    case mean
    /// Sleep: total duration of the day's category intervals, in hours.
    case durationHours
    /// Latest sample of the day wins (e.g. height).
    case latest
    /// Count of events (e.g. mindful sessions, stand hours).
    case count
}

public struct HealthMetricSummary: Codable, Identifiable, Hashable {
    public var id: String { typeIdentifier }
    public var typeIdentifier: String
    public var displayName: String
    public var category: String
    public var unit: String?
    public var aggregation: AggregationMethod
    public var sampleCount: Int
    public var firstDate: Date?
    public var lastDate: Date?
    public var sources: [String]
    public var statistics: DescriptiveStatistics?
    public var dailyStatistics: DescriptiveStatistics?
    public var daily: [DailyAggregate]
    public var weekly: [WeeklyAggregate]
    public var samplingFrequency: SamplingFrequencyReport?
    public var coverage: CoverageReport?
    public var outliers: OutlierReport?
    public var longitudinalChange: LongitudinalChange?
    public var categoryBreakdown: [String: Int]?
}

public struct HealthDataSummary: Codable {
    public var generatedAt: Date
    public var range: DateRange
    public var timeZoneIdentifier: String
    public var metrics: [HealthMetricSummary]
    /// Types HealthKit does not offer on this device / iOS version, or that were never authorised.
    public var unavailableTypes: [String]
    /// Types that are available and readable but returned no samples in the range.
    public var emptyTypes: [String]
    public var workoutCount: Int
    public var workoutsByActivity: [String: Int]
    public var totalSamples: Int
    public var notes: [String]
}

// MARK: - ARKit import

public struct ARKitColumnInfo: Codable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var index: Int
    /// From the session manifest when available: unit, origin ("arkit", "derived", "app") and description.
    public var unit: String?
    public var origin: String?
    public var description: String?
    /// True when the importer recognised the column and mapped it to a typed field.
    public var recognised: Bool
    public var numericCount: Int
    public var emptyCount: Int
}

/// One CSV row. Typed fields are copied from the raw row for convenience; `values` keeps every cell
/// (aligned with `ARKitSession.columns`) so nothing is lost, including columns this code does not know.
public struct ARKitFrame: Codable, Identifiable {
    public var id: Int { rowIndex }
    public var rowIndex: Int
    public var frameIndex: Int?
    /// `timestamp_s`: ARFrame.timestamp on the device uptime clock. Not Unix time.
    public var timestampUptime: Double
    public var recordingTime: Double?
    /// `wall_clock_unix_s`, written by the recorder when the frame was processed. Used only to
    /// cross-check the manifest-based alignment.
    public var wallClockUnix: Double?
    public var frameInterval: Double?
    public var droppedFramesEstimate: Int?
    public var faceAnchorPresent: Bool?
    public var faceTracked: Bool?
    public var cameraTrackingState: String?
    public var cameraLimitedReason: String?
    public var activeMarker: String?
    /// 16 row-major elements of the ARFaceAnchor world transform.
    public var headWorldTransform: [Double]?
    public var headWorldPosition: [Double]?
    public var eyeLeftTransform: [Double]?
    public var eyeRightTransform: [Double]?
    public var lookAtPoint: [Double]?
    /// Blend shape coefficients keyed by the ARKit identifier (column name minus "bs_").
    public var blendShapes: [String: Double]
    public var meshVertexCount: Int?
    public var ambientIntensity: Double?
    public var ambientColorTemperature: Double?
    public var exposureDuration: Double?
    public var exposureOffset: Double?
    public var depthDataAvailable: Bool?
    public var depthDataTimestamp: Double?
    /// Every numeric cell by column index; nil where the cell was empty or not a number.
    public var values: [Double?]
    /// Cells that were not numeric (strings such as tracking state), by column index.
    public var textValues: [Int: String]
}

/// Lenient mirror of FaceMetrics' `session.json`. Every field is optional so an older or newer
/// manifest still loads; the untouched document is kept in `raw`.
public struct ARKitSessionManifest: Codable {
    public struct AppInfo: Codable { public var name: String?; public var version: String?; public var build: String? }
    public struct DeviceInfo: Codable { public var model: String?; public var systemName: String?; public var systemVersion: String? }
    public struct TrackingSetup: Codable {
        public var videoFormat: String?
        public var framesPerSecond: Int?
        public var lightEstimationEnabled: Bool?
        public var expectedFrameIntervalSeconds: Double?
    }
    public struct Configuration: Codable {
        public var targetSampleRate: Double?
        public var writeJSONSamples: Bool?
        public var includeFaceGeometry: Bool?
        public var geometryEveryNthSample: Int?
        // participantLabel and notes are free text typed by a researcher: loaded but never transmitted.
        public var participantLabel: String?
        public var notes: String?
    }
    public struct PauseInterval: Codable { public var startTimestamp: Double; public var endTimestamp: Double }
    public struct MarkerRecord: Codable {
        public var id: String?
        public var label: String
        public var kind: String?
        public var startTimestamp: Double
        public var endTimestamp: Double?
        public var recordingStartTime: Double?
        public var recordingEndTime: Double?
        public var startFrameIndex: Int?
        public var endFrameIndex: Int?
        public var wallClock: Date?
        public var note: String?
    }
    public struct BlinkRecord: Codable {
        public var startTimestamp: Double
        public var endTimestamp: Double
        public var recordingStartTime: Double?
        public var durationSeconds: Double
        public var peakLeft: Double?
        public var peakRight: Double?
        public var peakAsymmetry: Double?
        public var onsetLagSeconds: Double?
        public var bilateral: Bool?
        public var kind: String?
        public var interBlinkIntervalSeconds: Double?
    }
    public struct LifecycleRecord: Codable { public var date: Date; public var kind: String; public var detail: String? }
    public struct Summary: Codable {
        public var averageFPS: Double?
        public var trackedSampleFraction: Double?
        public var interruptions: Int?
        public var blinkCount: Int?
        public var closureCount: Int?
        public var activationEvents: Int?
        public var lowActivityPeriods: Int?
        public var unknownBlendShapeKeysSeen: Int?
    }
    public struct ColumnDoc: Codable { public var name: String; public var unit: String?; public var origin: String?; public var description: String? }

    public var formatVersion: Int?
    public var id: String?
    public var app: AppInfo?
    public var device: DeviceInfo?
    public var createdAt: Date?
    public var endedAt: Date?
    public var recordingStartTimestamp: Double?
    public var recordingEndTimestamp: Double?
    public var durationSeconds: Double?
    public var configuration: Configuration?
    public var tracking: TrackingSetup?
    public var sampleCount: Int?
    public var trackedSampleCount: Int?
    public var framesSeen: Int?
    public var framesSkippedByRateLimit: Int?
    public var droppedFramesEstimate: Int?
    public var pauses: [PauseInterval]?
    public var blendShapeIdentifiers: [String]?
    public var columns: [ColumnDoc]?
    public var markers: [MarkerRecord]?
    public var blinkEvents: [BlinkRecord]?
    public var lifecycle: [LifecycleRecord]?
    public var summary: Summary?
    public var files: [String]?
    public var notes: [String]?
    /// The complete document as loaded, for anything not modelled above.
    public var raw: JSONValue?
}

/// Geometry export summary. Raw vertices live in `ARKitGeometryData`, which is never sent anywhere.
public struct ARKitGeometrySummary: Codable, Hashable {
    public var recordCount: Int
    public var vertexCount: Int
    public var triangleCount: Int
    public var everyNthSample: Int?
    public var firstTimestampUptime: Double?
    public var lastTimestampUptime: Double?
    public var fileBytes: Int64
    public var layout: String?
}

public struct ARKitGeometryRecord {
    public var timestampUptime: Double
    public var sampleIndex: Int
    /// vertexCount × 3 floats, face-anchor space, metres.
    public var vertices: [Float]
}

public struct ARKitGeometryData {
    public var summary: ARKitGeometrySummary
    public var triangleIndices: [Int]
    public var records: [ARKitGeometryRecord]
}

/// Derived numbers from geometry, for the optional separate experiment. No vertex positions.
public struct GeometryDerivedFeatures: Codable, Hashable {
    public var recordCount: Int
    public var vertexCount: Int
    public var meanInterRecordDisplacementM: Double?
    public var maxInterRecordDisplacementM: Double?
    public var displacementStdM: Double?
    public var meanBoundingBoxExtentM: [Double]?
    public var leftRightSymmetryError: Double?
    public var supportingMeasurements: [String]
}

public enum AlignmentMethod: String, Codable {
    /// `session.json`: createdAt (wall clock) paired with recordingStartTimestamp (uptime).
    case sessionManifest = "session_manifest"
    /// A marker in `session.json` that carries both wallClock and startTimestamp.
    case markerWallClock = "marker_wall_clock"
    /// Median of (`wall_clock_unix_s` − `timestamp_s`) over the CSV rows.
    case csvWallClock = "csv_wall_clock"
    /// No wall-clock anchor found. Frames keep only recording-relative time.
    case unaligned = "unaligned"
}

/// The relationship between the ARKit uptime clock and wall-clock time for one recording.
public struct TimestampAlignment: Codable, Hashable {
    public var sessionID: String
    public var method: AlignmentMethod
    /// wallClockUnix = timestampUptime + offset. nil when unaligned.
    public var uptimeToUnixOffsetSeconds: Double?
    public var recordingStartWallClock: Date?
    public var recordingEndWallClock: Date?
    /// How far the per-row `wall_clock_unix_s` column disagrees with the chosen anchor.
    public var crossCheckResidualMedianSeconds: Double?
    public var crossCheckResidualMaxSeconds: Double?
    public var crossCheckRows: Int
    public var warnings: [String]

    public func wallClock(forUptime t: Double) -> Date? {
        guard let o = uptimeToUnixOffsetSeconds else { return nil }
        return Date(timeIntervalSince1970: t + o)
    }
}

public struct ARKitValidationReport: Codable, Hashable {
    public struct Issue: Codable, Hashable { public var severity: String; public var message: String }
    public var frameCount: Int
    public var trackedFrameCount: Int
    public var recordingDurationSeconds: Double
    public var effectiveFrameRate: Double?
    public var expectedFrameRate: Double?
    public var medianFrameIntervalSeconds: Double?
    public var missingFramesEstimate: Int
    public var gapCount: Int
    public var largestGapSeconds: Double?
    public var pauseCount: Int
    public var pausedSeconds: Double
    public var interruptionCount: Int
    public var faceLostEvents: Int
    public var blendShapeColumns: Int
    public var blendShapeMissingFraction: Double
    public var framesWithAnyMissingBlendShape: Int
    public var cameraStateDistribution: [String: Double]
    public var limitedReasons: [String: Int]
    public var ambientIntensity: DescriptiveStatistics?
    public var colorTemperatureK: DescriptiveStatistics?
    public var exposureDurationS: DescriptiveStatistics?
    public var geometryAvailable: Bool
    public var geometryRecords: Int
    public var unknownColumns: [String]
    public var manifestSampleCountMatches: Bool?
    public var issues: [Issue]
}

public struct ARKitSession: Codable, Identifiable {
    public var id: String
    public var csvFileName: String
    public var sessionJSONFileName: String?
    public var geometryFileName: String?
    public var importedAt: Date
    public var columns: [ARKitColumnInfo]
    public var blendShapeIdentifiers: [String]
    public var frames: [ARKitFrame]
    public var manifest: ARKitSessionManifest?
    public var geometry: ARKitGeometrySummary?
    public var alignment: TimestampAlignment?
    public var validation: ARKitValidationReport?

    public var recordingDurationSeconds: Double {
        guard let f = frames.first, let l = frames.last else { return 0 }
        return l.timestampUptime - f.timestampUptime
    }
}

/// Numbers only; what is sent to Gemini for one recording.
public struct ARKitSessionSummary: Codable, Identifiable {
    public var id: String
    public var recordedStart: Date?
    public var recordedEnd: Date?
    public var alignmentMethod: AlignmentMethod
    public var durationSeconds: Double
    public var frameCount: Int
    public var trackedFraction: Double
    public var effectiveFrameRate: Double?
    public var videoFormat: String?
    public var deviceModel: String?
    public var markers: [String]
    public var validation: ARKitValidationReport?
    public var windowsBySeconds: [String: [FacialFeatureWindow]]
    public var sessionLevelFeatures: FacialFeatureWindow?
    public var blendShapeStatistics: [String: DescriptiveStatistics]
    public var exportedDerivedColumnMeans: [String: Double]
    public var geometryFeatures: GeometryDerivedFeatures?
}

// MARK: - Facial features

public struct FeatureStat: Codable, Hashable {
    public var n: Int
    public var mean: Double?
    public var standardDeviation: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var median: Double?
}

public struct BlinkFeatures: Codable, Hashable {
    public var count: Int
    public var ratePerMinute: Double?
    public var meanDurationSeconds: Double?
    public var durationStdSeconds: Double?
    public var meanInterBlinkIntervalSeconds: Double?
    public var leftOnlyCount: Int
    public var rightOnlyCount: Int
    public var method: String
}

public struct HeadMovementFeatures: Codable, Hashable {
    /// Range (max − min) of pitch, yaw, roll in radians inside the window.
    public var amplitudeRad: [String: Double]
    public var meanAmplitudeRad: Double?
    /// Zero-crossing rate of the mean-removed yaw+pitch signal, Hz.
    public var frequencyHz: Double?
    /// Mean standard deviation of pitch, yaw, roll.
    public var poseVariabilityRad: Double?
    public var meanAngularSpeedRadPerS: Double?
    public var positionRangeM: [String: Double]
    public var meanDistanceToOriginM: Double?
}

public struct FacialMovementFeatures: Codable, Hashable {
    /// Mean over coefficients of (window max − window min).
    public var amplitude: Double?
    /// Mean over coefficients of the window standard deviation.
    public var variability: Double?
    /// Mean |Δcoefficient| per second over all coefficients.
    public var activityPerSecond: Double?
    public var meanActivation: Double?
    public var activeCoefficientFraction: Double?
    public var mostActiveCoefficients: [String]
}

public struct AsymmetryFeatures: Codable, Hashable {
    public var pairCount: Int
    public var overallMeanAbsoluteDifference: Double?
    public var byGroup: [String: Double]
    public var byPairSigned: [String: Double]
}

public struct GazeFeatures: Codable, Hashable {
    public var directionChangeCount: Int
    public var changeThresholdDegrees: Double
    public var meanAngularSpeedDegPerS: Double?
    public var yawStdDeg: Double?
    public var pitchStdDeg: Double?
    public var meanLookAtDistanceM: Double?
}

public struct TrackingQualityFeatures: Codable, Hashable {
    public var trackedFraction: Double
    public var cameraStateDistribution: [String: Double]
    public var meanFrameIntervalSeconds: Double?
    public var droppedFramesEstimate: Int
    public var meanAmbientIntensity: Double?
    public var meanColorTemperatureK: Double?
    public var meanExposureDurationS: Double?
}

public struct FacialFeatureWindow: Codable, Identifiable, Hashable {
    public var id: String
    public var sessionID: String
    public var windowSeconds: Double
    public var startUptime: Double
    public var endUptime: Double
    public var startWallClock: Date?
    public var endWallClock: Date?
    public var frameCount: Int
    public var trackedFrameCount: Int
    public var missingBlendShapeFraction: Double
    public var markers: [String]
    public var blink: BlinkFeatures?
    public var eyeOpenness: FeatureStat?
    public var headMovement: HeadMovementFeatures?
    public var facialMovement: FacialMovementFeatures?
    public var blendShapeDynamics: [String: FeatureStat]
    public var asymmetry: AsymmetryFeatures?
    public var gaze: GazeFeatures?
    public var trackingQuality: TrackingQualityFeatures
    /// Column names whose values produced the numbers above.
    public var supportingMeasurements: [String]
    /// Means of the recorder's own derived columns in this window (blink_rate_per_min, quality_score...).
    /// Kept apart from this module's calculations.
    public var exportedDerivedMeans: [String: Double]
}

// MARK: - Baseline

public struct ReferenceRange: Codable, Hashable, Identifiable {
    public var id: String { metric }
    public var metric: String
    public var unit: String?
    public var sampleCount: Int
    public var daysCovered: Int
    public var median: Double?
    public var medianAbsoluteDeviation: Double?
    public var percentile5: Double?
    public var percentile25: Double?
    public var percentile75: Double?
    public var percentile95: Double?
    public var mean: Double?
    public var standardDeviation: Double?
    /// median ± 2.5 × (1.4826 × MAD). Describes the person's own usual spread, nothing else.
    public var lowerUsual: Double?
    public var upperUsual: Double?
    public var coverageFraction: Double?
    public var firstDate: Date?
    public var lastDate: Date?
}

public struct BaselineProfile: Codable {
    public var generatedAt: Date
    public var range: DateRange
    public var healthReferences: [ReferenceRange]
    public var facialReferences: [ReferenceRange]
    public var longitudinalChanges: [LongitudinalChange]
    public var caveat: String
}

// MARK: - Combined dataset

public struct BinAggregate: Codable, Hashable {
    public var n: Int
    public var mean: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var sum: Double?
    public var sources: [String]
}

public struct AlignedBin: Codable, Identifiable, Hashable {
    public var id: String { ISO8601.string(from: start) }
    public var start: Date
    public var end: Date
    public var health: [String: BinAggregate]
    public var facial: [String: BinAggregate]
    public var arKitSessionIDs: [String]
}

/// One calendar day with the daily health values and the facial features of that day's recordings.
public struct CombinedDailyRow: Codable, Identifiable, Hashable {
    public var id: String { day }
    public var day: String
    public var health: [String: Double]
    /// Health values from the night before / previous day, for "sleep → next-day face" questions.
    public var previousDayHealth: [String: Double]
    public var facial: [String: Double]
    public var arKitSessionIDs: [String]
    public var facialWindowCount: Int
}

public struct CombinedDataset: Codable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var range: DateRange
    public var timeZoneIdentifier: String
    public var aggregationWindowSeconds: Double
    public var bins: [AlignedBin]
    public var dailyRows: [CombinedDailyRow]
    public var healthSummary: HealthDataSummary
    public var arKitSummaries: [ARKitSessionSummary]
    public var alignments: [TimestampAlignment]
    public var correlations: [CorrelationResult]
    public var baseline: BaselineProfile?
    public var notes: [String]
}

// MARK: - Gemini

public enum AnalysisExperiment: String, Codable, CaseIterable, Identifiable {
    case connectionTest = "connection_test"
    case healthKitOnly = "healthkit"
    case arKitOnly = "arkit"
    case combined = "combined"
    case baseline = "baseline"
    case geometryFeatures = "geometry_features"
    case comparison = "comparison"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .connectionTest: return "Connection test"
        case .healthKitOnly: return "A. HealthKit only"
        case .arKitOnly: return "B. ARKit only"
        case .combined: return "C. Combined HealthKit + ARKit"
        case .baseline: return "Personal baseline"
        case .geometryFeatures: return "Geometry-derived features (optional)"
        case .comparison: return "Compare two analyses"
        }
    }
}

public struct GeminiAnalysisRequest: Codable, Identifiable {
    public var id: String
    public var experiment: AnalysisExperiment
    public var model: String
    public var createdAt: Date
    public var systemInstruction: String
    public var userPrompt: String
    /// The numeric payload the model reads. Only summaries and statistics, never raw frames or video.
    public var payload: JSONValue
    public var responseSchema: JSONValue
    public var thinkingLevel: String?
    public var inputDataRange: DateRange?
    public var dataCategories: [String]
    public var payloadBytes: Int
}

public struct GeminiUsage: Codable, Hashable {
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var thoughtTokens: Int?
    public var totalTokens: Int?
}

public struct GeminiAnalysisResponse: Codable, Identifiable {
    public enum Status: String, Codable {
        case success, apiError = "api_error", networkError = "network_error", invalidJSON = "invalid_json",
             schemaRejected = "schema_rejected", proxyError = "proxy_error", cancelled
    }
    public var id: String
    public var requestID: String
    public var experiment: AnalysisExperiment
    public var model: String
    public var requestTimestamp: Date
    public var responseTimestamp: Date
    public var latencyMilliseconds: Double
    public var status: Status
    public var httpStatus: Int?
    public var errorMessage: String?
    public var usage: GeminiUsage?
    public var rawText: String?
    public var rawProxyResponse: JSONValue?
    public var analysis: StructuredAnalysis?
    public var validation: ResponseValidationReport?
}

/// Section 9 response format. Every observation names its evidence.
public struct AnalysisObservation: Codable, Hashable, Identifiable {
    public var id: String { observation }
    public var observation: String
    public var supportingMeasurements: [String]
    public var timeRange: ObservationTimeRange?
    /// "direct_observation" or "hypothesis".
    public var kind: String
    public var dataQuality: String
    public var limitations: String

    enum CodingKeys: String, CodingKey {
        case observation
        case supportingMeasurements = "supporting_measurements"
        case timeRange = "time_range"
        case kind
        case dataQuality = "data_quality"
        case limitations
    }
}

public struct ObservationTimeRange: Codable, Hashable {
    public var start: String?
    public var end: String?
}

public struct StructuredAnalysis: Codable {
    public var experimentType: String
    public var baselineSummary: JSONValue
    public var healthObservations: [AnalysisObservation]
    public var facialBehaviorObservations: [AnalysisObservation]
    public var crossModalPatterns: [AnalysisObservation]
    public var longitudinalChanges: [AnalysisObservation]
    public var potentialConfounders: [AnalysisObservation]
    public var dataQuality: JSONValue
    public var uncertainties: [String]
    public var recommendedTracking: [String]
    public var plainLanguageExplanation: String

    enum CodingKeys: String, CodingKey {
        case experimentType = "experiment_type"
        case baselineSummary = "baseline_summary"
        case healthObservations = "health_observations"
        case facialBehaviorObservations = "facial_behavior_observations"
        case crossModalPatterns = "cross_modal_patterns"
        case longitudinalChanges = "longitudinal_changes"
        case potentialConfounders = "potential_confounders"
        case dataQuality = "data_quality"
        case uncertainties
        case recommendedTracking = "recommended_tracking"
        case plainLanguageExplanation = "plain_language_explanation"
    }

    public var allObservations: [AnalysisObservation] {
        healthObservations + facialBehaviorObservations + crossModalPatterns + longitudinalChanges + potentialConfounders
    }
}

public struct ResponseValidationReport: Codable, Hashable {
    public struct Problem: Codable, Hashable {
        public var severity: String   // "error" or "warning"
        public var location: String
        public var message: String
    }
    public var isValid: Bool
    public var schemaErrors: [Problem]
    /// Numbers in the response that do not appear in the request payload.
    public var unsupportedNumbers: [Problem]
    public var forbiddenTerms: [Problem]
    public var observationCount: Int
    public var checkedNumbers: Int
}

/// Result of comparing two structured analyses (e.g. same data on two days, or two models).
public struct AnalysisComparison: Codable {
    public var firstResponseID: String
    public var secondResponseID: String
    public var sharedObservations: [String]
    public var onlyInFirst: [String]
    public var onlySecond: [String]
    public var kindChanges: [String]
    public var similarityScore: Double
}
