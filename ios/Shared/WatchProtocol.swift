import Foundation

// The words the iPhone and the Apple Watch say to each other over WatchConnectivity.
// This file is compiled into both targets (Lanvi and LanviWatch), so the two sides can
// never drift apart. Plain dictionaries of plist types only: that is all WCSession carries.
//
// iPhone -> Watch (applicationContext, and sendMessage when reachable):
//   {"kind": "session", "session": id, "activity": "focus", "state": "waiting"|"playing"|"ended",
//    "sentAt": epoch seconds}
//   "waiting": a game is about to start and the phone waits for the watch to record.
//   "playing": the game is running (sent once the watch said "started").
//   "ended":   the game is over; the watch stops and flushes.
//
// Watch -> iPhone (sendMessage when reachable, else transferUserInfo, which queues and
// delivers later; every sample carries HealthKit's own uuid so the phone drops duplicates):
//   {"kind": "started", "session": id, "at": epoch seconds, "device": "Apple Watch"}
//   {"kind": "samples", "session": id, "samples": [[type, value, start, end, uuid], ...]}
//   {"kind": "stopped", "session": id, "at": epoch seconds, "samples": [...]}  (the last flush)
//   {"kind": "hello", "session": id?, "recording": Bool}  (the watch app came to the front)
//
// Times are wall-clock epoch seconds as HealthKit gives them (HKSample.startDate/endDate),
// never changed on the way. The phone keeps them as they are.

enum WatchProtocol {
    static let kind = "kind"
    static let session = "session"
    static let activity = "activity"
    static let state = "state"
    static let sentAt = "sentAt"
    static let at = "at"
    static let device = "device"
    static let samples = "samples"
    static let recording = "recording"

    enum Kind: String {
        case session, started, samples, stopped, hello
    }

    enum State: String {
        case waiting, playing, ended
    }

    /// A sample type as sent over the wire.
    enum SampleType: String {
        case heartRate = "hr"        // beats per minute
        case hrvSDNN = "hrv"         // milliseconds
    }
}

/// One heart-rate or HRV sample, with HealthKit's own timestamps and id.
struct WatchSample: Equatable, Hashable {
    var type: WatchProtocol.SampleType
    var value: Double
    /// Epoch seconds, as HealthKit gave them.
    var start: Double
    var end: Double
    var uuid: String

    /// `[type, value, start, end, uuid]`: short, and plist-safe.
    var wire: [Any] { [type.rawValue, value, start, end, uuid] }

    init(type: WatchProtocol.SampleType, value: Double, start: Double, end: Double, uuid: String) {
        self.type = type
        self.value = value
        self.start = start
        self.end = end
        self.uuid = uuid
    }

    init?(wire: Any) {
        guard let a = wire as? [Any], a.count == 5,
              let t = (a[0] as? String).flatMap(WatchProtocol.SampleType.init(rawValue:)),
              let v = a[1] as? Double, let s = a[2] as? Double, let e = a[3] as? Double,
              let u = a[4] as? String, v.isFinite, s.isFinite, e.isFinite else { return nil }
        self.init(type: t, value: v, start: s, end: e, uuid: u)
    }

    static func decode(_ list: Any?) -> [WatchSample] {
        (list as? [Any])?.compactMap(WatchSample.init(wire:)) ?? []
    }
}

/// What the phone tells the watch about the game.
struct WatchSessionContext: Equatable {
    var sessionId: String
    var activity: String
    var state: WatchProtocol.State
    var sentAt: Double

    var wire: [String: Any] {
        [WatchProtocol.kind: WatchProtocol.Kind.session.rawValue,
         WatchProtocol.session: sessionId,
         WatchProtocol.activity: activity,
         WatchProtocol.state: state.rawValue,
         WatchProtocol.sentAt: sentAt]
    }

    init(sessionId: String, activity: String, state: WatchProtocol.State, sentAt: Double = Date().timeIntervalSince1970) {
        self.sessionId = sessionId
        self.activity = activity
        self.state = state
        self.sentAt = sentAt
    }

    init?(wire: [String: Any]) {
        guard wire[WatchProtocol.kind] as? String == WatchProtocol.Kind.session.rawValue,
              let id = wire[WatchProtocol.session] as? String,
              let act = wire[WatchProtocol.activity] as? String,
              let st = (wire[WatchProtocol.state] as? String).flatMap(WatchProtocol.State.init(rawValue:))
        else { return nil }
        self.init(sessionId: id, activity: act, state: st,
                  sentAt: wire[WatchProtocol.sentAt] as? Double ?? 0)
    }
}
