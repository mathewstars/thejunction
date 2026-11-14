import SwiftUI

/// Duolingo-style 3D button: a hard edge under the button; pressing pushes it down onto the edge.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color = Theme.brand
    var edge: Color = Theme.brandEdge
    var text: Color = .white
    /// A rim drawn on the face, so it moves down with the press (white buttons).
    var outline: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.rounded(16, .heavy))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
            .overlay {
                if let outline {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(outline, lineWidth: 2)
                }
            }
            .offset(y: pressed ? 5 : 0)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(edge).offset(y: 5))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// Same press feel for cards and tiles.
struct ChunkyCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 2))
            .offset(y: pressed ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.line).offset(y: 4))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}
