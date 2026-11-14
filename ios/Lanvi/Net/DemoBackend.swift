import Foundation

/// Offline demo: behaves like the server with believable sample data, so the
/// look can always be shown and the screens tested without a config.
/// Lines and stories are copied from the server's fixed set
/// (`engine/clinic_engine/data/lanvi_lines.json`); XP follows the same rules.
///
/// Launch arguments pick the starting moment (handy for screenshots):
/// `-demoGlow 0.15`, `-demoXP 230`, `-demoSuggestion breathing|focus_game|checkin|walk_10min`,
/// `-demoWandering back|away`.
actor DemoBackend: LanviBackend {
    private var xp: Int
    private var glow: Double
    private var wandering: API.WanderingOut
    private var suggestion: API.SuggestionOut?
    private var line: API.LineOut
    private var awardsToday: [API.ActivityType: Int] = [:]
    private var seen: [String: API.ActivityOut] = [:]
    private var storyIndex = 0
    private var lessons: [API.Lesson] = [
        API.Lesson(id: "les_demo_breathing", text: "Breathe with Lanvi seemed to suit you, so it comes first now.",
                   action: "breathing", evidenceCount: 4),
        API.Lesson(id: "les_demo_evening", text: "Evenings seem to be a good time for a check-in.",
                   action: "checkin", evidenceCount: 3),
    ]
    private var questions: [API.Question] = [
        API.Question(id: "q_demo_walk", text: "Was a short walk too much on some days?", answers: ["yes", "no", "not_sure"]),
    ]

    /// XP that fills the glow (as on the server).
    private let glowCapacity = 50.0

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        // The -demo walk-through starts just short of grown fox with a nearly full
        // glow, so one activity shows growing up and Lanvi running off to wander.
        let walkthrough = arguments.contains("-demo")
        xp = value("-demoXP").flatMap(Int.init) ?? (walkthrough ? 290 : 230)
        glow = value("-demoGlow").flatMap(Double.init).map { min(max($0, 0), 1) } ?? (walkthrough ? 0.8 : 0.45)
        line = API.LineOut(templateId: "hello.2", text: "Good to see you. My tail is a little brighter now.")
        wandering = API.WanderingOut(state: .home, id: nil, returnsAt: nil, story: nil)

        if let action = value("-demoSuggestion") ?? (walkthrough ? "breathing" : nil) {
            suggestion = Self.suggestion(for: action)
            if let s = suggestion { line = API.LineOut(templateId: "\(action).1", text: s.text) }
        }
        // `-demoLine "<text>"`: what Lanvi says on Home (for screenshots of short and long lines).
        if let l = value("-demoLine") { line = API.LineOut(templateId: "demo", text: l) }
        switch value("-demoWandering") {
        case "back":
            wandering = API.WanderingOut(state: .back, id: "wander-0006", returnsAt: nil, story: Self.stories[0])
            line = API.LineOut(templateId: "back.1", text: "I'm back. I have a little story for you.")
        case "away":
            let back = Date().addingTimeInterval(3 * 3600)
            wandering = API.WanderingOut(state: .away, id: "wander-0007", returnsAt: API.isoString(back), story: nil)
            line = API.LineOut(templateId: "away.1", text: "Lanvi is off wandering across Lapland. Back soon.")
        default: break
        }
    }

    func today() async throws -> API.TodayOut {
        try await Task.sleep(for: .milliseconds(250))
        let (stage, next) = Self.stage(for: xp)
        return API.TodayOut(
            status: .within,
            suggestion: suggestion,
            lanvi: API.LanviOut(xp: xp, stage: stage, nextStageAt: next, glow: glow,
                                wandering: wandering, line: line,
                                planToAsk: API.PlanToAsk(checkinId: "demo-checkin-0001", planId: "coffee_outside")),
            roundConfig: nil,
            attention: "Your days look like your usual.",
            crisis: Self.crisis,
            productName: "Lanvi")
    }

    func send(_ a: API.ActivityIn) async throws -> API.ActivityOut {
        try await Task.sleep(for: .milliseconds(450))
        if let old = seen[a.id] {
            var again = old
            again.xpGained = 0
            return again
        }
        let caps: [API.ActivityType: Int] = [.focus: 2, .breathing: 2, .checkin: 1]
        var gained = 0
        if a.durationS >= 5, awardsToday[a.type, default: 0] < caps[a.type, default: 1] {
            gained = 10
            if a.type == .checkin, a.planDone == .yes { gained += 15 }
            awardsToday[a.type, default: 0] += 1
        }
        xp += gained
        glow = min(1, glow + Double(gained) / glowCapacity)
        if suggestion?.id == a.suggestionId { suggestion = nil }

        var state = wandering.state
        if glow >= 1, state == .home {
            // A full glow starts a wandering; the glow starts filling again.
            state = .away
            wandering = API.WanderingOut(state: .away, id: "wander-0007",
                                         returnsAt: API.isoString(Date().addingTimeInterval(3 * 3600)), story: nil)
        }

        let lineText: String
        switch (a.type, a.completed) {
        case (.focus, true): lineText = "Thanks for playing with me. The sparks liked that."
        case (.focus, false): lineText = "Thanks for playing. Every spark counts."
        case (.breathing, true): lineText = "That was calm and lovely. Thank you for breathing with me."
        case (.breathing, false): lineText = "Thank you for breathing with me."
        case (.checkin, _):
            lineText = a.plan != nil ? "Sounds nice. I will ask you about it tomorrow."
                                     : "Thank you. I will keep these good things safe."
        }
        let doneLine = API.LineOut(templateId: "\(a.type.rawValue)_done", text: lineText)
        line = doneLine
        let (stage, next) = Self.stage(for: xp)
        let out = API.ActivityOut(id: a.id, type: a.type.rawValue, xpGained: gained, xpTotal: xp,
                                  stage: stage, nextStageAt: next, glow: state == .away ? 1 : glow,
                                  wandering: state, line: doneLine, crisis: false, crisisBlock: nil,
                                  reading: a.type == .checkin ? "not_applicable" : "off")
        if state == .away { glow = 0 }
        seen[a.id] = out
        return out
    }

    func checkinOptions() async throws -> API.CheckinOptionsOut {
        API.CheckinOptionsOut(
            goodThings: [
                .init(id: "walked", label: "I went for a walk"),
                .init(id: "outside", label: "I was outside"),
                .init(id: "good_food", label: "I ate something good"),
                .init(id: "talked_to_someone", label: "I talked to someone"),
                .init(id: "music", label: "I listened to music"),
                .init(id: "rested", label: "I rested"),
                .init(id: "got_something_done", label: "I got something done"),
                .init(id: "laughed", label: "I laughed"),
                .init(id: "kind_moment", label: "Someone was kind, or I was"),
            ],
            plans: [
                .init(id: "walk", label: "A walk"),
                .init(id: "coffee_outside", label: "Coffee outside"),
                .init(id: "call_someone", label: "Call someone"),
                .init(id: "music", label: "Listen to a song I like"),
                .init(id: "cook_something", label: "Cook something simple"),
                .init(id: "daylight", label: "Sit in the daylight"),
                .init(id: "tidy_one_thing", label: "Tidy one small thing"),
                .init(id: "rest_early", label: "Go to bed a bit earlier"),
            ])
    }

    func setPreferences(_ helps: [String]) async throws -> API.PreferencesOut {
        let text = helps.first == "moving" ? "Got it. I'll start with walks." : "Got it. Thank you for telling me."
        return API.PreferencesOut(helps: helps, line: API.LineOut(templateId: "preferences.\(helps.first ?? "none")", text: text))
    }

    func answerWandering(id: String, answer: String) async throws -> API.WanderingAnswerOut {
        try await Task.sleep(for: .milliseconds(300))
        guard wandering.state == .back, wandering.id == id else { throw APIError.notFound }
        wandering = API.WanderingOut(state: .home, id: nil, returnsAt: nil, story: nil)
        line = API.LineOut(templateId: "hello.3", text: "Hi there. I was watching the sky.")
        storyIndex += 1
        return API.WanderingAnswerOut(id: id, answer: answer, wandering: wandering)
    }

    func mind() async throws -> API.MindOut {
        try await Task.sleep(for: .milliseconds(250))
        return API.MindOut(rules: [], lessons: lessons, questions: questions)
    }

    func feedback(_ f: API.FeedbackIn) async throws -> API.FeedbackOut {
        try await Task.sleep(for: .milliseconds(300))
        guard suggestion?.id == f.suggestionId else { throw APIError.notFound }
        suggestion = nil
        return API.FeedbackOut(ok: true)
    }

    /// Offline chat: a few believable replies from the server's own fixed set.
    func note(_ n: API.NoteIn) async throws -> API.NoteOut {
        // `-chatSlow`: a slower answer, to show the waiting dots in a screenshot.
        let slow = ProcessInfo.processInfo.arguments.contains("-chatSlow")
        try await Task.sleep(for: .milliseconds(slow ? 4000 : 1100))
        let t = n.text.lowercased()
        if ["need help", "help me", "kill myself", "hurt myself"].contains(where: t.contains) {
            return API.NoteOut(reply: .init(templateId: "help", text: "Thank you for telling me. You do not have to carry this alone. The help contacts are right here."),
                               crisis: true, crisisBlock: Self.crisis, suggestion: nil)
        }
        if ["tired", "sad", "lonely", "rough", "bad"].contains(where: t.contains) {
            return API.NoteOut(reply: .init(templateId: "low_2", text: "Thank you for sharing this. Let's go gently, one small thing at a time."),
                               crisis: false, crisisBlock: nil,
                               suggestion: Self.suggestion(for: "breathing"))
        }
        if ["good", "nice", "happy", "great", "walk", "coffee", "sun"].contains(where: t.contains) {
            return API.NoteOut(reply: .init(templateId: "good", text: "That is lovely to hear. My tail is glowing."),
                               crisis: false, crisisBlock: nil, suggestion: nil)
        }
        let neutral = [("ok", "Thank you. I am glad you told me."), ("neutral", "Thank you. I keep your words safe.")]
        let pick = neutral[n.text.count % neutral.count]
        return API.NoteOut(reply: .init(templateId: pick.0, text: pick.1), crisis: false, crisisBlock: nil, suggestion: nil)
    }

    func rejectLesson(id: String) async throws -> API.StatusOut {
        guard lessons.contains(where: { $0.id == id }) else { throw APIError.notFound }
        lessons.removeAll { $0.id == id }
        return API.StatusOut(id: id, status: "rejected")
    }

    func answerQuestion(id: String, answer: String) async throws -> API.StatusOut {
        guard questions.contains(where: { $0.id == id }) else { throw APIError.notFound }
        questions.removeAll { $0.id == id }
        return API.StatusOut(id: id, status: "answered")
    }

    /// Demo only: Lanvi comes back from the wandering now, with a story.
    func comeBack() {
        let story = Self.stories[storyIndex % Self.stories.count]
        wandering = API.WanderingOut(state: .back, id: "wander-0007", returnsAt: nil, story: story)
        line = API.LineOut(templateId: "back.1", text: "I'm back. I have a little story for you.")
    }

    // MARK: Sample data

    static func stage(for xp: Int) -> (API.Stage, Int?) {
        if xp >= 300 { return (.grownFox, nil) }
        if xp >= 100 { return (.youngFox, 300) }
        return (.kit, 100)
    }

    static func suggestion(for action: String) -> API.SuggestionOut? {
        let texts = [
            "breathing": "Want to breathe with me for a minute?",
            "focus_game": "Want to catch a few sparks with me?",
            "checkin": "Want to tell me three good things from today?",
            "walk_10min": "How about a ten-minute walk, at your own pace?",
            "daylight_10min": "Shall we find ten minutes of daylight, by a window or outside?",
            "call_someone": "Is there someone you would like to call or message today?",
        ]
        guard let text = texts[action] else { return nil }
        return API.SuggestionOut(id: "sug_0123456789abcdef01234567", action: action, text: text,
                                 createdAt: API.isoString(Date()))
    }

    static let stories: [API.StoryOut] = [
        API.StoryOut(id: "story.reindeer",
                     text: "I met a reindeer by a frozen lake. She was counting stars and kept losing her place.",
                     question: "Should I help her count tomorrow?",
                     answers: [.init(id: "a", text: "Yes, help her"), .init(id: "b", text: "Let her count alone")]),
        API.StoryOut(id: "story.owl",
                     text: "A snowy owl asked me why my tail glows. I told her it is because of you.",
                     question: "What colour should I glow next time?",
                     answers: [.init(id: "a", text: "Green"), .init(id: "b", text: "Violet")]),
    ]

    static let crisis = API.CrisisBlock(
        text: "Lanvi is not an emergency service. In an emergency, call 112. Otherwise, contact your clinic.",
        contacts: [API.CrisisContact(label: "Emergency number", phone: "112")],
        reviewedByClinician: false)
}
