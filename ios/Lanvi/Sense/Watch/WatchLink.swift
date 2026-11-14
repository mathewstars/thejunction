import Foundation
import Observation
import WatchConnectivity

/// The iPhone's end of the Apple Watch link (`ios/WATCH.md`).
///
/// One WCSession for the app. It tells the watch which game is waiting, hears the watch
/// say it started recording, takes its heart-rate and HRV samples as they come, and hands
/// everything to the `SensorSession` that is open. Samples are never changed: HealthKit's
/// own start and end times and its uuid travel with each one, and the uuid drops a sample
/// that arrives twice (the watch sends live when it can and queues the rest for later).
///
/// Without a paired watch, or without the watch app, nothing here does anything and the
/// games run as before.
@Observable @MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    enum Status: Equatable {
        case unsupported            // iPad, simulator without a paired watch
        case noWatch                // no Apple Watch paired
        case noApp                  // paired, Lanvi not installed on the watch
        case ready                  // installed; the watch app may or may not be open
    }

    private(set) var status: Status = .unsupported
    /// The watch app is open and awake right now.
    private(set) var reachable = false
    /// The session id the watch said it is recording for, if any.
    private(set) var recordingSession: String?
    private(set) var watchDevice: String?
    /// Samples received for the open session (for the small live display and tests).
    private(set) var receivedSamples = 0
    private(set) var lastHeartRate: Double?
    private(set) var lastHRV: (value: Double, at: Date)?

    private var session: WCSession?
    private var context: WatchSessionContext?
    private var seen: Set<String> = []
    private var onSamples: (@MainActor ([WatchSample]) -> Void)?
    private var onStarted: (@MainActor (String, Date) -> Void)?
    private var onStopped: (@MainActor (String) -> Void)?

    private override init() {
        super.init()
    }

    /// Call once at launch, so queued deliveries from the watch arrive even when no
    /// game is open. Safe to call again.
    func activate() {
        guard WCSession.isSupported() else { status = .unsupported; return }
        guard session == nil else { return }
        let s = WCSession.default
        s.delegate = self
        session = s
        s.activate()
    }

    /// True when it is worth asking the person to open the watch app.
    var canTrack: Bool { status == .ready }

    // MARK: Driving a session

    /// A game is about to start: tell the watch, and route what comes back.
    func beginSession(id: String, activity: String,
                      onStarted: @escaping @MainActor (String, Date) -> Void,
                      onSamples: @escaping @MainActor ([WatchSample]) -> Void,
                      onStopped: @escaping @MainActor (String) -> Void) {
        self.onStarted = onStarted
        self.onSamples = onSamples
        self.onStopped = onStopped
        seen.removeAll()
        receivedSamples = 0
        lastHeartRate = nil
        lastHRV = nil
        if recordingSession != id { recordingSession = nil }
        push(WatchSessionContext(sessionId: id, activity: activity, state: .waiting))
    }

    /// The game is running (the watch shows it).
    func playing(id: String) {
        guard let c = context, c.sessionId == id else { return }
        push(WatchSessionContext(sessionId: id, activity: c.activity, state: .playing))
    }

    /// The game is over: the watch stops and flushes. Callbacks stay until `closeSession`
    /// so the last samples still land.
    func endSession(id: String) {
        guard let c = context, c.sessionId == id else { return }
        push(WatchSessionContext(sessionId: id, activity: c.activity, state: .ended))
    }

    /// Nothing more is wanted for this session.
    func closeSession() {
        onStarted = nil
        onSamples = nil
        onStopped = nil
        context = nil
    }

    private func push(_ c: WatchSessionContext) {
        context = c
        guard let s = session, status == .ready else { return }
        // The context survives until the watch app next wakes; the message is for right now.
        try? s.updateApplicationContext(c.wire)
        if s.isReachable {
            s.sendMessage(c.wire, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: What the watch says

    private func handle(_ message: [String: Any]) {
        guard let kind = (message[WatchProtocol.kind] as? String).flatMap(WatchProtocol.Kind.init(rawValue:)) else { return }
        let id = message[WatchProtocol.session] as? String
        switch kind {
        case .hello:
            if message[WatchProtocol.recording] as? Bool == true { recordingSession = id } else if recordingSession == id { recordingSession = nil }
        case .started:
            guard let id else { return }
            recordingSession = id
            watchDevice = message[WatchProtocol.device] as? String
            let at = Date(timeIntervalSince1970: message[WatchProtocol.at] as? Double ?? Date().timeIntervalSince1970)
            onStarted?(id, at)
        case .samples:
            guard let id, id == context?.sessionId else { return }
            take(WatchSample.decode(message[WatchProtocol.samples]))
        case .stopped:
            guard let id else { return }
            if id == context?.sessionId { take(WatchSample.decode(message[WatchProtocol.samples])) }
            if recordingSession == id { recordingSession = nil }
            onStopped?(id)
        case .session:
            break
        }
    }

    private func take(_ samples: [WatchSample]) {
        let fresh = samples.filter { seen.insert($0.uuid).inserted }
        guard !fresh.isEmpty else { return }
        receivedSamples += fresh.count
        for s in fresh.sorted(by: { $0.start < $1.start }) {
            switch s.type {
            case .heartRate: lastHeartRate = s.value
            case .hrvSDNN: lastHRV = (s.value, Date(timeIntervalSince1970: s.start))
            }
        }
        onSamples?(fresh)
    }

    private func refreshStatus() {
        guard let s = session else { return }
        status = !s.isPaired ? .noWatch : !s.isWatchAppInstalled ? .noApp : .ready
        reachable = s.isReachable
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.refreshStatus()
            // A context pushed before activation finished: send it now.
            if let c = self.context { self.push(c) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshStatus() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if session.isReachable, let c = self.context {
                session.sendMessage(c.wire, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.handle(message) }
        replyHandler(["ok": true])
    }

    /// Queued deliveries: samples the watch could not send live, and its last flush.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.handle(userInfo) }
    }
}
