import SwiftUI

// MARK: - Panel

struct InstrumentPanel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Readout

struct Readout: View {
    let label: String
    let value: String
    var unit: String? = nil
    var color: Color = Theme.textPrimary
    var large: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(large ? .title2.weight(.medium) : .callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grid of readouts, two or three per row.
struct ReadoutGrid: View {
    let items: [(label: String, value: String, unit: String?)]
    var columns: Int = 3

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: columns)
        LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Readout(label: item.label, value: item.value, unit: item.unit)
            }
        }
    }
}

// MARK: - Status lamp

struct StatusLamp: View {
    let color: Color
    let label: String
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: pulsing ? 4 : 0))
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Bars

/// 0...1 level bar with a thin track.
struct LevelBar: View {
    let value: Float
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelRaised)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, CGFloat(value.isFinite ? value : 0))) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// -1...1 bar growing from the centre: left side in the left channel colour, right side in the right colour.
struct SignedBar: View {
    let value: Float
    var range: Float = 1
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let v = value.isFinite ? max(-range, min(range, value)) / range : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelRaised)
                Rectangle().fill(Theme.border).frame(width: 1).offset(x: w / 2)
                let barWidth = abs(CGFloat(v)) * w / 2
                RoundedRectangle(cornerRadius: 2)
                    .fill(v >= 0 ? Theme.left : Theme.right)
                    .frame(width: barWidth)
                    .offset(x: v >= 0 ? w / 2 : w / 2 - barWidth)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Float]
    var color: Color = Theme.accent
    var range: ClosedRange<Float>? = nil
    var fill: Bool = true

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo: Float, hi: Float
            if let range { lo = range.lowerBound; hi = range.upperBound }
            else {
                let mn = values.min() ?? 0, mx = values.max() ?? 1
                let pad = max((mx - mn) * 0.1, 1e-4)
                lo = mn - pad; hi = mx + pad
            }
            let span = max(hi - lo, 1e-6)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat((min(max(v, lo), hi) - lo) / span))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            if fill {
                var area = path
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.12)))
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}

// MARK: - Line chart

struct ChartSeries: Identifiable {
    let id: String
    let values: [Float]
    let color: Color
    var label: String { id }
}

/// Multi-trace line chart with horizontal grid lines, min/max labels and a legend.
struct LineChartView: View {
    let series: [ChartSeries]
    var yRange: ClosedRange<Float>? = nil
    var zeroLine: Bool = false
    var unit: String = ""
    var height: CGFloat = 120
    var decimals: Int = 2

    private var resolvedRange: ClosedRange<Float> {
        if let yRange { return yRange }
        let all = series.flatMap { $0.values }.filter { $0.isFinite }
        guard let mn = all.min(), let mx = all.max() else { return 0...1 }
        let pad = max((mx - mn) * 0.12, 1e-3)
        return (mn - pad)...(mx + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let range = resolvedRange
                    let span = max(range.upperBound - range.lowerBound, 1e-6)
                    func yFor(_ v: Float) -> CGFloat {
                        size.height * (1 - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span))
                    }
                    // grid
                    for i in 0...4 {
                        let y = size.height * CGFloat(i) / 4
                        var g = Path()
                        g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(g, with: .color(Theme.grid), style: StrokeStyle(lineWidth: 0.5, dash: i == 0 || i == 4 ? [] : [3, 4]))
                    }
                    if zeroLine, range.contains(0) {
                        var z = Path()
                        let y = yFor(0)
                        z.move(to: CGPoint(x: 0, y: y)); z.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(z, with: .color(Theme.textTertiary), lineWidth: 0.8)
                    }
                    let maxCount = series.map { $0.values.count }.max() ?? 0
                    guard maxCount > 1 else { return }
                    for s in series {
                        guard s.values.count > 1 else { continue }
                        var p = Path()
                        var started = false
                        // Right-align shorter series so the newest sample sits at the right edge.
                        let offset = maxCount - s.values.count
                        for (i, v) in s.values.enumerated() {
                            guard v.isFinite else { started = false; continue }
                            let x = size.width * CGFloat(i + offset) / CGFloat(maxCount - 1)
                            let pt = CGPoint(x: x, y: yFor(v))
                            if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                        }
                        ctx.stroke(p, with: .color(s.color), lineWidth: 1.4)
                    }
                }
                .frame(height: height)
                VStack {
                    Text(axisLabel(resolvedRange.upperBound))
                    Spacer()
                    Text(axisLabel(resolvedRange.lowerBound))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 2)
                .frame(height: height)
            }
            if series.count > 1 || !series.isEmpty {
                HStack(spacing: 12) {
                    ForEach(series) { s in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 10, height: 2)
                            Text(s.label).font(.caption2).foregroundStyle(Theme.textSecondary)
                            if let last = s.values.last(where: { $0.isFinite }) {
                                Text(String(format: "%.\(decimals)f", last))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func axisLabel(_ v: Float) -> String {
        String(format: "%.\(decimals)f\(unit)", v)
    }
}

// MARK: - Head attitude indicator

/// Shows yaw/pitch as a dot on a cross-hair and roll as the tilt of the horizon line.
struct AttitudeIndicator: View {
    let pitch: Float   // radians
    let yaw: Float
    let roll: Float
    var maxAngle: Float = 0.6   // radians to the edge

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var ring = Path()
            ring.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(ring, with: .color(Theme.border), lineWidth: 1)
            var inner = Path()
            inner.addEllipse(in: CGRect(x: c.x - r / 2, y: c.y - r / 2, width: r, height: r))
            ctx.stroke(inner, with: .color(Theme.grid), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(cross, with: .color(Theme.grid), lineWidth: 0.5)

            // Horizon tilted by roll
            let hl = r * 0.8
            let cr = CGFloat(cos(roll)), sr = CGFloat(sin(roll))
            var horizon = Path()
            horizon.move(to: CGPoint(x: c.x - hl * cr, y: c.y + hl * sr))
            horizon.addLine(to: CGPoint(x: c.x + hl * cr, y: c.y - hl * sr))
            ctx.stroke(horizon, with: .color(Theme.trace3), lineWidth: 1.2)

            // Dot for yaw (x) and pitch (y)
            let nx = CGFloat(max(-1, min(1, yaw / maxAngle)))
            let ny = CGFloat(max(-1, min(1, pitch / maxAngle)))
            let dot = CGPoint(x: c.x + nx * r, y: c.y - ny * r)
            var d = Path()
            d.addEllipse(in: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10))
            ctx.fill(d, with: .color(Theme.accent))
        }
    }
}

// MARK: - Chip

struct Chip: View {
    let label: String
    let selected: Bool
    var color: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.background : Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? color : Theme.panelRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? color : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons

struct InstrumentButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? Theme.background : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(prominent ? tint : Theme.panelRaised)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(prominent ? tint : tint.opacity(0.45), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SectionNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
