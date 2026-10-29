import Foundation

/// How the penalty screen rots the longer the penalty stays open. Pure math, so the view and the check share it.
/// Hours count from the time the penalty started (`PenaltyGroup.startedAtKey`).
///   0–1 h     gray only, creeping in from the edges
///   0.5–2 h   a dim copy of every line grows under it
///   1–4 h     the edge of the gray turns dark red and pulses, faster as time goes on
///   3–12 h    the outside blurs; the clear circle keeps closing in
/// Past 12 hours nothing gets worse.
enum PenaltyDecay {
    static let fullHours = 12.0
    /// Share of the screen radius still untouched: 1 when fresh, this at 12 hours.
    static let minClear = 0.28
    static let bloodStartHour = 1.0
    static let bloodFullHour = 4.0
    static let blurStartHour = 3.0
    static let maxBlur = 9.0
    static let ghostStartHour = 0.5
    static let ghostFullHour = 2.0
    static let maxGhost = 0.3
    static let slowBeat = 2.6
    static let fastBeat = 1.2

    /// Faults the screen names when the generator wrote no line. The quest day picks one, so a day reads the same all day.
    static let threats = ["Laziness", "Bad habits", "Neglect", "Weakness", "Complacency"]
    static let threatEnding = "Run 10 km and ensure your safety."
    static let threatMaxCharacters = 160

    /// The screen's two sentences: the generator's line when it kept the System's voice, else the app's own.
    static func threatLine(generated: String?, dayKey: String) -> String {
        if let text = generated?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           text.count <= threatMaxCharacters, text.hasSuffix(threatEnding), text.count > threatEnding.count,
           !text.lowercased().contains("penalty"), text.lowercased().contains("player"), !text.contains("!") {
            return text
        }
        return "\(threat(dayKey: dayKey)) is present and is damaging the Player. \(threatEnding)"
    }

    static func hours(since startedAt: Date, now: Date) -> Double {
        max(0, now.timeIntervalSince(startedAt) / 3600)
    }

    /// 1 → 0.28 over 12 hours, fast at first and then slower.
    static func clear(hours: Double) -> Double {
        let t = min(max(hours / fullHours, 0), 1)
        return 1 - (1 - minClear) * pow(t, 0.75)
    }

    /// 0 for the first hour, 1 from 4 hours on.
    static func blood(hours: Double) -> Double {
        min(max((hours - bloodStartHour) / (bloodFullHour - bloodStartHour), 0), 1)
    }

    /// Blur radius in points: 0 until 3 hours, 9 at 12 hours.
    static func blur(hours: Double) -> Double {
        min(max((hours - blurStartHour) / (fullHours - blurStartHour), 0), 1) * maxBlur
    }

    /// Opacity of the dim copy under each line: crisp for the first half hour, the scene's double look from 2 hours on.
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
        if !near(blood(hours: 1), 0) || blood(hours: 1.5) <= 0 || !near(blood(hours: 4), 1) {
            errors.append("blood should start after the first hour and be full at 4")
        }
        if !near(ghost(hours: 0.5), 0) || ghost(hours: 1) <= 0 || !near(ghost(hours: 2), maxGhost) || !near(ghost(hours: 30), maxGhost) {
            errors.append("the ghost copy should grow from 0.5 to 2 hours and stop at \(maxGhost)")
        }
        if !near(blur(hours: 3), 0) || blur(hours: 4) <= 0 || !near(blur(hours: 12), maxBlur) {
            errors.append("blur should start after 3 hours and reach \(maxBlur) at 12")
        }
        if !near(clear(hours: 12), minClear) || !near(clear(hours: 48), minClear) || clear(hours: 1) >= clear(hours: 0) {
            errors.append("the clear circle should close to \(minClear) by 12 hours and stop there")
        }
        if !near(beat(hours: 4), fastBeat) || beat(hours: 2) >= slowBeat || beat(hours: 2) <= fastBeat {
            errors.append("the pulse should quicken with the blood")
        }
        let own = threatLine(generated: nil, dayKey: "2026-10-28")
        let good = "Neglect has taken hold and is wearing the Player down. \(threatEnding)"
        if threatLine(generated: good, dayKey: "2026-10-28") != good || !own.hasSuffix(threatEnding) || !own.contains("damaging the Player") {
            errors.append("the generator's line should show when it keeps the voice, else the app's own")
        }
        for bad in ["", "  ", threatEnding, "The penalty grows. \(threatEnding)", "You are lazy! \(threatEnding)",
                    "Laziness is damaging the Player. Run 10 km now.", String(repeating: "x", count: 150) + " " + threatEnding] {
            if threatLine(generated: bad, dayKey: "2026-10-28") != own {
                errors.append("a line off the System's voice should fall back: \(bad)")
            }
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
