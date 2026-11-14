import XCTest
@testable import Lanvi

/// The clock maths of `SensorSession.sensors(...)`: game moments on both clocks, watch
/// samples with HealthKit's own times, the face anchor, and the record's id. Pure, no
/// watch and no game needed. See `ios/WATCH.md`.
final class SensorSessionTests: XCTestCase {
    // started_at on the wall clock and the matching monotonic time.
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000.000)
    let startedUptime = 48_213.412

    private func event(_ m: GameMoment, after seconds: Double, drift: Double = 0) -> GameMomentEvent {
        GameMomentEvent(moment: m, activity: m.activity,
                        date: startedAt.addingTimeInterval(seconds + drift),
                        uptime: startedUptime + seconds)
    }

    private func sample(_ type: WatchProtocol.SampleType, _ value: Double, at seconds: Double) -> WatchSample {
        let t = startedAt.timeIntervalSince1970 + seconds
        return WatchSample(type: type, value: value, start: t, end: t, uuid: UUID().uuidString)
    }

    func testMomentsUseTheStartMomentAsTheMonotonicAnchor() throws {
        let moments = [event(.focusStarted, after: 0),
                       event(.sparkCaught(reactionMs: 512), after: 1.84, drift: 0.001),
                       event(.snowTapped, after: 9.02),
                       event(.focusEnded(finished: true), after: 45.2)]
        let s = try XCTUnwrap(SensorSession.sensors(startedAt: startedAt, moments: moments, samples: [],
                                                     watchStarted: nil, watchDevice: nil,
                                                     faceAnchorUptime: nil, fallbackUptime: 0))
        XCTAssertEqual(s.clock.startedUptimeS, 48_213.412, accuracy: 0.0005)
        let rows = try XCTUnwrap(s.moments)
        XCTAssertEqual(rows.map(\.name), ["focus_started", "spark_caught", "snow_tapped", "focus_ended"])
        XCTAssertEqual(rows.map(\.tMs), [0, 1840, 9020, 45200])
        XCTAssertEqual(rows[1].wallMs, 1841)          // the wall clock drifted by 1 ms, visible
        XCTAssertEqual(rows[1].value, 512)
        XCTAssertEqual(rows[3].value, 1)
        XCTAssertNil(s.watch)
        XCTAssertNil(s.heartRate)
        XCTAssertNil(s.faceOffsetMs)
    }

    func testWatchSamplesKeepHealthKitsOwnTimes() throws {
        let samples = [sample(.heartRate, 71.04, at: -8.0), sample(.heartRate, 74.0, at: 2.0),
                       sample(.hrvSDNN, 38.46, at: -6.0), sample(.heartRate, 78.0, at: 7.0)]
        let s = try XCTUnwrap(SensorSession.sensors(startedAt: startedAt, moments: [event(.breatheStarted, after: 0)],
                                                     samples: samples,
                                                     watchStarted: startedAt.addingTimeInterval(-8.2),
                                                     watchDevice: "Apple Watch", faceAnchorUptime: nil,
                                                     fallbackUptime: 0))
        XCTAssertEqual(s.heartRate, [[-8000, 71.0], [2000, 74.0], [7000, 78.0]])   // sorted, 1 decimal
        XCTAssertEqual(s.hrvSdnn, [[-6000, 38.5]])
        XCTAssertEqual(s.watch, API.SensorWatch(source: "apple_watch", workout: true, startedMs: -8200))
    }

    func testTheFaceAnchorBecomesAnOffsetOnTheMonotonicClock() throws {
        let s = try XCTUnwrap(SensorSession.sensors(startedAt: startedAt, moments: [event(.focusStarted, after: 0)],
                                                     samples: [], watchStarted: nil, watchDevice: nil,
                                                     faceAnchorUptime: startedUptime - 0.412, fallbackUptime: 0))
        XCTAssertEqual(s.faceOffsetMs, -412)
        // A moment at 1.84 s lands on frame (1840 + 412) * 30 / 1000 = 67.56 of a 30 Hz recording.
        let frame = Double(1840 - s.faceOffsetMs!) * 30 / 1000
        XCTAssertEqual(frame, 67.56, accuracy: 0.001)
    }

    func testWithoutAStartMomentTheOpeningTimeIsTheAnchor() throws {
        let s = try XCTUnwrap(SensorSession.sensors(startedAt: startedAt, moments: [],
                                                     samples: [sample(.heartRate, 70, at: 1)],
                                                     watchStarted: nil, watchDevice: nil, faceAnchorUptime: nil,
                                                     fallbackUptime: 100.5))
        XCTAssertEqual(s.clock.startedUptimeS, 100.5)
        XCTAssertNil(s.moments)
    }

    func testNothingRecordedMeansNoSensorsBlock() {
        XCTAssertNil(SensorSession.sensors(startedAt: startedAt, moments: [], samples: [], watchStarted: nil,
                                           watchDevice: nil, faceAnchorUptime: nil, fallbackUptime: 0))
    }

    @MainActor
    func testAttachStampsTheRecordWithTheSessionId() {
        let session = SensorSession(kind: .focus, id: "session-0001-abcd")
        let record = API.ActivityIn(id: "other", type: .focus, startedAt: API.isoString(startedAt), durationS: 45,
                                    completed: true, endedBy: .finished, correctTaps: 1, wrongTaps: 0, misses: 0,
                                    reactionMs: [500])
        let out = session.attach(to: record, faceAnchorUptime: nil)
        XCTAssertEqual(out.id, "session-0001-abcd")
        XCTAssertNil(out.sensors)   // nothing was heard
    }

    func testTheWireFormatRoundTrips() throws {
        let s = WatchSample(type: .hrvSDNN, value: 41.5, start: 1.5, end: 1.5, uuid: "u1")
        XCTAssertEqual(WatchSample(wire: s.wire), s)
        XCTAssertNil(WatchSample(wire: ["hr", 70.0]))
        let c = WatchSessionContext(sessionId: "abc", activity: "focus", state: .waiting, sentAt: 5)
        XCTAssertEqual(WatchSessionContext(wire: c.wire), c)
        // The JSON keys the server wants.
        let data = try API.encoder.encode(API.Sensors(clock: .init(startedUptimeS: 1), watch: nil,
                                                      heartRate: [[0, 70]], hrvSdnn: nil,
                                                      moments: [.init(name: "focus_started", tMs: 0, wallMs: 0,
                                                                      value: nil, step: nil)],
                                                      faceOffsetMs: nil))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"started_uptime_s\"") && text.contains("\"heart_rate\"")
                      && text.contains("\"t_ms\"") && text.contains("\"wall_ms\""))
        XCTAssertFalse(text.contains("hrv_sdnn") || text.contains("face_offset_ms"))
    }
}
