import AVFoundation
import Observation
import SwiftUI

/// The person's yes or no to "May I watch your face while we play?", and the one
/// tracker that runs during Sparks and snow and Breathe with Lanvi.
///
/// - Asked once, kindly, before the first game; "Not now" is an equal answer.
/// - Only with a yes, only during those two games, only with a TrueDepth camera.
/// - The answer can be changed any time from the Help screen.
/// - Numbers only reach the activity record (`face`); nothing else is kept.
///
/// Launch arguments for screenshots and tests: `-faceAsk` asks even where face
/// tracking cannot run (the simulator), `-faceReset` forgets the answer.
@Observable @MainActor
final class FaceSense {
    static let shared = FaceSense()

    enum Answer: String { case yes, no }

    private static let key = "lanvi.face.answer"

    /// nil until the person answered.
    private(set) var answer: Answer?
    /// True while the camera is quietly on behind a game (shows the small indicator).
    private(set) var isOn = false
    /// The camera permission was refused in Settings.
    private(set) var cameraDenied = false

    private var tracker: FaceTracker?

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-faceReset") { UserDefaults.standard.removeObject(forKey: Self.key) }
        answer = UserDefaults.standard.string(forKey: Self.key).flatMap(Answer.init(rawValue:))
        cameraDenied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Face tracking can run on this phone at all.
    var canRun: Bool { FaceTracker.isSupported }

    /// Ask before this game: no answer yet, and the phone can do it (or `-faceAsk`).
    var shouldAsk: Bool {
        answer == nil && (canRun || ProcessInfo.processInfo.arguments.contains("-faceAsk"))
    }

    var isAllowed: Bool { answer == .yes }

    /// The person answered the question (or flipped the switch in Help).
    func setAllowed(_ yes: Bool) async {
        answer = yes ? .yes : .no
        UserDefaults.standard.set(answer?.rawValue, forKey: Self.key)
        if yes { await askCameraIfNeeded() }
    }

    private func askCameraIfNeeded() async {
        guard canRun else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraDenied = !granted
        case .denied, .restricted:
            cameraDenied = true
        default:
            cameraDenied = false
        }
    }

    // MARK: During a game

    /// The game screen appeared: start quietly when allowed. Never throws, never waits.
    func begin() {
        guard tracker == nil, isAllowed, canRun,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let t = FaceTracker()
        guard t.start() else { return }
        tracker = t
        isOn = true
    }

    /// A pleasant moment in the game (Lanvi cheers): for the smile response.
    static func mark() {
        shared.tracker?.mark()
    }

    /// The game ended with a record: stop and attach the summary, if there is a good one.
    func attach(to record: API.ActivityIn) -> API.ActivityIn {
        guard let t = tracker else { return record }
        tracker = nil
        isOn = false
        var r = record
        guard r.type == .focus || r.type == .breathing, let face = t.finish() else { return r }
        r.face = face
        #if DEBUG
        if let data = try? API.encoder.encode(face), let s = String(data: data, encoding: .utf8) {
            print("lanvi-sense: face \(s)")
        }
        #endif
        return r
    }

    /// The game went away without a record: stop, keep nothing.
    func end() {
        tracker?.cancel()
        tracker = nil
        isOn = false
    }
}
