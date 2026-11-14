import SwiftUI

// Every helper here is prefixed with `Checkin` so it never clashes with the other screens' helpers.

/// Evening colours: the same sky, a little darker and quieter.
enum CheckinEvening {
    static let top = Color(hex: 0x0A1442)
    static let bottom = Color(hex: 0x2D4C9E)
    static let moon = Color(hex: 0xFFF3D2)
    static let skyText = Color(hex: 0xC9D7FF)   // secondary text on the sky
    static let chipEdge = Color(hex: 0xA9BBEA)  // 3D edge of a white chip on the night sky
    static let pressedFill = Color(hex: 0xDCE6FF)
}

/// The evening sky: Lanvi's usual sky scene, darker, with a glowing crescent moon when there is room for it.
struct CheckinEveningSky: View {
    var hillTop: CGFloat
    var showMoon: Bool = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SkyScene(top: CheckinEvening.top, bottom: CheckinEvening.bottom, hillTop: hillTop)
            CheckinMoon()
                .padding(.top, 84)
                .padding(.trailing, 22)
                .ignoresSafeArea()
                .opacity(showMoon ? 1 : 0)
                .scaleEffect(showMoon ? 1 : 0.85)
                .animation(.easeInOut(duration: 0.6), value: showMoon)
                .allowsHitTesting(false)
        }
    }
}

/// A crescent moon made of light: a wide breathing halo, a soft glow, and a crisp shaded crescent.
struct CheckinMoon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 1 + 0.05 * sin(t * 2 * .pi / 6)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [CheckinEvening.moon.opacity(0.16), CheckinEvening.moon.opacity(0.05), .clear],
                                         center: .center, startRadius: 18, endRadius: 80))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse)
                    .blendMode(.plusLighter)
                crescent
                    .fill(CheckinEvening.moon.opacity(0.7))
                    .blur(radius: 7)
                    .blendMode(.plusLighter)
                crescent
                    .fill(LinearGradient(colors: [.white, CheckinEvening.moon, Color(hex: 0xE9D19A)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(crescent.stroke(.white.opacity(0.6), lineWidth: 0.5))
            }
            .frame(width: 160, height: 160)
        }
    }

    private var crescent: CheckinCrescent { CheckinCrescent() }
}

/// A crescent: a disc with a bigger offset disc cut out of its upper right.
struct CheckinCrescent: Shape {
    func path(in rect: CGRect) -> Path {
        let d: CGFloat = 46
        let outer = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        let cut = outer.insetBy(dx: 2, dy: 2).offsetBy(dx: 15, dy: -11)
        return Path(ellipseIn: outer).subtracting(Path(ellipseIn: cut))
    }
}

/// One mote of light: a wide faint halo, a brighter glow and a white-hot core, added onto what is behind.
struct CheckinMote: View {
    var size: CGFloat
    var color: Color = Theme.aurora

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.55), color.opacity(0.15), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 1.5))
                .frame(width: size * 3, height: size * 3)
            Circle()
                .fill(RadialGradient(colors: [.white, color, color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * 0.5))
                .frame(width: size, height: size)
            Circle()
                .fill(.white)
                .frame(width: size * 0.2, height: size * 0.2)
                .blur(radius: size * 0.04)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// A chunky chip on the night sky. Not picked: white, raised on a 3D edge.
/// Picked: pressed down flat, blue rim, check mark, soft aurora glow around it.
struct CheckinChipStyle: ButtonStyle {
    var selected: Bool
    var dimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let down = selected || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .font(Theme.rounded(16, .bold))
            .foregroundStyle(selected ? Theme.brandEdge : Theme.ink)
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(shape.fill(selected ? CheckinEvening.pressedFill : .white))
            .overlay {
                // Inner shadow along the top so a picked chip reads as sunk in.
                shape.stroke(Theme.brandEdge.opacity(selected ? 0.28 : 0), lineWidth: 5)
                    .blur(radius: 2.5)
                    .offset(y: 2)
                    .mask(shape)
            }
            .overlay(shape.stroke(selected ? Theme.brand : .clear, lineWidth: 2.5))
            .shadow(color: Theme.glow.opacity(selected ? 0.75 : 0), radius: 10)
            .offset(y: down ? 4 : 0)
            .background(shape.fill(selected ? Theme.brandEdge : CheckinEvening.chipEdge).offset(y: 4))
            .opacity(dimmed ? 0.62 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: down)
            .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

/// The "Write my own" chip: see-through on the sky with a dashed white rim, same chunky press.
struct CheckinAddChipStyle: ButtonStyle {
    var dimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .font(Theme.rounded(16, .heavy))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(shape.fill(.white.opacity(pressed ? 0.24 : 0.14)))
            .overlay(shape.strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            .offset(y: pressed ? 4 : 0)
            .background(shape.fill(.white.opacity(0.10)).offset(y: 4))
            .opacity(dimmed ? 0.45 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: pressed)
    }
}

/// Secondary chunky button: white with a blue label, same 3D press.
struct CheckinQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .font(Theme.rounded(16, .heavy))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.brand)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(shape.fill(.white))
            .overlay(shape.stroke(Theme.line, lineWidth: 2))
            .offset(y: pressed ? 5 : 0)
            .background(shape.fill(Theme.line).offset(y: 5))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { wasDown, isDown in isDown && !wasDown }
    }
}

/// The chunky round blue close button, top-left.
struct CheckinCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
        }
        .buttonStyle(RoundChunkyStyle())
        .accessibilityLabel("Leave the check-in")
    }

    private struct RoundChunkyStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            configuration.label
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.brand))
                .overlay(alignment: .top) {
                    Capsule().fill(.white.opacity(0.28)).frame(width: 18, height: 5).padding(.top, 6)
                }
                .offset(y: pressed ? 4 : 0)
                .background(Circle().fill(Theme.brandEdge).offset(y: 4))
                .contentShape(Circle())
                .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
                .sensoryFeedback(.impact(weight: .light), trigger: pressed) { wasDown, isDown in isDown && !wasDown }
        }
    }
}

/// Chips that wrap onto the next line, left aligned.
struct CheckinFlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .init(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.init(width: width, height: nil))
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Three slots in a little night-sky tray. Each good thing lights one with a breathing mote.
struct CheckinSparkTray: View {
    var count: Int
    var total: Int = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ForEach(0..<total, id: \.self) { i in
                    let lit = i < count
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                                 center: .center, startRadius: 0, endRadius: 5))
                            .frame(width: 9, height: 9)
                        if lit {
                            CheckinMote(size: 15, color: i == 1 ? Theme.auroraViolet : Theme.aurora)
                                .scaleEffect(1 + 0.08 * sin(t * 2.4 + Double(i)))
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(hex: 0x081039), Color(hex: 0x182C78)],
                                              startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: count)
        .accessibilityElement()
        .accessibilityLabel("\(count) of \(total) picked")
    }
}

/// Chunky progress bar for the steps: a sunk track and a glowing aurora fill with a gloss line.
struct CheckinProgress: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0x07103A).opacity(0.55))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1.5))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.aurora, Theme.glow, Theme.auroraViolet],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.55)).frame(height: 4).padding(.horizontal, 7).padding(.top, 3)
                    }
                    .frame(width: max(18, geo.size.width * progress))
                    .shadow(color: Theme.aurora.opacity(0.7), radius: 8)
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: progress)
    }
}
