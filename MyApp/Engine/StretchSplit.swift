import Foundation

/// A 5-day stretching rotation for the AGI goals. Vertical jump is not a stretching goal, so it has no day here.
/// A week holds 5 or 6 stretching days: `RestDays` rolls 1 or 2 rest days, and a spent rest day has no Stretching row.
/// So the whole rotation fits every week, and a 6-day week starts it again at the front splits.
/// Reviews of static stretching put the most gain at about 10 minutes a week per muscle, and find gains from 5.
/// The splits get 10 minutes a side each week. Shoulders, ankles, and hip rotation get 8.
/// Days run in order. A day moves on only after its row is done, so a missed day comes back next.
enum StretchSplit {
    struct Stretch: Equatable {
        /// Hevy name. `StretchTime.isStretchExercise` must match it, and `AgilityHevy` must not read it as a test.
        var name: String
        var sets: Int
        var perSide: Bool
        /// Seconds per set, on each side.
        var seconds = 60

        var minutes: Double { Double(sets * seconds * (perSide ? 2 : 1)) / 60 }
        var label: String { "\(sets) × \(seconds)s\(perSide ? " per side" : "")" }
    }

    struct Day: Equatable {
        var id: String
        var name: String
        var stretches: [Stretch]

        /// The row's target for this day.
        var minutes: Double { stretches.reduce(0) { $0 + $1.minutes } }
    }

    private static let front = [
        Stretch(name: "Couch Stretch", sets: 5, perSide: true),
        Stretch(name: "Half Split Stretch", sets: 5, perSide: true),
    ]

    static let rotation: [Day] = [
        Day(id: "front_1", name: "Front Splits", stretches: front),
        Day(id: "side", name: "Side Splits + Ankles", stretches: [
            Stretch(name: "Frog Stretch", sets: 3, perSide: false),
            Stretch(name: "Pancake Stretch", sets: 3, perSide: false),
            Stretch(name: "Middle Split Stretch", sets: 4, perSide: false),
            Stretch(name: "Bent Knee Calf Stretch", sets: 5, perSide: true),
        ]),
        Day(id: "upper", name: "Shoulders + Hips", stretches: [
            Stretch(name: "Towel Shoulder Stretch", sets: 5, perSide: true),
            Stretch(name: "90/90 Hip Stretch", sets: 5, perSide: true),
        ]),
        Day(id: "front_2", name: "Front Splits", stretches: front),
        Day(id: "mix", name: "Shoulders, Ankles + Hips", stretches: [
            Stretch(name: "Towel Shoulder Stretch", sets: 3, perSide: true),
            Stretch(name: "Bent Knee Calf Stretch", sets: 3, perSide: true),
            Stretch(name: "Pigeon Pose", sets: 3, perSide: true),
        ]),
    ]

    /// The next day after the newest past day whose row was done. `history` is newest first.
    static func today(history: [QuestDayRecord], dayKey: String) -> Day {
        for record in history where record.dayKey < dayKey {
            for quest in record.quests where quest.status == .completed {
                if let id = quest.params[DailyStretch.dayParam]?.stringValue,
                   let index = rotation.firstIndex(where: { $0.id == id }) {
                    return rotation[(index + 1) % rotation.count]
                }
            }
        }
        return rotation[0]
    }

    /// The day a Stretching row belongs to. Nil for a row saved before this split.
    static func day(of quest: Quest) -> Day? {
        rotation.first { $0.id == quest.verification.params[DailyStretch.dayParam]?.stringValue }
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// Minutes each side gets in one pass of the rotation.
    private static func minutesPerSide(_ names: Set<String>) -> Double {
        rotation.flatMap(\.stretches).filter { names.contains($0.name) }.reduce(0) { $0 + $1.minutes / ($1.perSide ? 2 : 1) }
    }

    static func check() -> [String] {
        var errors: [String] = []
        if rotation.map(\.minutes) != [20, 20, 20, 20, 18] {
            errors.append("stretch days should run 20, 20, 20, 20, 18 minutes, got \(rotation.map(\.minutes))")
        }
        for (names, minutes) in [(["Couch Stretch"], 10.0), (["Half Split Stretch"], 10),
                                 (["Frog Stretch", "Pancake Stretch", "Middle Split Stretch"], 10),
                                 (["Towel Shoulder Stretch"], 8), (["Bent Knee Calf Stretch"], 8),
                                 (["90/90 Hip Stretch", "Pigeon Pose"], 8)]
            where minutesPerSide(Set(names)) != minutes {
            errors.append("\(names) should get \(minutes) minutes a side each rotation")
        }
        for stretch in rotation.flatMap(\.stretches) {
            if !StretchTime.isStretchExercise(stretch.name) { errors.append("\(stretch.name) should count as a stretch") }
            if AgilityHevy.test(named: stretch.name) != nil { errors.append("\(stretch.name) must not read as an AGI test") }
        }
        if Set(rotation.map(\.id)).count != rotation.count { errors.append("stretch day ids should be unique") }

        func record(_ dayKey: String, _ id: String, _ status: QuestStatus) -> QuestDayRecord {
            QuestDayRecord(dayKey: dayKey, mode: .performanceTraining, trainingBand: .green, noGym: false, splitDay: nil,
                           generatedBy: "mock", missedRequired: false, quests: [
                QuestRecord(title: DailyStretch.title, kind: .daily, stat: .AGI, method: .hevySets,
                            params: [DailyStretch.dayParam: .string(id)], target: 20, done: 20, unit: "min", status: status),
            ])
        }
        if today(history: [], dayKey: "2026-11-05").id != "front_1" {
            errors.append("the stretch split should start at the first day")
        }
        if today(history: [record("2026-11-04", "side", .completed)], dayKey: "2026-11-05").id != "upper" {
            errors.append("a done stretch day should move on")
        }
        if today(history: [record("2026-11-04", "upper", .failed), record("2026-11-03", "side", .completed)], dayKey: "2026-11-05").id != "upper" {
            errors.append("a missed stretch day should come back next")
        }
        if today(history: [record("2026-11-04", "mix", .completed)], dayKey: "2026-11-05").id != "front_1" {
            errors.append("the stretch split should wrap to the first day")
        }
        if today(history: [record("2026-11-05", "side", .completed)], dayKey: "2026-11-05").id != "front_1" {
            errors.append("today's own record must not move the split")
        }
        return errors
    }
}
