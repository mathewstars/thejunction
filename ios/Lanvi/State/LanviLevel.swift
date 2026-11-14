import Foundation

/// Levels, worked out on the phone from the XP total the server already sends.
/// They sit beside the three growth stages (kit, young fox, grown fox), which stay
/// exactly as the server says.
///
/// Level 1 starts at 0 XP. Level 1 to 2 takes 30 XP (about three activities); each
/// level after asks 5 XP more, never more than 100.
struct LanviLevel: Equatable {
    /// The level, from 1.
    let level: Int
    /// XP gathered inside this level.
    let into: Int
    /// XP this level takes in all.
    let needed: Int

    /// XP still to go to the next level.
    var toNext: Int { needed - into }
    /// 0...1 along this level.
    var progress: Double { needed > 0 ? Double(into) / Double(needed) : 0 }

    /// XP that level `n` takes to finish (`n` from 1).
    static func needed(for n: Int) -> Int { min(30 + 5 * (max(n, 1) - 1), 100) }

    /// The XP total at which level `n` begins.
    static func start(of n: Int) -> Int {
        guard n > 1 else { return 0 }
        return (1..<n).reduce(0) { $0 + needed(for: $1) }
    }
}

extension LanviLevel {
    /// XP total -> level, XP into it, XP it needs.
    init(xp: Int) {
        var left = max(xp, 0)
        var n = 1
        while left >= Self.needed(for: n) {
            left -= Self.needed(for: n)
            n += 1
        }
        level = n
        into = left
        needed = Self.needed(for: n)
    }
}
