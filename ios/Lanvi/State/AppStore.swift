import Foundation
import Observation
import SwiftUI

/// The three things a person can play from Home.
enum ActivityKind: String, Identifiable, CaseIterable {
    case focus, breathing, checkin
    var id: String { rawValue }

    /// The server's suggestion action that opens this activity.
    var suggestionAction: String {
        switch self {
        case .focus: return "focus_game"
        case .breathing: return "breathing"
        case .checkin: return "checkin"
        }
    }
}

/// The moment after an activity: what Home animates.
struct HomeCelebration: Equatable, Identifiable {
    let id = UUID()
    var kind: ActivityKind
    var xpGained: Int
    var line: String
    var startedWandering: Bool
}

/// One observable store for the whole app: today's state from the server (or the
/// offline demo), the outbox of unsent activities, and the moments Home shows.
@Observable @MainActor
final class AppStore {
    enum Mode { case live, demo }
    enum Link { case connecting, online, offline }

    let mode: Mode
    private let backend: any LanviBackend
    private var outbox = ActivityOutbox()

    // Today
    private(set) var today: API.TodayOut?
    private(set) var link: Link = .connecting
    private(set) var checkinOptions: API.CheckinOptionsOut?
    /// The line Lanvi says right now (the server's, or the one after an activity).
    private(set) var line: String = ""

    // Moments for Home
    var celebration: HomeCelebration?
    /// Set when the server says typed words asked for help: Home opens Help at once.
    var crisisNow: API.CrisisBlock?
    private(set) var storyThanks: String?
    private var suggestionsPlayed: Set<String> = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let config = ServerConfig.current
        if config.isLive, let url = config.serverURL {
            mode = .live
            backend = LanviClient(base: url, pairingCode: config.pairingCode)
            // Last known state, so an offline start still shows Lanvi as it was.
            if let cached = LanviDisk.load(API.TodayOut.self, "today.json") { apply(cached) }
        } else {
            mode = .demo
            backend = DemoBackend(arguments: arguments)
        }
    }

    // MARK: Derived values for Home

    var lanvi: API.LanviOut? { today?.lanvi }
    var xp: Int { today?.lanvi.xp ?? 0 }
    var glow: Double { min(max(today?.lanvi.glow ?? 0, 0), 1) }
    var stage: API.Stage { today?.lanvi.stage ?? .kit }
    var crisis: API.CrisisBlock { today?.crisis ?? DemoBackend.crisis }
    var wandering: API.WanderingOut? { today?.lanvi.wandering }
    var planToAsk: API.PlanToAsk? { today?.lanvi.planToAsk }
    var pendingCount: Int { outbox.items.count }

    /// The suggestion, shown once: hidden after it was played.
    var suggestion: API.SuggestionOut? {
        guard let s = today?.suggestion, !suggestionsPlayed.contains(s.id) else { return nil }
        return s
    }

    /// The card the suggestion points at, if it is one of the three activities.
    var suggestedKind: ActivityKind? {
        guard let s = suggestion else { return nil }
        return ActivityKind.allCases.first { $0.suggestionAction == s.action }
    }

    /// XP where the current stage began, and where the next one starts.
    var stageRange: (start: Int, next: Int?) {
        let starts: [API.Stage: Int] = [.kit: 0, .youngFox: 100, .grownFox: 300]
        return (starts[stage] ?? 0, today?.lanvi.nextStageAt)
    }

    // MARK: Loading

    private var startTask: Task<Void, Never>?

    /// On open: send what is waiting, then ask for today. Safe to call from
    /// several places; the work runs once and later callers wait for it.
    func start() async {
        if let startTask { return await startTask.value }
        let t = Task { await load() }
        startTask = t
        await t.value
    }

    /// Back in the foreground: send what waited, then ask for today again.
    func resume() async {
        guard startTask != nil else { return }
        await flushOutbox()
        await refresh()
    }

    private func load() async {
        await flushOutbox()
        await refresh()
        if checkinOptions == nil { checkinOptions = try? await backend.checkinOptions() }
    }

    func refresh() async {
        do {
            let t = try await backend.today()
            apply(t)
            link = .online
            if mode == .live { LanviDisk.save(t, "today.json") }
        } catch {
            link = .offline
            if today == nil, mode == .live {
                // Never an empty screen: a calm stand-in until the server answers.
                apply(Self.placeholderToday)
            }
        }
    }

    private func apply(_ t: API.TodayOut) {
        today = t
        line = t.lanvi.line.text
    }

    // MARK: Activities

    /// An activity finished (or was stopped): send it, then celebrate with the
    /// server's answer. Unsent records stay on disk and go out on the next open.
    func finish(_ activity: API.ActivityIn, kind: ActivityKind) async {
        var record = activity
        if record.suggestionId == nil, let s = suggestion, s.action == kind.suggestionAction {
            record.suggestionId = s.id
        }
        if let sid = record.suggestionId { suggestionsPlayed.insert(sid) }
        outbox.add(record)

        do {
            let out = try await backend.send(record)
            outbox.remove(id: record.id)
            link = .online
            await celebrate(out, kind: kind)
            if out.wandering != wandering?.state { await refresh() }
        } catch let e as APIError where e.isTemporary {
            link = .offline
            celebrateOffline(kind: kind)
        } catch {
            // Refused for good (shape, plausibility, reused id): drop it, still thank them.
            outbox.remove(id: record.id)
            celebrateOffline(kind: kind)
        }
    }

    private func celebrate(_ out: API.ActivityOut, kind: ActivityKind) async {
        guard var t = today else { return }
        line = out.line.text
        celebration = HomeCelebration(kind: kind, xpGained: out.xpGained, line: out.line.text,
                                  startedWandering: out.wandering == .away && t.lanvi.wandering.state != .away)
        // Let Home show the cheer before the numbers move.
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.spring(response: 1.1, dampingFraction: 0.82)) {
            t.lanvi.xp = out.xpTotal
            t.lanvi.stage = out.stage
            t.lanvi.nextStageAt = out.nextStageAt
            t.lanvi.glow = out.glow
            t.lanvi.line = out.line
            today = t
        }
        if out.crisis == true, let block = out.crisisBlock { crisisNow = block }
        if mode == .live { LanviDisk.save(t, "today.json") }
    }

    private func celebrateOffline(kind: ActivityKind) {
        line = "Thanks for coming by. I'll tell the sky when we're back online."
        celebration = HomeCelebration(kind: kind, xpGained: 0, line: line, startedWandering: false)
    }

    private func flushOutbox() async {
        for item in outbox.items {
            do {
                _ = try await backend.send(item)
                outbox.remove(id: item.id)
            } catch let e as APIError where e.isTemporary {
                return   // still offline: try again next open
            } catch {
                outbox.remove(id: item.id)
            }
        }
    }

    // MARK: Wandering, preferences

    /// Answer the story Lanvi brought back ("a" or "b").
    func answerStory(_ answer: String) async -> Bool {
        guard let w = wandering, w.state == .back, let id = w.id else { return false }
        do {
            let out = try await backend.answerWandering(id: id, answer: answer)
            if var t = today {
                t.lanvi.wandering = out.wandering ?? API.WanderingOut(state: .home, id: nil, returnsAt: nil, story: nil)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { today = t }
            }
            line = "Thank you. I'll remember that on my next trip."
            await refresh()
            line = "Thank you. I'll remember that on my next trip."
            return true
        } catch APIError.notFound {
            await refresh()   // the story was already answered elsewhere
            return true
        } catch {
            link = .offline
            return false
        }
    }

    @discardableResult
    func setPreferences(_ helps: [String]) async -> String? {
        try? await backend.setPreferences(helps).line.text
    }

    // MARK: Demo helpers

    /// For the `-demo` walk-through: a breathing minute that just finished.
    static func sampleBreathing(suggestionId: String? = nil) -> API.ActivityIn {
        API.ActivityIn(id: API.ActivityIn.newId(), type: .breathing,
                       startedAt: API.isoString(Date().addingTimeInterval(-62)), durationS: 61,
                       completed: true, endedBy: .finished, suggestionId: suggestionId,
                       timePlayedS: 60, breathsCompleted: 6)
    }

    private static let placeholderToday = API.TodayOut(
        status: .noData, suggestion: nil,
        lanvi: API.LanviOut(xp: 0, stage: .kit, nextStageAt: 100, glow: 0.2,
                            wandering: API.WanderingOut(state: .home, id: nil, returnsAt: nil, story: nil),
                            line: API.LineOut(templateId: "hello.1", text: "Hi. The snow is quiet today."),
                            planToAsk: nil),
        roundConfig: nil, attention: "", crisis: DemoBackend.crisis, productName: "Lanvi")
}
