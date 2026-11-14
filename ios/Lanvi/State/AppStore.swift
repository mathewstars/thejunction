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

/// Time of day, for the sky and Lanvi's resting pose.
enum DayPart { case morning, day, evening, night }

/// What the big "For today" card on Home shows.
enum TodayThing: Equatable {
    case game(ActivityKind)             // one of the three activities
    case realWorld(API.SuggestionOut)   // walk, daylight, call someone: "I did it" / "Not today"
    case done(DoneToday)                // today's one thing is done
}

/// The moment after an activity: what Home animates.
struct HomeCelebration: Equatable, Identifiable {
    let id = UUID()
    var kind: ActivityKind
    var xpGained: Int
    var line: String
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
    private var feedbackOutbox = FeedbackOutbox()

    // The day, kept on the phone
    /// `-hour 20` shows the app as at that hour (sky, pose and today's pick).
    private let forcedHour: Int?
    private(set) var days: DaysTogether
    private let daysFile: String?

    // Chat with Lanvi: today's thread, kept on the phone for the day
    private(set) var chat = ChatThread()
    /// True only while a message is on its way to the server (the dots are honest).
    private(set) var chatWaiting = false
    private let chatFile: String?
    /// Changes when Lanvi should give a small cheer on Home (a real-world "I did it").
    private(set) var cheerTick = 0

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
    /// Set when the stage went up with the last activity: Home celebrates it.
    var grewUp: API.Stage?
    /// What Lanvi has learned (GET /v1/mind), loaded when that screen opens.
    private(set) var mind: API.MindOut?
    private(set) var mindFailed = false
    private var suggestionsPlayed: Set<String> = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        forcedHour = value("-hour").flatMap(Int.init).map { min(max($0, 0), 23) }
            ?? (arguments.contains("-demo") ? 20 : nil)
        let config = ServerConfig.current
        // The -demo walk-through always uses the offline demo, so the video is the same every time.
        // The app never asks for a pairing code (the captain): it talks to the server only
        // when this phone is already paired or a tester code sits in the private config;
        // otherwise it quietly runs on offline sample data.
        let canPair = config.serverURL.map { TokenKeychain.token(for: $0) != nil } == true || config.pairingCode != nil
        if config.isLive, canPair, !arguments.contains("-demo"), let url = config.serverURL {
            mode = .live
            backend = LanviClient(base: url, pairingCode: config.pairingCode)
            daysFile = "days.json"
            days = DaysTogether.load("days.json")
            chatFile = "chat.json"
            chat = LanviDisk.load(ChatThread.self, "chat.json") ?? ChatThread()
            // Last known state, so an offline start still shows Lanvi as it was.
            if let cached = LanviDisk.load(API.TodayOut.self, "today.json") { apply(cached) }
        } else {
            mode = .demo
            backend = DemoBackend(arguments: arguments)
            // The demo never writes the real days or chat to disk; it starts from samples.
            daysFile = nil
            chatFile = nil
            var d = DaysTogether()
            let past = value("-demoDays").flatMap(Int.init) ?? 11
            for i in stride(from: past, to: 0, by: -1) {
                d.dates.append(DaysTogether.key(Date().addingTimeInterval(Double(-i) * 86_400)))
            }
            d.roll(to: Date())
            if let k = value("-demoDone").flatMap(ActivityKind.init(rawValue:)) {
                d.markTogether(Date())
                d.kindsToday = [k.rawValue]
                d.done = DoneToday(kind: k.rawValue, log: Self.log(k, seconds: k == .focus ? 45 : 60))
            }
            days = d
        }
        days.roll(to: Date())
    }

    // MARK: The day

    /// Now, or the forced hour today.
    var now: Date {
        guard let h = forcedHour else { return Date() }
        return Calendar.current.date(bySettingHour: h, minute: 10, second: 0, of: Date()) ?? Date()
    }

    var dayPart: DayPart {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return .morning
        case 12..<18: return .day
        case 18..<21: return .evening
        default: return .night
        }
    }

    /// Which painted scene Lanvi is in right now.
    var worldScene: WorldScene { .at(hour: Calendar.current.component(.hour, from: now)) }

    /// Back after three or more days away (nothing done yet today): Lanvi kept a spot warm.
    var backAfterGap: Bool {
        guard !days.dates.contains(days.today) else { return false }
        guard let last = days.dates.max(), let lastDay = DaysTogether.date(last) else { return false }
        return Calendar.current.dateComponents([.day], from: lastDay, to: Date()).day ?? 0 >= 3
    }

    /// Nothing done together yet: the very first time.
    var firstTime: Bool { days.dates.isEmpty }

    var daysTogether: Int { max(days.dates.count, 1) }   // today counts as day one

    /// Today's one thing. What is done stays done; then the server's suggestion;
    /// then the clock (morning breathing, afternoon Sparks and snow, evening the check-in).
    var todayThing: TodayThing {
        if let d = days.done, days.today == DaysTogether.key(Date()) { return .done(d) }
        if let s = suggestion {
            if let k = suggestedKind { return .game(k) }
            if Self.realWorldActions.contains(s.action) { return .realWorld(s) }
        }
        switch dayPart {
        case .morning: return .game(.breathing)
        case .day: return .game(.focus)
        case .evening, .night:
            if days.kindsToday.contains(ActivityKind.checkin.rawValue) {
                return .done(DoneToday(kind: "checkin", log: Self.log(.checkin, seconds: 60)))
            }
            return .game(.checkin)
        }
    }

    static let realWorldActions: Set<String> = ["walk_10min", "daylight_10min", "call_someone"]

    /// The tiny log line for something done together.
    static func log(_ kind: ActivityKind, seconds: Double) -> String {
        let time = seconds >= 50 ? "\(max(1, Int((seconds / 60).rounded()))) min" : "\(Int(seconds)) sec"
        switch kind {
        case .breathing: return "Breathed together, \(time)"
        case .focus: return "Caught sparks together, \(time)"
        case .checkin: return "Shared good things from today"
        }
    }

    static func realWorldLog(_ action: String) -> String {
        switch action {
        case "walk_10min": return "Went for a short walk"
        case "daylight_10min": return "Found some daylight"
        default: return "Reached out to someone"
        }
    }

    private func saveDays() {
        if let daysFile { days.save(daysFile) }
    }

    /// Something was done together today: the day counts, and when it was
    /// today's one thing, the card turns calm.
    private func markDone(_ kind: ActivityKind, seconds: Double, thing: TodayThing) {
        days.markTogether(Date())
        days.kindsToday.append(kind.rawValue)
        if case .game(let k) = thing, k == kind, days.done == nil {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                days.done = DoneToday(kind: kind.rawValue, log: Self.log(kind, seconds: seconds))
            }
        }
        saveDays()
    }

    /// "I did it" or "Not today" on a real-world suggestion. Both are fine, both
    /// get a warm line, and "Not today" is never argued with.
    func answerSuggestion(_ s: API.SuggestionOut, didIt: Bool) async {
        let f = API.FeedbackIn(id: API.ActivityIn.newId(), suggestionId: s.id, answer: didIt ? "did_it" : "not_today")
        feedbackOutbox.add(f)
        suggestionsPlayed.insert(s.id)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            line = didIt ? "You did it. That makes my tail glow." : "That is okay. Tomorrow has room for small things too."
            if didIt { days.markTogether(Date()) } else { days.roll(to: Date()) }
            days.done = DoneToday(kind: s.action, log: didIt ? Self.realWorldLog(s.action) : "", restful: !didIt)
        }
        if didIt { cheerTick += 1 }
        saveDays()
        do {
            _ = try await backend.feedback(f)
            feedbackOutbox.remove(id: f.id)
        } catch let e as APIError where e.isTemporary {
            link = .offline
        } catch {
            feedbackOutbox.remove(id: f.id)
        }
    }

    // MARK: Chat

    /// Opening the chat: a new day starts a fresh thread with Lanvi's line of the day.
    func openChat() {
        let key = DaysTogether.key(Date())
        if chat.day != key {
            chat = ChatThread(day: key, messages: [])
        }
        if chat.messages.isEmpty {
            let opening = today?.lanvi.line.text ?? (line.isEmpty ? "Hi. The snow is quiet today." : line)
            chat.messages.append(ChatMessage(id: "open-\(key)", from: .lanvi, text: opening))
        }
        saveChat()
    }

    /// Send one message. Lanvi's answer always comes from the server.
    func sendChat(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = ChatMessage(id: API.ActivityIn.newId(), from: .me, text: String(trimmed.prefix(280)), status: .sending)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { chat.messages.append(msg) }
        saveChat()
        await deliver(msg.id)
    }

    /// Try a message marked "not sent" again (same id, so the server sees it once).
    func retryChat(_ id: String) async {
        guard let i = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        chat.messages[i].status = .sending
        await deliver(id)
    }

    private func deliver(_ id: String) async {
        guard let msg = chat.messages.first(where: { $0.id == id }) else { return }
        chatWaiting = true
        defer { chatWaiting = false }
        do {
            let reply = try await backend.sendMessage(id: msg.id, text: msg.text)
            link = .online
            if let i = chat.messages.firstIndex(where: { $0.id == id }) { chat.messages[i].status = .sent }
            chatWaiting = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                chat.messages.append(ChatMessage(id: "re-\(id)", from: .lanvi, text: reply.text,
                                                 suggestion: reply.suggestion))
            }
            if let s = reply.suggestion, var t = today {
                // Home's "For today" card shows it afterwards.
                t.suggestion = s
                today = t
            }
            if let block = reply.crisis { crisisNow = block }
        } catch {
            if case APIError.offline = error { link = .offline }
            if let i = chat.messages.firstIndex(where: { $0.id == id }) { chat.messages[i].status = .failed }
        }
        saveChat()
    }

    private func saveChat() {
        if let chatFile { LanviDisk.save(chat, chatFile) }
    }

    private func flushFeedback() async {
        for item in feedbackOutbox.items {
            do {
                _ = try await backend.feedback(item)
                feedbackOutbox.remove(id: item.id)
            } catch let e as APIError where e.isTemporary {
                return
            } catch {
                feedbackOutbox.remove(id: item.id)
            }
        }
    }

    // MARK: Derived values for Home

    var lanvi: API.LanviOut? { today?.lanvi }
    var xp: Int { today?.lanvi.xp ?? 0 }
    var glow: Double { min(max(today?.lanvi.glow ?? 0, 0), 1) }
    var stage: API.Stage { today?.lanvi.stage ?? .kit }
    var crisis: API.CrisisBlock { today?.crisis ?? DemoBackend.crisis }
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
        days.roll(to: Date())
        await flushOutbox()
        await flushFeedback()
        await refresh()
    }

    private func load() async {
        await flushOutbox()
        await flushFeedback()
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
        line = Self.careLine(t.lanvi.line)
    }

    /// The wandering and its stories are cut (the captain, Saturday): Lanvi never
    /// leaves and never has a story. The server may still send its wandering lines
    /// (`away.*`, `back.*` in engine/clinic_engine/data/lanvi_lines.json); those are
    /// swapped for a plain line in the care voice. The `wandering` object is ignored.
    static func careLine(_ l: API.LineOut) -> String {
        let id = l.templateId
        guard id.hasPrefix("away.") || id.hasPrefix("back.") else { return l.text }
        let lines = ["Hi. I'm glad you're here.",
                     "The snow is soft today. Stay a while?",
                     "There you are. I kept a spot warm for you."]
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return lines[day % lines.count]           // the same line all day
    }

    // MARK: Activities

    /// An activity finished (or was stopped): send it, then celebrate with the
    /// server's answer. Unsent records stay on disk and go out on the next open.
    func finish(_ activity: API.ActivityIn, kind: ActivityKind) async {
        var record = activity
        if record.suggestionId == nil, let s = suggestion, s.action == kind.suggestionAction {
            record.suggestionId = s.id
        }
        let thing = todayThing
        if let sid = record.suggestionId { suggestionsPlayed.insert(sid) }
        outbox.add(record)

        do {
            let out = try await backend.send(record)
            outbox.remove(id: record.id)
            link = .online
            await celebrate(out, kind: kind)
            markDone(kind, seconds: record.durationS, thing: thing)
        } catch let e as APIError where e.isTemporary {
            link = .offline
            celebrateOffline(kind: kind)
            markDone(kind, seconds: record.durationS, thing: thing)
        } catch {
            // Refused for good (shape, plausibility, reused id): drop it, still thank them.
            outbox.remove(id: record.id)
            celebrateOffline(kind: kind)
            markDone(kind, seconds: record.durationS, thing: thing)
        }
    }

    private func celebrate(_ out: API.ActivityOut, kind: ActivityKind) async {
        guard var t = today else { return }
        let oldStage = t.lanvi.stage
        line = out.line.text
        line = Self.careLine(out.line)
        celebration = HomeCelebration(kind: kind, xpGained: out.xpGained, line: line)
        // Let Lanvi's happy hop start, then the numbers move.
        try? await Task.sleep(for: .milliseconds(out.xpGained > 0 ? 500 : 300))
        #if DEBUG
        FrameMeter.mark("xp numbers move")
        #endif
        withAnimation(.spring(response: 1.1, dampingFraction: 0.82)) {
            t.lanvi.xp = out.xpTotal
            t.lanvi.stage = out.stage
            t.lanvi.nextStageAt = out.nextStageAt
            t.lanvi.glow = out.glow
            t.lanvi.line = API.LineOut(templateId: out.line.templateId, text: line)
            today = t
        }
        if out.crisis == true, let block = out.crisisBlock { crisisNow = block }
        if out.stage != oldStage, out.xpTotal > 0 {
            try? await Task.sleep(for: .milliseconds(1400))
            grewUp = out.stage
        }
        if mode == .live { LanviDisk.save(t, "today.json") }
    }

    private func celebrateOffline(kind: ActivityKind) {
        line = "Thanks for coming by. I'll tell the sky when we're back online."
        celebration = HomeCelebration(kind: kind, xpGained: 0, line: line)
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

    // MARK: Preferences

    // MARK: What Lanvi has learned

    func loadMind() async {
        do {
            mind = try await backend.mind()
            mindFailed = false
        } catch {
            mindFailed = mind == nil
        }
    }

    /// "Not true": the lesson goes away and does not come back from the same evidence.
    func rejectLesson(_ id: String) async -> Bool {
        do {
            _ = try await backend.rejectLesson(id: id)
        } catch APIError.notFound {
            // Already gone: fine.
        } catch {
            return false
        }
        if var m = mind {
            m.lessons.removeAll { $0.id == id }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { mind = m }
        }
        return true
    }

    func answerQuestion(_ id: String, answer: String) async -> Bool {
        do {
            _ = try await backend.answerQuestion(id: id, answer: answer)
        } catch APIError.notFound {
        } catch {
            return false
        }
        if var m = mind {
            m.questions.removeAll { $0.id == id }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { mind = m }
        }
        return true
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
