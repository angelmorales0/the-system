import Foundation

/// How the penalty screen rots the longer the penalty stays open. Pure math, so the view and the check share it.
/// Hours count from the time the penalty started (`PenaltyGroup.startedAtKey`).
///   0–1 h   gray only, creeping in from the edges
///   1–8 h   the edge of the gray turns dark red and pulses, faster as time goes on
///   1–4 h   a dim copy of every line grows under it
///   6–24 h  the outside blurs; the clear circle keeps closing in
/// Past 24 hours nothing gets worse.
enum PenaltyDecay {
    static let fullHours = 24.0
    /// Share of the screen radius still untouched: 1 when fresh, this at 24 hours.
    static let minClear = 0.28
    static let bloodStartHour = 1.0
    static let bloodFullHour = 8.0
    static let blurStartHour = 6.0
    static let maxBlur = 9.0
    static let ghostStartHour = 1.0
    static let ghostFullHour = 4.0
    static let maxGhost = 0.3
    static let slowBeat = 2.6
    static let fastBeat = 1.2

    /// Phrases the screen names as the threat. The quest day picks one, so a day reads the same all day.
    static let threats = ["Laziness", "Bad habits", "Neglect", "Weakness", "Complacency"]

    static func hours(since startedAt: Date, now: Date) -> Double {
        max(0, now.timeIntervalSince(startedAt) / 3600)
    }

    /// 1 → 0.28 over 24 hours, fast at first and then slower.
    static func clear(hours: Double) -> Double {
        let t = min(max(hours / fullHours, 0), 1)
        return 1 - (1 - minClear) * pow(t, 0.75)
    }

    /// 0 for the first hour, 1 from 8 hours on.
    static func blood(hours: Double) -> Double {
        min(max((hours - bloodStartHour) / (bloodFullHour - bloodStartHour), 0), 1)
    }

    /// Blur radius in points: 0 until 6 hours, 9 at 24 hours.
    static func blur(hours: Double) -> Double {
        min(max((hours - blurStartHour) / (fullHours - blurStartHour), 0), 1) * maxBlur
    }

    /// Opacity of the dim copy under each line: crisp for the first hour, the scene's double look from 4 hours on.
    static func ghost(hours: Double) -> Double {
        min(max((hours - ghostStartHour) / (ghostFullHour - ghostStartHour), 0), 1) * maxGhost
    }

    /// Seconds per pulse of the red edge. It quickens with the blood.
    static func beat(hours: Double) -> Double {
        slowBeat - (slowBeat - fastBeat) * blood(hours: hours)
    }

    static func threat(dayKey: String) -> String {
        let sum = dayKey.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return threats[sum % threats.count]
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        if !near(clear(hours: 0), 1) || !near(blood(hours: 0), 0) || !near(blur(hours: 0), 0) || !near(beat(hours: 0), slowBeat) {
            errors.append("a fresh penalty should show no decay")
        }
        if !near(blood(hours: 1), 0) || blood(hours: 1.5) <= 0 || !near(blood(hours: 8), 1) {
            errors.append("blood should start after the first hour and be full at 8")
        }
        if !near(ghost(hours: 1), 0) || ghost(hours: 2) <= 0 || !near(ghost(hours: 4), maxGhost) || !near(ghost(hours: 30), maxGhost) {
            errors.append("the ghost copy should grow from 1 to 4 hours and stop at \(maxGhost)")
        }
        if !near(blur(hours: 6), 0) || blur(hours: 7) <= 0 || !near(blur(hours: 24), maxBlur) {
            errors.append("blur should start after 6 hours and reach \(maxBlur) at 24")
        }
        if !near(clear(hours: 24), minClear) || !near(clear(hours: 48), minClear) || clear(hours: 1) >= clear(hours: 0) {
            errors.append("the clear circle should close to \(minClear) by 24 hours and stop there")
        }
        if !near(beat(hours: 8), fastBeat) || beat(hours: 4) >= slowBeat || beat(hours: 4) <= fastBeat {
            errors.append("the pulse should quicken with the blood")
        }
        let start = Date(timeIntervalSince1970: 1_000_000)
        if !near(hours(since: start, now: start.addingTimeInterval(5400)), 1.5) || !near(hours(since: start, now: start.addingTimeInterval(-60)), 0) {
            errors.append("hours should count from the start and never go negative")
        }
        if threat(dayKey: "2026-10-28") != threat(dayKey: "2026-10-28") || !threats.contains(threat(dayKey: "2026-10-29")) {
            errors.append("a day should always name the same threat from the list")
        }
        return errors
    }
}
