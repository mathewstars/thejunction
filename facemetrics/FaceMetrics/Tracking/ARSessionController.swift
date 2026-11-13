import Foundation
import ARKit

/// Lifecycle events the controller reports. Timestamps are wall-clock.
struct SessionLifecycleEvent: Identifiable {
    let id = UUID()
    let date: Date
    let kind: Kind
    let detail: String

    enum Kind: String, Codable {
        case configured, started, paused, interrupted, interruptionEnded, failed
        case cameraTrackingChanged, faceAnchorAdded, faceAnchorRemoved, formatChanged
    }
}

enum ARSessionRunState: String {
    case idle, starting, running, paused, interrupted, failed, unsupported
}

/// Describes one ARConfiguration.VideoFormat for the settings UI and the session manifest.
struct VideoFormatDescription: Identifiable, Equatable {
    let id: Int
    let width: Int
    let height: Int
    let framesPerSecond: Int
    var label: String { "\(width)x\(height) @ \(framesPerSecond) fps" }
}

/// Owns the ARSession and delivers every ARFrame to one sink on a dedicated serial queue.
/// Nothing here touches SwiftUI. All state changes are forwarded through `onLifecycleEvent`
/// and `onRunStateChanged`, which are invoked on the delegate queue.
final class ARSessionController: NSObject, ARSessionDelegate {

    let session = ARSession()
    let delegateQueue = DispatchQueue(label: "facemetrics.arsession", qos: .userInteractive)

    /// Called for every ARFrame on `delegateQueue`. The frame must not be retained by the sink.
    var frameSink: ((ARFrame) -> Void)?
    var onLifecycleEvent: ((SessionLifecycleEvent) -> Void)?
    var onRunStateChanged: ((ARSessionRunState) -> Void)?

    private(set) var runState: ARSessionRunState = .idle {
        didSet { if runState != oldValue { onRunStateChanged?(runState) } }
    }

    private let configLock = NSLock()
    private var _currentConfiguration: ARFaceTrackingConfiguration?
    /// Read from main and from the delegate queue, so it is lock-protected.
    private(set) var currentConfiguration: ARFaceTrackingConfiguration? {
        get { configLock.lock(); defer { configLock.unlock() }; return _currentConfiguration }
        set { configLock.lock(); _currentConfiguration = newValue; configLock.unlock() }
    }
    // Written and read only inside start(), which the view model calls from the main thread.
    private(set) var selectedFormatIndex: Int = 0
    private(set) var lightEstimationEnabled: Bool = true

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    static var supportedVideoFormats: [VideoFormatDescription] {
        ARFaceTrackingConfiguration.supportedVideoFormats.enumerated().map { index, format in
            VideoFormatDescription(
                id: index,
                width: Int(format.imageResolution.width),
                height: Int(format.imageResolution.height),
                framesPerSecond: format.framesPerSecond
            )
        }
    }

    static var supportedNumberOfTrackedFaces: Int { ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces }
    static var supportsWorldTracking: Bool { ARFaceTrackingConfiguration.supportsWorldTracking }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    /// Expected camera frame interval in seconds for the active configuration.
    var expectedFrameInterval: Double {
        let fps = currentConfiguration?.videoFormat.framesPerSecond ?? 60
        return fps > 0 ? 1.0 / Double(fps) : 1.0 / 60.0
    }

    // MARK: Lifecycle

    func start(formatIndex: Int? = nil, lightEstimation: Bool? = nil, resetTracking: Bool = true) {
        guard ARFaceTrackingConfiguration.isSupported else {
            delegateQueue.async {
                self.runState = .unsupported
                self.emit(.failed, "ARFaceTrackingConfiguration is not supported on this device")
            }
            return
        }
        if let formatIndex { selectedFormatIndex = formatIndex }
        if let lightEstimation { lightEstimationEnabled = lightEstimation }

        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = lightEstimationEnabled
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.worldAlignment = .gravity
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if formats.indices.contains(selectedFormatIndex) {
            configuration.videoFormat = formats[selectedFormatIndex]
        }
        currentConfiguration = configuration

        var options: ARSession.RunOptions = []
        if resetTracking { options.formUnion([.resetTracking, .removeExistingAnchors]) }

        delegateQueue.async {
            self.runState = .starting
            self.emit(.configured, "format \(Int(configuration.videoFormat.imageResolution.width))x\(Int(configuration.videoFormat.imageResolution.height)) @ \(configuration.videoFormat.framesPerSecond) fps, light estimation \(configuration.isLightEstimationEnabled ? "on" : "off")")
        }
        session.run(configuration, options: options)
        delegateQueue.async {
            self.runState = .running
            self.emit(.started, "session running")
        }
    }

    func pause() {
        session.pause()
        delegateQueue.async {
            self.runState = .paused
            self.emit(.paused, "session paused by app")
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameSink?(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARFaceAnchor {
            emit(.faceAnchorAdded, "face anchor \(anchor.identifier.uuidString.prefix(8))")
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARFaceAnchor {
            emit(.faceAnchorRemoved, "face anchor \(anchor.identifier.uuidString.prefix(8))")
        }
    }

    // MARK: ARSessionObserver

    func session(_ session: ARSession, didFailWithError error: Error) {
        runState = .failed
        emit(.failed, error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        runState = .interrupted
        emit(.interrupted, "session interrupted (app backgrounded or camera taken by another client)")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        runState = .running
        emit(.interruptionEnded, "interruption ended")
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        emit(.cameraTrackingChanged, ARSessionController.describe(camera.trackingState))
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }

    // MARK: Helpers

    private func emit(_ kind: SessionLifecycleEvent.Kind, _ detail: String) {
        onLifecycleEvent?(SessionLifecycleEvent(date: Date(), kind: kind, detail: detail))
    }

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable: return "notAvailable"
        case .normal: return "normal"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited: initializing"
            case .excessiveMotion: return "limited: excessive motion"
            case .insufficientFeatures: return "limited: insufficient features"
            case .relocalizing: return "limited: relocalizing"
            @unknown default: return "limited: unknown"
            }
        @unknown default: return "unknown"
        }
    }

    static func code(for state: ARCamera.TrackingState) -> (CameraTrackingStateCode, String?) {
        switch state {
        case .notAvailable: return (.notAvailable, nil)
        case .normal: return (.normal, nil)
        case .limited(let reason):
            let text: String
            switch reason {
            case .initializing: text = "initializing"
            case .excessiveMotion: text = "excessiveMotion"
            case .insufficientFeatures: text = "insufficientFeatures"
            case .relocalizing: text = "relocalizing"
            @unknown default: text = "unknown"
            }
            return (.limited, text)
        @unknown default: return (.notAvailable, "unknown")
        }
    }
}
