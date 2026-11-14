import AVFoundation
import UIKit

/// Plays the fox's clips one after another with no gap, decides what comes next,
/// and cross-fades to a reaction at once when it is urgent (a tap).
///
/// Two lanes, each an `AVQueuePlayer` on its own `AVPlayerLayer`. The live lane
/// always has the next clip already queued (so it is decoded before it is needed and
/// the switch at a clip's end is gapless: never a frozen, black or blank frame). An
/// urgent reaction starts on the other lane, which fades in on top over 150 ms once
/// its first frame is ready; then the old lane stops.
@MainActor
final class FoxClipDirector: ObservableObject {
    /// True once a clip's first frame is on screen (the rest picture covers until then).
    @Published private(set) var showing = false
    /// The clip playing now (for the test screen).
    @Published private(set) var current: FoxClip = .idle

    let view = FoxClipLayersView()

    /// Held moods change what plays between reactions.
    var held: Held = .calm {
        didSet { if held != oldValue { requeue() } }
    }
    enum Held: Equatable { case calm, sleepy, listening, talking }

    private var lanes: [Lane] = []
    private var live = 0
    private var pending: FoxClip?
    private var lastMoment: FoxClip?
    private var idleLeft = 1
    private var running = false
    private var assets: [FoxClip: AVURLAsset] = [:]
    private var fading = false
    private var warmed = false
    /// The waiting lane stays rendered, nearly invisible, holding the rest frame: a
    /// video layer shown for the first time costs a long frame, a rendered one does not.
    private static let standby: Float = 0.01

    init() {
        idleLeft = Int.random(in: 1...2)
    }

    /// The first video player in the app costs ~0.2 s while the media frameworks load.
    /// Pay that once, off the main thread, before the first real player is made.
    private static var prewarmed = false
    private static func prewarm() async {
        guard !prewarmed else { return }
        await Task.detached(priority: .userInitiated) {
            let player = AVQueuePlayer()
            _ = AVPlayerLayer(player: player)
            if let url = FoxClip.idle.url { _ = try? await AVURLAsset(url: url).load(.tracks, .duration) }
        }.value
        prewarmed = true
    }

    private func setUp() {
        lanes = [Lane(), Lane()]
        for lane in lanes { view.add(lane.layer) }
        lanes[1].layer.opacity = Self.standby
        for (i, lane) in lanes.enumerated() {
            lane.onAdvance = { [weak self] item in self?.advanced(lane: i, to: item) }
            lane.onReady = { [weak self] in self?.ready(lane: i) }
        }
    }

    /// A second after the first frame: open every clip file once, one by one, and park
    /// the waiting lane on the rest frame, so a later switch never waits on either.
    /// (Doing this at launch, all at once, cost the opening a half-second stall.)
    private func warmUp() {
        guard !warmed else { return }
        warmed = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.running else { self?.warmed = false; return }
            if !self.fading { self.warm(self.lanes[1 - self.live]) }
            for clip in FoxClip.available {
                _ = try? await self.asset(clip).load(.duration, .tracks)
            }
        }
    }

    // MARK: Control

    func start() {
        guard !running else { if !lanes.isEmpty { lanes[live].player.play() }; return }
        running = true
        guard lanes.isEmpty else { return begin() }
        // The rest picture shows until the first frame, so this wait is never blank.
        Task { [weak self] in
            await Self.prewarm()
            guard let self, self.running, self.lanes.isEmpty else { return }
            self.setUp()
            self.begin()
        }
    }

    private func begin() {
        let lane = lanes[live]
        lane.load([item(.idle), item(nextClip(after: .idle))])
        current = .idle
        lane.player.play()
    }

    /// Park a lane on the rest frame (paused), rendered at standby opacity.
    private func warm(_ lane: Lane) {
        lane.player.pause()
        lane.player.removeAllItems()
        lane.player.insert(item(.idle), after: nil)
        lane.layer.opacity = Self.standby
    }

    func pause() { for lane in lanes { lane.player.pause() } }

    func resume() {
        guard running else { return start() }
        if !lanes.isEmpty { lanes[live].player.play() }
    }

    func stop() {
        running = false
        fading = false
        showing = false
        for (i, lane) in lanes.enumerated() {
            lane.player.pause()
            lane.player.removeAllItems()
            lane.layer.removeAllAnimations()
            lane.layer.opacity = i == live ? 1 : Self.standby
        }
    }

    /// Play `clip` next: after the current clip, or (urgent) cross-faded in now.
    func request(_ clip: FoxClip, urgent: Bool = false) {
        let clip = clip.resolved
        guard running, !lanes.isEmpty else { pending = clip; return }
        if urgent { crossFade(to: clip) } else { queueNext(clip) }
    }

    // MARK: What plays next

    /// Chosen when a clip starts, so the pattern never repeats on a timer.
    private func nextClip(after now: FoxClip) -> FoxClip {
        if let p = pending { pending = nil; return p }
        switch held {
        case .talking: return FoxClip.talk.resolved
        case .listening: return now == .listen ? .idle : FoxClip.listen.resolved
        case .sleepy:
            if now == .sleepy { return .idle }
            return Int.random(in: 0..<3) == 0 ? FoxClip.sleepy.resolved : .idle
        case .calm: break
        }
        if idleLeft > 0 {
            idleLeft -= 1
            return .idle
        }
        // A small moment between idles: mostly a look, sometimes a nod or a listen,
        // a yawn in the evening. Never the same moment twice in a row.
        idleLeft = Int.random(in: 0...2)
        let hour = Calendar.current.component(.hour, from: Date())
        var bag: [(FoxClip, Int)] = [(.look, 5), (.nod, 2), (.listen, 2)]
        if hour >= 20 || hour < 6 { bag.append((.sleepy, 3)) }
        bag = bag.filter { $0.0.isAvailable && $0.0 != lastMoment }
        guard !bag.isEmpty else { return .idle }
        var roll = Int.random(in: 0..<bag.reduce(0) { $0 + $1.1 })
        for (clip, w) in bag {
            if roll < w { lastMoment = clip; return clip }
            roll -= w
        }
        return .idle
    }

    /// Replace the queued next clip, if there is still time to decode it; otherwise
    /// it plays after that one.
    private func queueNext(_ clip: FoxClip) {
        guard !fading else { pending = clip; return }
        let lane = lanes[live]
        let left = lane.remaining
        if left > 0.45 {
            lane.replaceQueued(with: item(clip))
        } else {
            pending = clip
        }
    }

    /// A held mood changed: let the next clip follow it.
    private func requeue() {
        guard running, !fading, !lanes.isEmpty else { return }
        let lane = lanes[live]
        if lane.remaining > 0.45 { lane.replaceQueued(with: item(nextClip(after: current))) }
    }

    private func crossFade(to clip: FoxClip) {
        guard !fading else { pending = clip; return }
        fading = true
        let incoming = lanes[1 - live]
        incoming.layer.removeAllAnimations()
        incoming.layer.opacity = Self.standby
        incoming.load([item(clip), item(nextClip(after: clip))])
        incoming.tagged = clip
        incoming.waitForFirstFrame()
        // Never hang on a lane that did not report its first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.fading, self.lanes[1 - self.live] === incoming else { return }
            self.ready(lane: 1 - self.live)
        }
    }

    /// The incoming lane has its first frame: play it and fade it in over the live one.
    private func ready(lane i: Int) {
        if !showing { showing = true; warmUp() }
        guard fading, i != live else { return }
        let incoming = lanes[i], outgoing = lanes[live]
        incoming.player.play()
        // Order by z, never by re-adding the layer (that rebuilds the video layer: a hitch).
        incoming.layer.zPosition = 1
        outgoing.layer.zPosition = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Self.standby
        fade.toValue = 1
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        incoming.layer.opacity = 1
        incoming.layer.add(fade, forKey: "in")
        live = i
        current = incoming.tagged ?? current
        #if DEBUG
        FrameMeter.mark("clip fade to \(current.rawValue)")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            self?.warm(outgoing)
            self?.fading = false
        }
    }

    /// The live lane moved on to its queued clip: queue the one after it.
    private func advanced(lane i: Int, to item: AVPlayerItem?) {
        guard i == live, running, let item, let clip = clipOf[ObjectIdentifier(item)] else { return }
        current = clip
        #if DEBUG
        FrameMeter.mark("clip \(clip.rawValue)")
        #endif
        if !fading { lanes[i].enqueue(self.item(nextClip(after: clip))) }
    }

    // MARK: Items

    private func asset(_ clip: FoxClip) -> AVURLAsset {
        if let a = assets[clip] { return a }
        let a = AVURLAsset(url: clip.url!, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[clip] = a
        return a
    }

    private var clipOf: [ObjectIdentifier: FoxClip] = [:]

    private func item(_ clip: FoxClip) -> AVPlayerItem {
        let clip = clip.resolved
        let item = AVPlayerItem(asset: asset(clip))
        item.preferredForwardBufferDuration = 1
        if clipOf.count > 64 { clipOf.removeAll() }
        clipOf[ObjectIdentifier(item)] = clip
        return item
    }
}

/// One player and its layer.
@MainActor
private final class Lane {
    let player = AVQueuePlayer()
    let layer: AVPlayerLayer
    var onAdvance: ((AVPlayerItem?) -> Void)?
    var onReady: (() -> Void)?
    var tagged: FoxClip?
    private var itemWatch: NSKeyValueObservation?
    private var readyWatch: NSKeyValueObservation?
    private var statusWatch: NSKeyValueObservation?
    /// Waiting to report the first frame of a freshly loaded clip.
    private var armed = false

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        itemWatch = player.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            let item = p.currentItem
            Task { @MainActor in self?.onAdvance?(item) }
        }
        readyWatch = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.checkReady() }
        }
    }

    private func checkReady() {
        guard armed, layer.isReadyForDisplay, player.currentItem?.status == .readyToPlay else { return }
        armed = false
        onReady?()
    }

    /// Seconds left in the current clip.
    var remaining: Double {
        guard let item = player.currentItem else { return 0 }
        let d = item.duration.seconds, t = item.currentTime().seconds
        return d.isFinite && t.isFinite ? d - t : 0
    }

    func load(_ items: [AVPlayerItem]) {
        player.removeAllItems()
        for i in items { player.insert(i, after: nil) }
        statusWatch = items.first?.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.checkReady() }
        }
        armed = true
    }

    func enqueue(_ item: AVPlayerItem) {
        // Keep exactly one clip waiting behind the current one.
        for queued in player.items().dropFirst() { player.remove(queued) }
        player.insert(item, after: nil)
    }

    func replaceQueued(with item: AVPlayerItem) { enqueue(item) }

    /// Call `onReady` when this lane's first frame is ready (at once if it already is).
    func waitForFirstFrame() {
        armed = true
        checkReady()
    }
}

/// The two player layers, stacked, filling the view.
final class FoxClipLayersView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ l: CALayer) { layer.addSublayer(l) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layer.sublayers ?? [] { l.frame = bounds }
        CATransaction.commit()
    }
}
