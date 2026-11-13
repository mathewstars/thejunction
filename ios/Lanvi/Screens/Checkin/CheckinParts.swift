import SwiftUI

/// Evening colours: the same sky, a little darker and quieter.
enum EveningTheme {
    static let top = Color(hex: 0x0B1546)
    static let bottom = Color(hex: 0x3253A8)
    static let moon = Color(hex: 0xFFF4D6)
}

/// The evening sky: Lanvi's usual sky scene, darker, with a soft crescent moon.
struct EveningSky: View {
    var hillTop: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SkyScene(top: EveningTheme.top, bottom: EveningTheme.bottom, hillTop: hillTop)
            Moon()
                .padding(.top, 70)
                .padding(.trailing, 38)
                .ignoresSafeArea()
        }
    }
}

private struct Moon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(EveningTheme.moon.opacity(0.22))
                .frame(width: 86, height: 86)
                .blur(radius: 16)
            Circle()
                .fill(EveningTheme.moon)
                .frame(width: 40, height: 40)
                .mask {
                    Rectangle()
                        .overlay(Circle().frame(width: 36, height: 36).offset(x: 13, y: -9).blendMode(.destinationOut))
                        .compositingGroup()
                }
                .rotationEffect(.degrees(-10))
        }
        .allowsHitTesting(false)
    }
}

/// A chunky chip. Not picked: raised on a 3D edge. Picked: pressed down into the snow, blue rim, check mark.
struct CheckinChipStyle: ButtonStyle {
    var selected: Bool
    var dimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let down = selected || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .font(Theme.rounded(16, .bold))
            .foregroundStyle(selected ? Theme.brandEdge : Theme.ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 15)
            .background(shape.fill(selected ? Theme.tint : .white))
            .overlay {
                // Inner shadow at the top edge so a picked chip reads as sunk in.
                shape.stroke(Theme.brandEdge.opacity(selected ? 0.22 : 0), lineWidth: 4)
                    .blur(radius: 2)
                    .offset(y: 1.5)
                    .mask(shape)
            }
            .overlay(shape.stroke(selected ? Theme.brand : Theme.line, lineWidth: 2))
            .offset(y: down ? 4 : 0)
            .background(shape.fill(selected ? Theme.brand.opacity(0.35) : Theme.line).offset(y: 4))
            .opacity(dimmed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed && !selected ? 0.98 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: down)
            .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

/// Secondary chunky button: white with an ink label, same 3D press.
struct ChunkyQuietButtonStyle: ButtonStyle {
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
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// Chips that wrap onto the next line, left aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
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
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
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

/// Three little sparks that light up as good things are picked.
struct SparkCounter: View {
    var count: Int
    var total: Int = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                let lit = i < count
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(lit ? Theme.brand : Theme.line)
                    .shadow(color: lit ? Theme.glow : .clear, radius: 6)
                    .scaleEffect(lit ? 1.15 : 0.9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.45), value: lit)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(count) of \(total) picked")
    }
}

/// Chunky progress bar for the steps, with a glossy highlight like the buttons.
struct StepProgress: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(Theme.glow)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.45)).frame(height: 4).padding(.horizontal, 8).padding(.top, 3)
                    }
                    .frame(width: max(16, geo.size.width * progress))
                    .shadow(color: Theme.glow.opacity(0.7), radius: 8)
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: progress)
    }
}

/// Small round icon button on the sky (close).
struct SkyIconButton: View {
    var icon: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
