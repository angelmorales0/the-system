import Foundation

/// The System's own words for each day, written into the app: the day's narrative and the penalty screen's threat.
/// Nothing is generated. Each list goes through in order, one line a day, so no line repeats within its list's length
/// and a day always reads the same line.
enum DailyLines {
    /// The day's narrative, in the System's voice. It says nothing about loads or pace: the player picks them.
    static let narratives = [
        "The daily quest has been issued. The Player will complete it.",
        "Strength is not given. It is taken, one set at a time.",
        "The System records every rep. Make today's worth recording.",
        "Yesterday is logged and closed. Today is still open.",
        "The gap to the target is measured. Close it.",
        "Discipline is the only stat that raises every other stat.",
        "A quest left open is a weakness the System will remember.",
        "The run builds the engine. The bar builds the frame. Both are required.",
        "No one is coming to do this for the Player.",
        "The body adapts to what it is asked to do. Ask more of it.",
        "Every finished quest is proof. Collect the proof.",
        "The level does not rise on intention. It rises on completed work.",
        "Comfort is the enemy's offer. Decline it.",
        "The split is set. The sets are counted. Begin.",
        "Small work, done daily, becomes a different Player.",
        "The System does not negotiate. The quest stands as written.",
        "Rest is earned by the quest, not taken before it.",
        "Pull-ups are the main goal. Every strict rep moves the Player closer.",
        "The 10 km does not shorten. The Player becomes faster.",
        "Weakness leaves the body one completed quest at a time.",
        "The Player chose this path. The System only keeps the record.",
        "Today's quest is the same size as yesterday's. The Player is not.",
        "Hesitation is logged as time lost.",
        "There is no partial credit for an unfinished day.",
        "The stats are watching. Give them something to count.",
        "A strong day is built from ordinary sets done without excuse.",
        "The System sees the streak. Do not be the one who breaks it.",
        "Effort is the only currency the System accepts.",
        "Finish the quest first. Everything else waits.",
        "The Player is stronger than last month. Prove it again today.",
    ]

    /// The first sentence of the penalty screen: the fault behind the missed day, as a presence that harms the Player.
    /// Each is short enough that, with the run or burpee sentence, the screen stays under 160 characters.
    static let threats = [
        "Laziness is present and is damaging the Player.",
        "Neglect has taken hold and is wearing the Player down.",
        "Bad habits are spreading through the Player.",
        "Complacency has settled in and is weakening the Player.",
        "Weakness has found the Player and is growing.",
        "Avoidance is feeding on the Player's progress.",
        "Comfort has trapped the Player and is closing in.",
        "Sloth is present and is consuming the Player's strength.",
        "Distraction has taken root and is draining the Player.",
        "Excuses are multiplying and are dragging the Player back.",
        "Hesitation has grown into decay inside the Player.",
        "Idleness is present and is eroding the Player.",
        "Procrastination has seized the Player and will not let go.",
        "Apathy is spreading and is hollowing out the Player.",
        "Indulgence has crept in and is softening the Player.",
        "Doubt is present and is stealing the Player's gains.",
        "Inertia has taken hold and is pulling the Player under.",
        "Negligence is present and is rotting the Player's progress.",
        "Self-pity has surfaced and is weakening the Player.",
        "Lethargy is present and is slowing the Player's heart.",
        "Surrender is whispering to the Player and gaining ground.",
        "Stagnation has set in and is shrinking the Player.",
        "Carelessness is present and is breaking down the Player.",
        "Retreat has begun and is costing the Player everything earned.",
        "The old self has returned and is reclaiming the Player.",
        "Decline is present and is accelerating inside the Player.",
        "Softness has spread and is undoing the Player's work.",
        "Fatigue of will has set in and is draining the Player.",
        "The easy path has claimed the Player and is narrowing.",
        "Drift is present and is carrying the Player away.",
    ]

    /// Days since 1970 for a quest day key, so each next day takes the next line.
    private static func dayNumber(_ dayKey: String) -> Int {
        guard let date = QuestDay.date(from: dayKey) else { return 0 }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private static func line(_ lines: [String], dayKey: String) -> String {
        let count = lines.count
        return lines[((dayNumber(dayKey) % count) + count) % count]
    }

    static func narrative(dayKey: String) -> String { line(narratives, dayKey: dayKey) }
    static func threat(dayKey: String) -> String { line(threats, dayKey: dayKey) }

    static func check() -> [String] {
        var errors: [String] = []
        if Set(narratives).count != narratives.count || Set(threats).count != threats.count { errors.append("each line should be in its list once") }
        for line in narratives where line.count > 280 || line.contains("!") || line.lowercased().contains("penalty") {
            errors.append("a narrative should be under 280 characters, calm, and not name the penalty: \(line)")
        }
        let longest = max(PenaltyDecay.threatEnding.count, PenaltyDecay.burpeeEnding.count)
        for line in threats where line.count + 1 + longest > PenaltyDecay.threatMaxCharacters || !line.contains("Player")
            || line.contains("!") || line.lowercased().contains("penalty") {
            errors.append("a threat should fit the screen, name the Player, and keep the System's voice: \(line)")
        }
        // A day reads the same line all day, and the next days take the next lines with no repeat for a full list.
        if narrative(dayKey: "2026-11-21") != narrative(dayKey: "2026-11-21") { errors.append("a day should keep its narrative") }
        var key = "2026-11-21"
        var seen: Set<String> = []
        for _ in threats.indices {
            seen.insert(threat(dayKey: key))
            key = QuestDay.key(byAddingDays: 1, to: key)
        }
        if seen.count != threats.count { errors.append("\(threats.count) days in a row should show every threat once") }
        return errors
    }
}
