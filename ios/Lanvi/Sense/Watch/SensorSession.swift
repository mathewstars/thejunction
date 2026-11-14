import Foundation
import Observation
import QuartzCore

/// One game's sensor session (`ios/WATCH.md`): the unified id, every game moment, the
/// watch's heart-rate and HRV samples, and the one clock anchor that lines all of it up
/// with the ARKit face frames.
///
/// Clocks. Three sources, two clocks:
/// - Game moments (`GameMoments`) carry both: `date` (wall clock) and `uptime`
///   (`CACurrentMediaTime()`, the same clock as `ARFrame.timestamp`).
/// - ARKit face frames (`FaceRawRecorder`) have uptime only.
/// - Watch samples (HealthKit) have wall clock only.
/// The record's `started_at` is the wall-clock anchor. The `started` game moment gives
/// the matching uptime, so `sensors.clock.started_uptime_s` is the monotonic anchor.
/// Every moment is sent as `t_ms` from that anchor on the monotonic clock (exact) and
/// `wall_ms` on the wall clock (so drift is visible); every watch sample as `t_ms`
/// on the wall clock; the first face frame as `face_offset_ms` on the monotonic clock.
///
/// Nothing here changes a game. The session listens to `GameMoments` and to `WatchLink`;
/// it is created by `SensorSessionHost` before the game and read once at the end.
@Observable @MainActor
final class SensorSession {
    let id: String
    let kind: ActivityKind
    /// When the session was opened (Start Game pressed), both clocks.
    let openedAt: Date
    let openedUptime: TimeInterval

    private(set) var moments: [GameMomentEvent] = []
    private(set) var samples: [WatchSample] = []
    /// The watch said it is recording for this session.
    private(set) var watchStarted: Date?
    private(set) var watchStopped = false
    private(set) var watchDevice: String?
    /// Set once `end` or `cancel` ran; the host then leaves the session alone.
    private(set) var closed = false

    private var token: GameMoments.Token?
    private var link: WatchLink { WatchLink.shared }

    init(kind: ActivityKind, id: String = API.ActivityIn.newId()) {
        self.id = id
        self.kind = kind
        openedAt = Date()
        openedUptime = CACurrentMediaTime()
    }

    // MARK: Lifecycle

    /// Start listening to the games, and tell the watch a game is waiting.
    func begin(onWatchStarted: @escaping () -> Void) {
        guard token == nil else { return }
        token = GameMoments.shared.listen { [weak self] event in
            // GameMoments calls on the main thread; its times were taken at the instant.
            MainActor.assumeIsolated {
                guard let self, event.activity.rawValue == self.kind.rawValue else { return }
                self.moments.append(event)
                if self.isStart(event.moment) { self.link.playing(id: self.id) }
            }
        }
        link.beginSession(id: id, activity: kind.rawValue,
                          onStarted: { [weak self] sid, at in
                              guard let self, sid == self.id else { return }
                              self.watchStarted = at
                              self.watchDevice = self.link.watchDevice
                              onWatchStarted()
                          },
                          onSamples: { [weak self] new in self?.samples.append(contentsOf: new) },
                          onStopped: { [weak self] sid in if sid == self?.id { self?.watchStopped = true } })
    }

    /// The game is over: tell the watch, wait a moment for its last flush, stop listening.
    /// At most `flushWait` seconds; the watch's queued deliveries still land later and are
    /// kept with the record only if they arrive in time (the record is sent once).
    func end(flushWait: Double = 2.5) async {
        if watchStarted != nil, !watchStopped {
            link.endSession(id: id)
            let deadline = Date().addingTimeInterval(flushWait)
            while !watchStopped, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        token?.cancel()
        token = nil
        link.closeSession()
        closed = true
    }

    /// The game went away with nothing to send.
    func cancel() {
        guard !closed else { return }
        token?.cancel()
        token = nil
        if watchStarted != nil { link.endSession(id: id) }
        link.closeSession()
        closed = true
    }

    private func isStart(_ m: GameMoment) -> Bool {
        switch m {
        case .focusStarted, .breatheStarted, .checkinStarted: true
        default: false
        }
    }

    // MARK: The record

    /// Puts the session into the record under `sensors`. The record's `id` becomes the
    /// session id, so the server, the face frames and the watch data share one id.
    /// `faceAnchorUptime` is the ARKit time of the first kept face frame, if any.
    func attach(to record: API.ActivityIn, faceAnchorUptime: Double?) -> API.ActivityIn {
        var r = record
        r.id = id
        guard let startedAt = API.date(from: r.startedAt) else { return r }
        r.sensors = Self.sensors(startedAt: startedAt, moments: moments, samples: samples,
                                 watchStarted: watchStarted, watchDevice: watchDevice,
                                 faceAnchorUptime: faceAnchorUptime,
                                 fallbackUptime: openedUptime + startedAt.timeIntervalSince(openedAt))
        return r
    }

    /// Pure: the `sensors` object for a record (tested without a watch or a game).
    nonisolated static func sensors(startedAt: Date, moments: [GameMomentEvent], samples: [WatchSample],
                                    watchStarted: Date?, watchDevice: String?, faceAnchorUptime: Double?,
                                    fallbackUptime: Double) -> API.Sensors? {
        let start = moments.first { event in
            switch event.moment {
            case .focusStarted, .breatheStarted, .checkinStarted: true
            default: false
            }
        }
        // The monotonic time of started_at: from the start moment when there is one
        // (it fired at the same instant), else from when the session was opened.
        let startedUptime = start.map { $0.uptime + startedAt.timeIntervalSince($0.date) } ?? fallbackUptime
        guard !moments.isEmpty || !samples.isEmpty else { return nil }

        func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

        let momentRows: [API.SensorMoment] = moments.prefix(400).map { e in
            var value: Int?
            var step: String?
            switch e.moment {
            case .sparkCaught(let reaction): value = reaction
            case .breathIn(let n), .breathHold(let n), .breathOut(let n): value = n
            case .focusEnded(let f), .breatheEnded(let f), .checkinEnded(let f): value = f ? 1 : 0
            case .checkinStep(let s): step = s.rawValue
            default: break
            }
            return API.SensorMoment(name: e.moment.name, tMs: ms(e.uptime - startedUptime),
                                    wallMs: ms(e.date.timeIntervalSince(startedAt)), value: value, step: step)
        }
        let hr = samples.filter { $0.type == .heartRate }.sorted { $0.start < $1.start }.prefix(2000)
            .map { [Double(ms($0.start - startedAt.timeIntervalSince1970)), ($0.value * 10).rounded() / 10] }
        let hrv = samples.filter { $0.type == .hrvSDNN }.sorted { $0.start < $1.start }.prefix(100)
            .map { [Double(ms($0.start - startedAt.timeIntervalSince1970)), ($0.value * 10).rounded() / 10] }
        var watch: API.SensorWatch?
        if let watchStarted {
            watch = API.SensorWatch(source: "apple_watch", workout: true,
                                    startedMs: ms(watchStarted.timeIntervalSince(startedAt)))
        }
        return API.Sensors(clock: API.SensorClock(startedUptimeS: (startedUptime * 1000).rounded() / 1000),
                           watch: watch,
                           heartRate: hr.isEmpty ? nil : hr,
                           hrvSdnn: hrv.isEmpty ? nil : hrv,
                           moments: momentRows.isEmpty ? nil : momentRows,
                           faceOffsetMs: faceAnchorUptime.map { ms($0 - startedUptime) })
    }
}
