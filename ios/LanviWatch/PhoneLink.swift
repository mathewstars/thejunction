import Foundation
import Observation
import WatchConnectivity

/// The watch's end of the link to the iPhone (`WatchProtocol.swift`).
///
/// Hears which game is waiting on the phone. Sends "started" when recording begins,
/// the samples in small batches while the phone is reachable, and a final "stopped"
/// with whatever is left. A batch the phone did not confirm stays in the queue and goes
/// again; the final flush also goes through `transferUserInfo`, which the system
/// delivers later if the phone is away. The phone drops duplicates by each sample's uuid.
@Observable @MainActor
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var reachable = false
    private(set) var activated = false
    /// What the phone last said about a game.
    private(set) var context: WatchSessionContext?
    private(set) var pendingCount = 0
    private(set) var sentCount = 0
    /// The phone said the game for this session is over.
    var onSessionEnded: (@MainActor (String) async -> Void)?

    private var session: WCSession?
    private var pending: [WatchSample] = []
    private var inFlight = false
    private var currentSession: String?
    private var ticker: Timer?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported(), session == nil else { return }
        let s = WCSession.default
        s.delegate = self
        session = s
        s.activate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    // MARK: Recording for a session

    func started(sessionId: String, at: Date) {
        currentSession = sessionId
        send([WatchProtocol.kind: WatchProtocol.Kind.started.rawValue,
              WatchProtocol.session: sessionId,
              WatchProtocol.at: at.timeIntervalSince1970,
              WatchProtocol.device: "Apple Watch"], queued: true)
    }

    func queue(_ samples: [WatchSample]) {
        guard currentSession != nil else { return }
        pending.append(contentsOf: samples)
        pendingCount = pending.count
        flush()
    }

    /// The last word for this session: everything still pending goes with it, both ways.
    func stopped(sessionId: String, at: Date) {
        let rest = pending
        pending.removeAll()
        pendingCount = 0
        send([WatchProtocol.kind: WatchProtocol.Kind.stopped.rawValue,
              WatchProtocol.session: sessionId,
              WatchProtocol.at: at.timeIntervalSince1970,
              WatchProtocol.samples: rest.map(\.wire)], queued: true)
        sentCount += rest.count
        currentSession = nil
    }

    private func flush() {
        guard let s = session, s.isReachable, !inFlight, !pending.isEmpty, let sid = currentSession else { return }
        let batch = Array(pending.prefix(60))
        inFlight = true
        s.sendMessage([WatchProtocol.kind: WatchProtocol.Kind.samples.rawValue,
                       WatchProtocol.session: sid,
                       WatchProtocol.samples: batch.map(\.wire)],
                      replyHandler: { [weak self] _ in
                          Task { @MainActor in
                              guard let self else { return }
                              let got = Set(batch.map(\.uuid))
                              self.pending.removeAll { got.contains($0.uuid) }
                              self.pendingCount = self.pending.count
                              self.sentCount += batch.count
                              self.inFlight = false
                          }
                      },
                      errorHandler: { [weak self] _ in
                          Task { @MainActor in self?.inFlight = false }   // stays pending, goes again
                      })
    }

    /// Live when the phone is reachable; `queued` also hands it to the system to deliver later.
    private func send(_ message: [String: Any], queued: Bool) {
        guard let s = session else { return }
        if s.isReachable {
            s.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
        if queued {
            s.transferUserInfo(message)
        }
    }

    private func hello() {
        guard let s = session, s.isReachable else { return }
        var m: [String: Any] = [WatchProtocol.kind: WatchProtocol.Kind.hello.rawValue,
                                WatchProtocol.recording: currentSession != nil]
        if let currentSession { m[WatchProtocol.session] = currentSession }
        s.sendMessage(m, replyHandler: nil, errorHandler: nil)
    }

    private func take(_ dict: [String: Any]) {
        guard let c = WatchSessionContext(wire: dict) else { return }
        if let old = context, old.sentAt > c.sentAt { return }   // an older word arriving late
        context = c
        if c.state == .ended, let onSessionEnded {
            Task { await onSessionEnded(c.sessionId) }
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.activated = state == .activated
            self.reachable = session.isReachable
            self.take(session.receivedApplicationContext)
            self.hello()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if session.isReachable {
                self.hello()
                self.flush()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.take(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.take(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.take(message) }
        replyHandler(["ok": true])
    }
}
