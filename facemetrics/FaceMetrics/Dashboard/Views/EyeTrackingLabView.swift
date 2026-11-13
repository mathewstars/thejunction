import SwiftUI
import simd

struct EyeTrackingLabView: View {
    @EnvironmentObject var model: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                gazePanel
                eyeDirectionPanel
                blinkPanel
                eyeCoefficientsPanel
            }
            .padding(14)
        }
    }

    private var gazePanel: some View {
        let e = model.snapshot.eyes?.reading
        let m = model.snapshot.eyes?.metrics
        return InstrumentPanel("Gaze relative to the camera", subtitle: "derived from lookAtPoint") {
            VStack(spacing: 10) {
                GazeTargetView(hit: e?.gazePlaneHit, gazeYaw: e?.gazeYawDegrees, gazePitch: e?.gazePitchDegrees)
                    .frame(height: 200)
                ReadoutGrid(items: [
                    ("Gaze yaw", Fmt.degValue(e?.gazeYawDegrees), nil),
                    ("Gaze pitch", Fmt.degValue(e?.gazePitchDegrees), nil),
                    ("L/R divergence", Fmt.degValue(e?.leftRightDivergenceDegrees), nil),
                    ("Plane hit X", Fmt.mm(e?.gazePlaneHit?.x), nil),
                    ("Plane hit Y", Fmt.mm(e?.gazePlaneHit?.y), nil),
                    ("Gaze speed", Fmt.f(e?.gazeAngularSpeed, 0), "°/s"),
                    ("Gaze variability", Fmt.f(m?.gazeVariabilityDegrees, 2), "° std"),
                    ("Eye movement", Fmt.f(m?.eyeMovementDegPerSecond, 1), "°/s"),
                    ("Look-at Z", Fmt.mm(e?.lookAtPointAnchor.z), nil)
                ])
                SectionNote(text: "ARKit provides per-eye transforms and one lookAtPoint. It does not track pupils and is not calibrated to the screen. The plane hit is where the gaze ray crosses the camera plane; expect several centimetres of error. 0° means looking at the camera.")
            }
        }
    }

    private var eyeDirectionPanel: some View {
        let e = model.snapshot.eyes?.reading
        let snap = model.snapshot.eyes
        return InstrumentPanel("Eye transforms", subtitle: "leftEyeTransform / rightEyeTransform") {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    EyeDial(title: "Left eye", yaw: e?.leftYawDegrees, pitch: e?.leftPitchDegrees, color: Theme.left)
                    EyeDial(title: "Right eye", yaw: e?.rightYawDegrees, pitch: e?.rightPitchDegrees, color: Theme.right)
                }
                ReadoutGrid(items: [
                    ("Left pos X", Fmt.mm(e?.leftPosition.x), nil),
                    ("Left pos Y", Fmt.mm(e?.leftPosition.y), nil),
                    ("Left pos Z", Fmt.mm(e?.leftPosition.z), nil),
                    ("Right pos X", Fmt.mm(e?.rightPosition.x), nil),
                    ("Right pos Y", Fmt.mm(e?.rightPosition.y), nil),
                    ("Right pos Z", Fmt.mm(e?.rightPosition.z), nil),
                    ("Left pitch/yaw", "\(Fmt.deg(e?.leftEulerAnchor.x, 0)) \(Fmt.deg(e?.leftEulerAnchor.y, 0))", nil),
                    ("Right pitch/yaw", "\(Fmt.deg(e?.rightEulerAnchor.x, 0)) \(Fmt.deg(e?.rightEulerAnchor.y, 0))", nil),
                    ("Interocular", e.map { Fmt.mm(simd_length($0.leftPosition - $0.rightPosition)) } ?? "—", nil)
                ])
                LineChartView(series: [
                    ChartSeries(id: "gaze yaw", values: snap?.gazeYawHistory ?? [], color: Theme.accent),
                    ChartSeries(id: "gaze pitch", values: snap?.gazePitchHistory ?? [], color: Theme.trace3)
                ], zeroLine: true, unit: "°", height: 100, decimals: 1)
                SectionNote(text: "Positions are in face-anchor space, metres. The forward direction of each eye is the +Z axis of its transform, the same convention as the face anchor.")
            }
        }
    }

    private var blinkPanel: some View {
        let b = model.snapshot.blink
        let s = b?.statistics
        return InstrumentPanel("Blink detection", subtitle: "eyeBlink_L / eyeBlink_R with hysteresis") {
            VStack(alignment: .leading, spacing: 10) {
                LineChartView(series: [
                    ChartSeries(id: "eyeBlink_L", values: b?.leftBlinkHistory ?? [], color: Theme.left),
                    ChartSeries(id: "eyeBlink_R", values: b?.rightBlinkHistory ?? [], color: Theme.right)
                ], yRange: 0...1, height: 90, decimals: 2)
                HStack {
                    StatusLamp(color: s?.blinkInProgress == true ? Theme.accent : Theme.textTertiary, label: s?.blinkInProgress == true ? "Eyes closing" : "Eyes open")
                    Spacer()
                    Text("onset ≥ \(Fmt.f(model.blinkConfig.onsetThreshold, 2)), offset ≤ \(Fmt.f(model.blinkConfig.offsetThreshold, 2))")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                ReadoutGrid(items: [
                    ("Blinks", Fmt.int(s?.totalBlinks), nil),
                    ("Long closures", Fmt.int(s?.totalClosures), nil),
                    ("Rate", Fmt.f(s?.ratePerMinute, 1), "/min"),
                    ("Mean duration", Fmt.ms(s?.meanDuration), nil),
                    ("Mean interval", Fmt.f(s?.meanInterBlinkInterval, 2), "s"),
                    ("Interval CV", Fmt.f(s?.interBlinkIntervalCV, 2), nil),
                    ("Clustered", Fmt.int(s?.clusteredBlinkCount), "< \(Fmt.f(model.blinkConfig.clusterInterval, 1)) s"),
                    ("Peak asym. L−R", Fmt.signed(s?.meanPeakAsymmetry, 2), nil),
                    ("Openness std", Fmt.f(s?.opennessVariability, 3), nil)
                ])
                if let events = b?.recentEvents, !events.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent events").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(events.suffix(8).reversed()) { ev in
                            HStack(spacing: 8) {
                                Text(ev.kind).font(.caption2.weight(.semibold)).foregroundStyle(ev.kind == "blink" ? Theme.accent : Theme.warn).frame(width: 46, alignment: .leading)
                                Text(Fmt.ms(ev.duration)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textPrimary).frame(width: 56, alignment: .leading)
                                Text("L \(Fmt.f(ev.peakLeft, 2))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.left)
                                Text("R \(Fmt.f(ev.peakRight, 2))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.right)
                                if let lag = ev.onsetLag { Text("lag \(Fmt.ms(lag))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                                Spacer()
                                if let ibi = ev.interBlinkInterval { Text("+\(Fmt.f(ibi, 2)) s").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var eyeCoefficientsPanel: some View {
        let eyes = model.snapshot.coefficients.filter { $0.category == .eyes }
        return InstrumentPanel("Eye coefficients", subtitle: "\(eyes.count) raw values") {
            VStack(spacing: 6) {
                ForEach(eyes) { c in
                    HStack(spacing: 8) {
                        Text(c.name).font(.caption).foregroundStyle(Theme.textPrimary).frame(width: 130, alignment: .leading)
                        LevelBar(value: c.value, color: Theme.channel(c.side), height: 5)
                        Text(Fmt.f(c.value, 2)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Draws the device plane as seen from the participant: camera at the top centre, gaze hit as a dot.
struct GazeTargetView: View {
    let hit: SIMD2<Float>?
    let gazeYaw: Float?
    let gazePitch: Float?
    /// Half-width of the drawn plane in metres.
    var extent: Float = 0.15

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // Grid in 5 cm steps
            let scale = CGFloat(min(Float(w), Float(h)) / (2 * extent))
            let c = CGPoint(x: w / 2, y: h * 0.25)
            var grid = Path()
            var step: Float = -0.3
            while step <= 0.3 {
                let x = c.x + CGFloat(step) * scale
                let y = c.y - CGFloat(step) * scale
                if x >= 0, x <= w { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: h)) }
                if y >= 0, y <= h { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y)) }
                step += 0.05
            }
            ctx.stroke(grid, with: .color(Theme.grid), lineWidth: 0.5)
            // Camera marker
            var cam = Path()
            cam.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            ctx.stroke(cam, with: .color(Theme.textSecondary), lineWidth: 1.2)
            ctx.draw(Text("camera").font(.system(size: 9)).foregroundColor(Theme.textTertiary), at: CGPoint(x: c.x + 28, y: c.y))
            // Hit point
            if let hit {
                let p = CGPoint(x: c.x + CGFloat(hit.x) * scale, y: c.y - CGFloat(hit.y) * scale)
                let clamped = CGPoint(x: min(max(p.x, 6), w - 6), y: min(max(p.y, 6), h - 6))
                var line = Path()
                line.move(to: c); line.addLine(to: clamped)
                ctx.stroke(line, with: .color(Theme.accent.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var dot = Path()
                dot.addEllipse(in: CGRect(x: clamped.x - 6, y: clamped.y - 6, width: 12, height: 12))
                ctx.fill(dot, with: .color(Theme.accent))
                if clamped != p {
                    ctx.draw(Text("off chart").font(.system(size: 9)).foregroundColor(Theme.warn), at: CGPoint(x: clamped.x, y: clamped.y + 14))
                }
            } else {
                ctx.draw(Text(gazeYaw == nil ? "no eye data" : "gaze points away from the camera").font(.system(size: 10)).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: w / 2, y: h * 0.6))
            }
        }
        .background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EyeDial: View {
    let title: String
    let yaw: Float?
    let pitch: Float?
    let color: Color
    var maxDegrees: Float = 30

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2 - 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var ring = Path(); ring.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.stroke(ring, with: .color(Theme.border), lineWidth: 1)
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
                ctx.stroke(cross, with: .color(Theme.grid), lineWidth: 0.5)
                guard let yaw, let pitch else { return }
                let nx = CGFloat(max(-1, min(1, yaw / maxDegrees)))
                let ny = CGFloat(max(-1, min(1, pitch / maxDegrees)))
                let p = CGPoint(x: c.x + nx * r, y: c.y - ny * r)
                var line = Path(); line.move(to: c); line.addLine(to: p)
                ctx.stroke(line, with: .color(color.opacity(0.6)), lineWidth: 1)
                var dot = Path(); dot.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                ctx.fill(dot, with: .color(color))
            }
            .frame(height: 90)
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text("\(Fmt.degValue(yaw, 0)) / \(Fmt.degValue(pitch, 0))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }
}
