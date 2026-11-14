import Foundation
import HealthKit
import Observation

/// The HealthKit types and units, outside the actor so the query callbacks can use them.
private enum HK {
    static let heartRate = HKQuantityType(.heartRate)
    static let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let ms = HKUnit.secondUnit(with: .milli)
}

/// Records the heart during one game: an `HKWorkoutSession` with an `HKLiveWorkoutBuilder`
/// (so the watch samples the heart at workout rate and keeps running with the wrist
/// down), and two anchored queries that hand over every real HealthKit sample, heart
/// rate and HRV (SDNN), with HealthKit's own start and end times and uuid.
///
/// Nothing is invented. HRV is written by watchOS only now and then (often not at all
/// during one short game): the screen shows the latest sample and when it was taken,
/// or "none yet".
@Observable @MainActor
final class WorkoutRecorder: NSObject {
    enum State: Equatable {
        case idle, starting, recording, stopping
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The game session this recording belongs to (the iPhone's activity id).
    private(set) var sessionId: String?
    private(set) var startedAt: Date?
    private(set) var heartRate: Double?
    private(set) var heartRateAt: Date?
    private(set) var hrv: Double?
    private(set) var hrvAt: Date?
    private(set) var sampleCount = 0
    /// New samples, as they come. Set by the app; the phone link queues them.
    var onSamples: (@MainActor ([WatchSample]) -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var queries: [HKAnchoredObjectQuery] = []

    var isRecording: Bool { state == .recording || state == .starting }

    // MARK: Start and stop

    func start(sessionId id: String) async {
        guard state == .idle || isFailed else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed("Health data is not available here.")
            return
        }
        state = .starting
        sessionId = id
        heartRate = nil; heartRateAt = nil; hrv = nil; hrvAt = nil; sampleCount = 0
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                 read: [HK.heartRate, HK.hrv])
            let config = HKWorkoutConfiguration()
            config.activityType = .mindAndBody
            config.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            let start = Date()
            s.startActivity(with: start)
            try await b.beginCollection(at: start)
            startedAt = start
            state = .recording
            watch(HK.heartRate, from: start)
            watch(HK.hrv, from: start)
        } catch {
            state = .failed(error.localizedDescription)
            session = nil
            builder = nil
        }
    }

    func stop() async {
        guard let s = session, let b = builder, isRecording else { return }
        state = .stopping
        let end = Date()
        s.end()
        for q in queries { store.stop(q) }
        queries.removeAll()
        do {
            try await b.endCollection(at: end)
            // The workout is kept in Health as "Mind and Body": real data, nothing to hide.
            _ = try await b.finishWorkout()
        } catch {
            // A workout that could not be saved still gave its samples; nothing is lost.
        }
        session = nil
        builder = nil
        state = .idle
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: Samples

    /// Every sample of `type` written from `start` on, as HealthKit stores it.
    private func watch(_ type: HKQuantityType, from start: Date) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil,
                                          limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            self?.took(samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.took(samples)
        }
        store.execute(query)
        queries.append(query)
    }

    nonisolated private func took(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
        let converted: [WatchSample] = samples.compactMap { s in
            if s.quantityType == HK.heartRate {
                return WatchSample(type: .heartRate, value: s.quantity.doubleValue(for: HK.bpm),
                                   start: s.startDate.timeIntervalSince1970, end: s.endDate.timeIntervalSince1970,
                                   uuid: s.uuid.uuidString)
            }
            if s.quantityType == HK.hrv {
                return WatchSample(type: .hrvSDNN, value: s.quantity.doubleValue(for: HK.ms),
                                   start: s.startDate.timeIntervalSince1970, end: s.endDate.timeIntervalSince1970,
                                   uuid: s.uuid.uuidString)
            }
            return nil
        }
        guard !converted.isEmpty else { return }
        Task { @MainActor in self.show(converted) }
    }

    private func show(_ samples: [WatchSample]) {
        sampleCount += samples.count
        for s in samples.sorted(by: { $0.start < $1.start }) {
            switch s.type {
            case .heartRate:
                heartRate = s.value
                heartRateAt = Date(timeIntervalSince1970: s.start)
            case .hrvSDNN:
                hrv = s.value
                hrvAt = Date(timeIntervalSince1970: s.start)
            }
        }
        onSamples?(samples)
    }
}

extension WorkoutRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
        }
    }
}

extension WorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    /// The builder's running statistics are not used: the anchored queries hand over the
    /// real samples with their own times. This keeps the builder collecting.
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
