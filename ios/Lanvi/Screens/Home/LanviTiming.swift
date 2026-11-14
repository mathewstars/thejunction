import SwiftUI

/// One timing family for the whole app, so everything moves alike.
/// Nothing linear: screens and sheets settle with a calm spring, presses are quick.
enum LanviTiming {
    /// Screens, steps of the first run, overlays arriving and leaving.
    static let screen = Animation.spring(response: 0.45, dampingFraction: 0.85)
    /// Small things appearing (a message, a pill, a line of text).
    static let pop = Animation.spring(response: 0.35, dampingFraction: 0.75)
    /// Content swapping in place (a button row, a label).
    static let swap = Animation.easeInOut(duration: 0.22)
    /// Presses.
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.75)

    /// How a step or a screen arrives: it rises a little and fades in; it leaves by fading.
    static var arrive: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity)
    }
}
