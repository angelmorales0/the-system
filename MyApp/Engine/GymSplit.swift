import Foundation

/// A 5-day split: upper, lower, upper, lower, then an arms day, built around the STR targets and 5 10Ks a week.
/// Overhead press and bench press come once each, heavy. Chest and triceps get support work on Deadlift Day.
/// Dead hangs come 3 times (Squat, Press, and Arms Day), never on Deadlift Day, so grip gets a day off between hard pulls.
/// Lateral raises and curls, the current focus, come 3 times a rotation (Bench, Press, and Arms Day), never on a leg day.
/// Pull-ups, the main goal (20 strict reps), also come 3 times, each with its own job: volume on Bench Day,
/// weighted strength on Press Day, and a max-effort set on Arms Day. Squats come once, heavy.
/// Rows and the deadlift come once: the deadlift is the most tiring lift next to the running.
/// Pistol squats and handstand push-ups are optional rows, done at home on a good day: one per day at most.
/// Eight support exercises score no STR target: Romanian deadlift and calf raises on Squat Day for the running;
/// incline dumbbell press, skull crushers, and a lying leg curl on Deadlift Day for chest, triceps, and hamstrings;
/// face pulls on Arms Day for the shoulders; and hip adduction and abduction on both lower days.
/// Toes-to-bar comes once, on Arms Day, to make room.
/// The fifth day is upper body with no pressing, so it does not tire the chest before the next Bench Day.
/// The two lower days are the only heavy leg days, two days apart, so the split stays inside the heavy-leg limits
/// next to the running. A third leg day would cost the runs more than it gives the lifts.
/// Days run in order. A day moves on only after one of its lifts is done, so a missed day comes back next.
enum GymSplit {
    static let name = "5-day upper/lower + arms"

    enum Role: String, Codable, Equatable {
        /// The day's heavy lift: one top set at RPE 8, then back-off sets.
        case main
        /// A main lift on its light day: under 80% of the best e1RM, more than 6 reps.
        case light
        /// Double progression in its rep range.
        case accessory
    }

    struct Exercise: Codable, Equatable {
        /// Hevy name without equipment, as the Hevy check compares it.
        var exercise: String
        /// Other Hevy names that count as this exercise.
        var aliases: [String]
        var role: Role
        var sets: Int
        var minReps: Int
        var maxReps: Int
        /// Timed holds and carries: seconds per set instead of reps.
        var secondsPerSet: Double? = nil
        /// The STR target this exercise trains.
        var target: String
        /// An optional row: the player may skip it, and skipping it never misses the day.
        var optional = false
        /// How to run this exercise today, for the generator and the player. Nil when the role says enough.
        var note: String? = nil
        /// A support exercise: it trains what the running and the shoulders need, but no STR target.
        /// Its `target` names the muscle instead.
        var support = false
        /// A goal the player added (see `CustomStrengthGoal`). Its `target` is the goal's STR target.
        var custom = false

        /// The hip rows sit outside the day limit, so a goal never needs their place and never takes it.
        var isHipRow: Bool { support && GymSplit.hipRows.contains { $0.exercise == exercise } }
    }

    struct Day: Codable, Equatable {
        var id: String
        /// Shown in `[Daily Quest: {name} has arrived.]`.
        var name: String
        var focus: String
        var lowerBody: Bool
        var exercises: [Exercise]
    }

    private static func lift(_ exercise: String, _ role: Role, _ sets: Int, _ reps: ClosedRange<Int>, target: String, aliases: [String], optional: Bool = false, note: String? = nil) -> Exercise {
        Exercise(exercise: exercise, aliases: aliases, role: role, sets: sets, minReps: reps.lowerBound, maxReps: reps.upperBound, target: target, optional: optional, note: note)
    }

    /// A support exercise in double progression. The name is Hevy's, without equipment, so the Hevy check finds it.
    private static func support(_ exercise: String, _ sets: Int, _ reps: ClosedRange<Int>, muscle: String, aliases: [String], note: String? = nil) -> Exercise {
        Exercise(exercise: exercise, aliases: aliases, role: .accessory, sets: sets, minReps: reps.lowerBound, maxReps: reps.upperBound, target: muscle, note: note, support: true)
    }

    /// Inner and outer hip, on both lower days, after the rest of the leg work.
    static let hipRows = [
        support("Hip Adduction", 2, 10...15, muscle: "Adductors", aliases: ["hip adduction"],
                note: "Inner hip. Light and controlled, 2-3 reps in reserve."),
        support("Hip Abduction", 2, 10...15, muscle: "Abductors", aliases: ["hip abduction"],
                note: "Outer hip, which keeps the knees and pelvis steady on the run. Light and controlled, 2-3 reps in reserve."),
    ]

    private static func hold(_ exercise: String, _ sets: Int, seconds: Double, target: String, aliases: [String]) -> Exercise {
        Exercise(exercise: exercise, aliases: aliases, role: .accessory, sets: sets, minReps: 0, maxReps: 0, secondsPerSet: seconds, target: target)
    }

    static let bench = Day(id: "bench", name: "Bench Day", focus: "Upper body: chest, back, side delts, biceps", lowerBody: false, exercises: [
        lift("Bench Press", .main, 3, 3...5, target: "Bench press", aliases: StrengthLevel.bench.aliases),
        lift("Bent Over Row", .main, 3, 5...8, target: "Barbell row", aliases: StrengthLevel.row.aliases),
        lift("Pull Up", .accessory, 4, 3...10, target: "Pull-ups", aliases: StrengthLevel.pullUps.aliases, note: pullUpVolume),
        lift("Chest Dip", .accessory, 3, 5...8, target: "Weighted dips", aliases: StrengthLevel.dips.aliases),
        lift("Lateral Raise", .accessory, 3, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 3, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
    ])

    static let squat = Day(id: "squat", name: "Squat Day", focus: "Lower body: squat, single-leg work, hamstrings, calves, and hips", lowerBody: true, exercises: [
        lift("Squat", .main, 3, 1...5, target: "Squat", aliases: StrengthLevel.squat.aliases),
        // Sets count both legs: 2 per leg.
        lift("Bulgarian Split Squat", .accessory, 3, 8...12, target: "Bulgarian split squat", aliases: StrengthLevel.bulgarianSplitSquat.aliases),
        support("Romanian Deadlift", 3, 8...10, muscle: "Hamstrings", aliases: ["romanian deadlift", "rdl"],
                note: "Hamstrings and glutes for the running. Moderate weight, 2-3 reps in reserve; this is not a heavy deadlift."),
        support("Standing Calf Raise", 3, 10...15, muscle: "Calves", aliases: ["standing calf raise", "calf raise", "seated calf raise"],
                note: "Calves and Achilles for the running. Slow, full range, a pause at the bottom."),
    ] + hipRows + [
        hold("Dead Hang", 3, seconds: 60, target: "Dead hang", aliases: StrengthLevel.hangAliases),
        // Optional and last: done at home on a good day, so the gym session stays short next to the running.
        lift("Pistol Squat", .accessory, 3, 3...10, target: "Pistol squats", aliases: StrengthLevel.pistolAliases, optional: true,
             note: "Optional. Do them at home only if your legs feel good. Skipping them never misses the day."),
    ])

    static let press = Day(id: "press", name: "Press Day", focus: "Upper body: shoulders, back, chest, biceps", lowerBody: false, exercises: [
        lift("Overhead Press", .main, 3, 1...5, target: "Overhead press", aliases: StrengthLevel.overheadPress.aliases),
        lift("Pull Up", .main, 4, 3...5, target: "Pull-ups", aliases: StrengthLevel.pullUps.aliases, note: pullUpStrength),
        lift("Lateral Raise", .accessory, 3, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 3, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
        hold("Dead Hang", 3, seconds: 60, target: "Dead hang", aliases: StrengthLevel.hangAliases),
        // Optional and last, like the pistol squats: done at home if there is time.
        lift("Handstand Push Up", .accessory, 3, 1...5, target: "Handstand push-ups", aliases: StrengthLevel.handstandPushUps.aliases, optional: true,
             note: "Optional. Do them at home if you have time. Skipping them never misses the day."),
    ])

    static let deadlift = Day(id: "deadlift", name: "Deadlift Day", focus: "Lower body: deadlift, hamstrings, and hips, plus chest, triceps, and grip", lowerBody: true, exercises: [
        lift("Deadlift", .main, 3, 1...5, target: "Deadlift", aliases: StrengthLevel.deadlift.aliases),
        // Chest and triceps, three days before the next Bench Day, with Arms Day (no pressing) between.
        support("Incline Bench Press", 3, 8...12, muscle: "Chest", aliases: ["incline bench press", "incline dumbbell press"],
                note: "Dumbbells, 30-45° incline. Upper chest, which the flat bench misses. 1-2 reps in reserve."),
        support("Skullcrusher", 3, 8...12, muscle: "Triceps", aliases: ["skullcrusher", "skull crusher", "lying triceps extension"],
                note: "Triceps long head, the biggest part of the upper arm. EZ bar or dumbbells, elbows still."),
        support("Lying Leg Curl", 3, 8...12, muscle: "Hamstrings", aliases: ["lying leg curl", "seated leg curl", "leg curl", "nordic hamstring curl", "nordic curl"],
                note: "Knee-flexion hamstring work, which the hinge lifts miss. Runners need it to protect the hamstrings."),
    ] + hipRows + [
        hold("Farmers Walk", 3, seconds: 60, target: "Farmer's carry", aliases: StrengthLevel.farmerAliases),
    ])

    static let arms = Day(id: "arms", name: "Arms Day", focus: "Pull-ups first while fresh, then side delts, biceps, grip, and core. No pressing", lowerBody: false, exercises: [
        lift("Pull Up", .accessory, 3, 3...20, target: "Pull-ups", aliases: StrengthLevel.pullUps.aliases, note: pullUpMax),
        lift("Lateral Raise", .accessory, 3, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 3, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
        lift("Toes To Bar", .accessory, 3, 5...10, target: "Toes-to-bar", aliases: StrengthLevel.toesToBar.aliases),
        hold("Dead Hang", 3, seconds: 60, target: "Dead hang", aliases: StrengthLevel.hangAliases),
        support("Face Pull", 3, 12...15, muscle: "Rear delts", aliases: ["face pull"],
                note: "Rear delts and rotator cuff, to balance the pressing and lateral raises. Light, controlled reps."),
    ])

    // Three pull-up sessions, three jobs. Together: 11 sets a rotation, most of them short of failure.
    static let pullUpVolume = "Volume: strict sets, each stopped about 3 reps short of failure. Add 1 rep to every set each week. Never to failure today."
    static let pullUpStrength = "Weighted strength: add weight with a belt or a dumbbell so the top set of 5 is about RPE 8. Under 8 strict bodyweight reps, do bodyweight sets of 3-5 instead."
    static let pullUpMax = "Max effort: first set as many strict reps as you can, stopping 1 rep short of failure. Then 2 sets at about 60% of that number. The first set shows your progress to 20."

    /// The most sets one lift holds in a day: 3 for every lift, 4 for pull-ups, the main goal.
    /// The split, the planner's plans, and a day that is already saved all keep to it.
    static let maxSetsPerLift = 3
    static let maxPullUpSets = 4

    static func maxSets(for exercise: String) -> Int {
        StrengthLevel.pullUps.aliases.contains(StrengthLevel.normalizedName(exercise)) ? maxPullUpSets : maxSetsPerLift
    }

    /// Cuts each open lift row that asks for more sets down to the limit: a plan the planner wrote, or a day saved
    /// before the limit. A finished row stays as it is. A timed row keeps its seconds per set.
    static func cappingSets(_ bundle: QuestBundle) -> QuestBundle {
        var copy = bundle
        for index in copy.quests.indices {
            let quest = copy.quests[index]
            guard quest.verification.method == .hevySets, quest.id != DailyStretch.questId, quest.status != .completed,
                  let sets = quest.verification.params["sets"]?.doubleValue, sets > 0 else { continue }
            let limit = Double(maxSets(for: quest.verification.params["exercise"]?.stringValue ?? quest.title))
            guard sets > limit else { continue }
            var row = quest
            row.verification.params["sets"] = .number(limit)
            if let seconds = quest.verification.params["minDurationSec"]?.doubleValue {
                row.verification.params["minDurationSec"] = .number(seconds / sets * limit)
            }
            row.progress.target = quest.progress.target / sets * limit
            row.progress.current = min(quest.progress.current, row.progress.target)
            for mark in ["×", "x"] {
                if let range = row.title.range(of: "\(Int(sets))\(mark)") {
                    row.title.replaceSubrange(range, with: "\(Int(limit))\(mark)")
                    break
                }
            }
            copy.quests[index] = row
        }
        return copy
    }

    /// The player's top focus right now. Each is trained 3 times a rotation, and is never dropped for time.
    /// Pull-ups lead: 20 strict reps is the main goal.
    static let focusTargets = ["Pull-ups", "Lateral raise", "Dumbbell curl"]
    /// At most this many lifts a day, not counting the hip rows, so a day with two 10Ks still fits the quest limits.
    static let maxExercisesPerDay = 6
    private static func countedRows(_ exercises: [Exercise]) -> Int {
        exercises.filter { !$0.isHipRow }.count
    }

    /// Upper and lower alternate, so lifting on back-to-back days never puts two leg days together.
    /// Arms Day ends the rotation: it is upper body with no pressing, so the next Bench Day starts fresh.
    static let rotation = [bench, squat, press, deadlift, arms]

    static func day(named name: String) -> Day? {
        rotation.first { $0.name == name }
    }

    static func day(id: String) -> Day? {
        rotation.first { $0.id == id }
    }

    /// The next day in the rotation after the newest past day whose lifts were started, with the player's own goals on it.
    /// A split day the player skipped counts like a done day here, so the split moves past it.
    /// `history` is newest first. With no lifting yet, the split starts at Bench Day.
    static func today(history: [QuestDayRecord], dayKey: String, goals: [CustomStrengthGoal] = []) -> Day {
        // A skip is written on the newest past record, after that record's own day, so it comes first.
        let last = history.lazy.filter { $0.dayKey < dayKey }.compactMap { $0.skippedSplitDay ?? doneSplitDay($0) }.first
        guard let last, let index = rotation.firstIndex(where: { $0.id == last }) else { return adding(goals, to: rotation[0]) }
        return adding(goals, to: rotation[(index + 1) % rotation.count])
    }

    /// The split day this record trained: it has a split day and one of its lifts is done.
    private static func doneSplitDay(_ record: QuestDayRecord) -> String? {
        record.quests.contains { $0.stat == .STR && $0.status == .completed } ? record.splitDay : nil
    }

    // MARK: - Custom goals

    /// The rotation with the player's own goals on their days.
    static func rotation(with goals: [CustomStrengthGoal]) -> [Day] {
        rotation.map { adding(goals, to: $0) }
    }

    /// Puts each custom goal of this day on it, oldest goal first, as a scored STR exercise.
    ///
    /// Full-day rule: a day holds at most `maxExercisesPerDay` exercises besides its hip rows, so the day fits the quest limits
    /// (`QuestSafety.maxQuests`, `MorningConstraints.maxRequiredQuests`). A goal takes a free place first, before
    /// the optional row. On a full day, it takes the place of a support exercise: the one with the same name, else the
    /// last support exercise still on the day. A goal never cuts a scored STR target, a focus target, an optional row,
    /// or another custom goal. A day with no free place and no support exercise left has no room:
    /// `StatTargets.add` refuses the goal and the sheet tells the player. Today every day is full, so the room is
    /// Squat Day 2, Deadlift Day 3, Arms Day 1, Bench Day 0, and Press Day 0.
    static func adding(_ goals: [CustomStrengthGoal], to day: Day) -> Day {
        var copy = day
        for goal in goals where goal.day == day.id {
            let row = exercise(for: goal)
            if countedRows(copy.exercises) < maxExercisesPerDay {
                copy.exercises.insert(row, at: copy.exercises.firstIndex(where: \.optional) ?? copy.exercises.count)
            } else if let index = copy.exercises.firstIndex(where: { $0.support && names(of: $0).contains(goal.alias) })
                        ?? copy.exercises.lastIndex(where: { $0.support && !$0.isHipRow }) {
                copy.exercises[index] = row
            }
            // Else the day has no room. `StatTargets.add` never saves such a goal, so the day stays as it is.
        }
        return copy
    }

    /// The support exercise that a new goal would cut from its day. Nil when it takes a free place or the day has no room.
    static func replaced(by goal: CustomStrengthGoal, goals: [CustomStrengthGoal]) -> Exercise? {
        guard let splitDay = Self.day(id: goal.day) else { return nil }
        let before = adding(goals, to: splitDay).exercises
        let after = adding(goals + [goal], to: splitDay).exercises
        return before.first { old in old.support && !after.contains(old) }
    }

    /// How many more custom goals the day can take: free places plus support exercises still on it.
    static func room(on day: Day, goals: [CustomStrengthGoal]) -> Int {
        let adapted = adding(goals, to: day)
        return max(0, maxExercisesPerDay - countedRows(adapted.exercises)) + adapted.exercises.filter { $0.support && !$0.isHipRow }.count
    }

    /// "Auto": the upper-body or lower-body day with the most room, the first in the rotation on a tie. Nil when none has room.
    static func autoDay(lowerBody: Bool, goals: [CustomStrengthGoal]) -> Day? {
        rotation.enumerated()
            .filter { $0.element.lowerBody == lowerBody && room(on: $0.element, goals: goals) > 0 }
            .min { lhs, rhs in
                let left = room(on: lhs.element, goals: goals), right = room(on: rhs.element, goals: goals)
                return left != right ? left > right : lhs.offset < rhs.offset
            }?.element
    }

    /// The split row of a custom goal: an accessory that trains toward the goal.
    /// Weight × reps: 3 sets in double progression from the goal's reps up to 4 more.
    /// Reps: a max-effort set, then sets at about 60%. Holds: 3 holds at half the goal time.
    static func exercise(for goal: CustomStrengthGoal) -> Exercise {
        let name = goal.exercise
        switch goal.kind {
        case .weightReps:
            let low = min(max(goal.targetReps, 1), 20)
            return Exercise(exercise: name, aliases: [goal.alias], role: .accessory, sets: 3, minReps: low, maxReps: low + 4, target: goal.category,
                            note: "Your goal: \(goal.goal). Double progression: add reps until every set reaches \(low + 4), then add the smallest weight step and go back to \(low).",
                            custom: true)
        case .reps:
            let target = max(goal.targetReps, 1)
            return Exercise(exercise: name, aliases: [goal.alias], role: .accessory, sets: maxSets(for: name), minReps: max(1, target / 4), maxReps: target, target: goal.category,
                            note: "Your goal: \(goal.goal). First set as many strict reps as you can, stopping 1 rep short of failure. Then \(maxSets(for: name) - 1) sets at about 60% of that number.",
                            custom: true)
        case .hold:
            let seconds = min(goal.targetSeconds, max(10, (goal.targetSeconds / 2).rounded()))
            return Exercise(exercise: name, aliases: [goal.alias], role: .accessory, sets: 3, minReps: 0, maxReps: 0, secondsPerSet: seconds, target: goal.category,
                            note: "Your goal: \(goal.goal). Hold 3 sets of \(Int(seconds)) sec. Add 5 sec to each set once all 3 feel easy.",
                            custom: true)
        }
    }

    private static func names(of exercise: Exercise) -> Set<String> {
        Set(([exercise.exercise] + exercise.aliases).map { StrengthLevel.normalizedName($0) })
    }

    /// The newest day each split day was done, by name, so the generator sees how the rotation went.
    static func lastDone(history: [QuestDayRecord]) -> [String: String] {
        var dates: [String: String] = [:]
        for record in history.reversed() {
            guard let id = record.splitDay, let day = day(id: id),
                  record.quests.contains(where: { $0.stat == .STR && $0.status == .completed }) else { continue }
            dates[day.name] = record.dayKey
        }
        return dates
    }

    /// Swaps the catalog's strength rows for the split day's exercises, without loads.
    /// The generator writes the loads; this is the plan when it is offline. Yellow and red take one set off each main lift.
    static func apply(_ day: Day, to bundle: QuestBundle, band: ReadinessBand, now: Date) -> QuestBundle {
        // Optional lift rows (pistol squats) are the split's too, so a second pass does not repeat them.
        func isLift(_ quest: Quest) -> Bool {
            TrainingDay.isStrength(quest) && quest.id != DailyStretch.questId && (quest.kind == .daily || quest.kind == .optional)
        }
        guard bundle.mode == .performanceTraining, bundle.quests.contains(where: { isLift($0) && $0.kind == .daily }) else { return bundle }
        var copy = bundle
        copy.headerLine = day.name
        copy.quests.removeAll(where: isLift)
        let rows = day.exercises.map { quest(for: $0, band: band, dayKey: bundle.dayKey, now: now) }
        let insertAt = copy.quests.lastIndex { $0.kind == .daily }.map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(contentsOf: rows, at: insertAt)
        return copy
    }

    /// Takes a row the split no longer has off a day that was saved before the split changed.
    /// The light squat left Deadlift Day; a saved Deadlift Day still had its row. A row with sets done stays.
    static func withoutOldRows(_ bundle: QuestBundle) -> QuestBundle {
        guard bundle.headerLine == deadlift.name else { return bundle }
        var copy = bundle
        // The planner writes its own ids and names ("Squat (Barbell)"), so the exercise decides, not the id.
        let squats = Set((StrengthLevel.squat.aliases + ["Squat"]).map(StrengthLevel.normalizedName))
        copy.quests.removeAll {
            guard $0.verification.method == .hevySets, !$0.id.hasSuffix("_goal"),
                  let exercise = $0.verification.params["exercise"]?.stringValue else { return false }
            return squats.contains(StrengthLevel.normalizedName(exercise)) && $0.status == .pending && $0.progress.current == 0 && $0.evidence.isEmpty
        }
        return copy
    }

    static func quest(for exercise: Exercise, band: ReadinessBand, dayKey: String, now: Date) -> Quest {
        let sets = exercise.role == .main && band != .green ? max(1, exercise.sets - 1) : exercise.sets
        var params: [String: JSONValue] = ["exercise": .string(exercise.exercise), "sets": .number(Double(sets))]
        let title: String
        let progress: QuestProgress
        if let seconds = exercise.secondsPerSet {
            params["minDurationSec"] = .number(seconds * Double(sets))
            title = "\(exercise.exercise) \(sets)×\(Int(seconds))s"
            progress = QuestProgress(current: 0, target: seconds * Double(sets) / 60, unit: "min")
        } else {
            params["minReps"] = .number(Double(exercise.minReps))
            let reps = exercise.minReps == exercise.maxReps ? "\(exercise.minReps)" : "\(exercise.minReps)-\(exercise.maxReps)"
            title = "\(exercise.exercise) \(sets)×\(reps)"
            progress = QuestProgress(current: 0, target: Double(sets), unit: "sets")
        }
        let slug = exercise.exercise.lowercased().replacingOccurrences(of: " ", with: "_")
        return Quest(
            // A goal's row has its own ending: a goal named "Squat Light" would else share the light squat's id.
            id: "q_\(dayKey)_\(slug)\(exercise.role == .light ? "_light" : "")\(exercise.custom ? "_goal" : "")",
            title: title,
            kind: exercise.optional ? .optional : .daily,
            stat: .STR,
            verification: VerificationSpec(method: .hevySets, params: params),
            deadline: QuestDay.endOfDay(now),
            difficulty: exercise.role == .main ? .hard : .normal,
            mode: .performanceTraining,
            progress: progress,
            status: .pending,
            evidence: [],
            assignedAt: now
        )
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        guard let now = QuestDay.date(from: "2026-10-05") else { return ["quest day failed to parse"] }
        // A Deadlift Day saved before the light squat left the split loses that row; a row with sets done stays.
        let deadliftDay = apply(deadlift, to: FallbackCatalog.bundled().makeBundle(mode: .performanceTraining, band: .green, dayKey: "2026-10-05", now: now), band: .green, now: now)
        var oldRow = quest(for: lift("Squat", .light, 3, 8...8, target: "Squat", aliases: []), band: .green, dayKey: "2026-10-05", now: now)
        var saved = deadliftDay
        saved.quests.append(oldRow)
        if withoutOldRows(saved).quests != deadliftDay.quests {
            errors.append("a saved Deadlift Day should lose the old light squat row")
        }
        var planned = oldRow
        planned.id = "q_2026-10-05_model_squat"
        planned.verification.params["exercise"] = .string("Squat (Barbell)")
        saved = deadliftDay
        saved.quests.append(planned)
        if withoutOldRows(saved).quests != deadliftDay.quests {
            errors.append("a saved Deadlift Day should lose a squat row the planner wrote")
        }
        oldRow.progress.current = 1
        saved = deadliftDay
        saved.quests.append(oldRow)
        if withoutOldRows(saved).quests != saved.quests {
            errors.append("a light squat row with a set done should stay")
        }
        let catalog = FallbackCatalog.bundled()

        // Every exercise trains a real STR target, and every STR target is in the split.
        let targets = Set(StrengthLevel.evaluate(workouts: [], now: now).requirements.map(\.category))
        let trained = Set(rotation.flatMap { $0.exercises.filter { !$0.support }.map(\.target) })
        if !trained.isSubset(of: targets) || trained != targets {
            errors.append("the split should train exactly the STR targets, missing \(targets.subtracting(trained).sorted()), extra \(trained.subtracting(targets).sorted())")
        }
        if rotation.map(\.lowerBody) != [false, true, false, true, false] {
            errors.append("the split should run upper, lower, upper, lower, arms")
        }
        if arms.exercises.contains(where: { ["Bench press", "Overhead press", "Weighted dips", "Handstand push-ups"].contains($0.target) }) {
            errors.append("Arms Day must not press, so the next Bench Day starts fresh")
        }
        for day in rotation {
            for exercise in day.exercises where exercise.sets > maxSets(for: exercise.exercise) {
                errors.append("\(exercise.exercise) on \(day.name) should have at most \(maxSets(for: exercise.exercise)) sets, got \(exercise.sets)")
            }
        }
        if maxSets(for: "Pull Up (Weighted)") != 4 || maxSets(for: "Lateral Raise") != 3 {
            errors.append("the set limit should be 4 for pull-ups and 3 for every other lift")
        }
        for day in rotation where countedRows(day.exercises) > maxExercisesPerDay {
            errors.append("\(day.name) should have at most \(maxExercisesPerDay) exercises so the day fits the quest limits")
        }
        let fullDay = maxExercisesPerDay + hipRows.count + NoGymDay.runCount
        if fullDay > MorningConstraints.standard.maxRequiredQuests || fullDay + MorningConstraints.standard.maxOptionalQuests > QuestSafety.maxQuests {
            errors.append("a full split day with two 10Ks should fit the quest limits")
        }
        // Days a rotation that train each target. The focus targets come 3 times; the hardest lifts once.
        let expectedDays: [String: Int] = [
            "Lateral raise": 3, "Dumbbell curl": 3, "Toes-to-bar": 1,
            "Pull-ups": 3, "Dead hang": 3, "Squat": 1, "Overhead press": 1, "Barbell row": 1,
            "Deadlift": 1, "Bench press": 1, "Weighted dips": 1, "Handstand push-ups": 1,
            "Bulgarian split squat": 1, "Pistol squats": 1, "Farmer's carry": 1,
        ]
        for target in targets {
            let count = rotation.filter { day in day.exercises.contains { $0.target == target } }.count
            let expected = expectedDays[target] ?? -1
            if count != expected {
                errors.append("\(target) should be trained \(expected) times a rotation, got \(count)")
            }
        }
        for day in rotation where day.exercises.contains(where: { StretchTime.isStretchExercise($0.exercise) }) {
            errors.append("\(day.name) must not hold a stretch; the Stretching row covers that")
        }

        // A fresh game starts at Bench Day, and the catalog day uses its exercises.
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        if snapshot.bundle.headerLine != "Bench Day" || !snapshot.bundle.quests.contains(where: { $0.title == "Bench Press 3×3-5" }) {
            errors.append("a fresh game should start on Bench Day, got \(snapshot.bundle.headerLine) \(snapshot.bundle.quests.map(\.title))")
        }
        if !snapshot.bundle.quests.contains(where: { NoGymDay.isTenK($0) }) || snapshot.bundle.quests.last?.id != DailyStretch.questId {
            errors.append("a split day should keep the 10K and end with Stretching, got \(snapshot.bundle.quests.map(\.title))")
        }

        // The offline generator builds the same split day, so it does not undo the split.
        let mock = MockQuestGenerateClient(catalog: catalog).bundle(for: ContextBuilder.make(snapshot: snapshot, now: now), now: now)
        if mock.headerLine != "Bench Day" || TrainingDay.exerciseOnly(mock)?.headerLine != "Bench Day" {
            errors.append("the mock generator should build today's split day, got \(mock.headerLine)")
        }

        // A day with a lift done moves the split on; a day with none repeats it.
        func finishDay(_ snapshot: inout GameSnapshot, lift: Bool, dayOffset: Int) {
            if lift, let row = snapshot.bundle.quests.first(where: { $0.stat == .STR }) {
                let evidence = Evidence.make(source: "manual_confirm", externalId: "split-\(dayOffset)", payload: "split", timestamp: now)
                _ = snapshot.apply(.completed(evidence: evidence), questId: row.id, now: now)
            }
            snapshot.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(Double(dayOffset) * 86_400))
        }
        finishDay(&snapshot, lift: true, dayOffset: 1)
        if snapshot.bundle.headerLine != "Squat Day" || snapshot.questHistory.first?.splitDay != "bench" {
            errors.append("after Bench Day the split should move to Squat Day, got \(snapshot.bundle.headerLine)")
        }
        finishDay(&snapshot, lift: false, dayOffset: 2)
        if snapshot.bundle.headerLine != "Squat Day" {
            errors.append("a missed Squat Day should come back the next day, got \(snapshot.bundle.headerLine)")
        }
        finishDay(&snapshot, lift: true, dayOffset: 3)
        finishDay(&snapshot, lift: true, dayOffset: 4)
        finishDay(&snapshot, lift: true, dayOffset: 5)
        if snapshot.bundle.headerLine != "Arms Day" {
            errors.append("after Deadlift Day the split should move to Arms Day, got \(snapshot.bundle.headerLine)")
        }
        finishDay(&snapshot, lift: true, dayOffset: 6)
        if snapshot.bundle.headerLine != "Bench Day" {
            errors.append("after Arms Day the split should start again at Bench Day, got \(snapshot.bundle.headerLine)")
        }
        if lastDone(history: snapshot.questHistory)["Squat Day"] != QuestDay.key(for: now.addingTimeInterval(2 * 86_400)) {
            errors.append("the last Squat Day should be the one that was done, got \(lastDone(history: snapshot.questHistory))")
        }

        // Squat Day: pistol squats are an optional row, so the day is done without them.
        let squatDay = GymSplit.apply(squat, to: catalog.makeBundle(mode: .performanceTraining, band: .green, dayKey: "2026-10-05", now: now), band: .green, now: now)
        let pistolRows = squatDay.quests.filter { $0.title.hasPrefix("Pistol Squat") }
        if pistolRows.count != 1 || pistolRows.first?.kind != .optional {
            errors.append("Squat Day should have one optional Pistol Squat row, got \(squatDay.quests.map { "\($0.title) \($0.kind)" })")
        }
        if apply(squat, to: squatDay, band: .green, now: now).quests.filter({ $0.title.hasPrefix("Pistol Squat") }).count != 1 {
            errors.append("applying Squat Day twice should not repeat the optional pistol row")
        }
        var skipped = GameSnapshot.fresh(catalog: catalog, now: now)
        skipped.bundle = squatDay
        for index in skipped.bundle.quests.indices where skipped.bundle.quests[index].kind != .optional {
            skipped.bundle.quests[index].status = .completed
        }
        if skipped.missesRequiredSet {
            errors.append("skipping only the optional pistol squats should not miss the day")
        }

        // Support exercises: a hinge and a knee-flexion hamstring lift on different days, face pulls, and calf raises.
        let supportDays = rotation.flatMap { day in day.exercises.filter(\.support).map { "\(day.id): \($0.exercise)" } }
        if supportDays != ["squat: Romanian Deadlift", "squat: Standing Calf Raise", "squat: Hip Adduction", "squat: Hip Abduction",
                           "deadlift: Incline Bench Press", "deadlift: Skullcrusher", "deadlift: Lying Leg Curl", "deadlift: Hip Adduction", "deadlift: Hip Abduction", "arms: Face Pull"] {
            errors.append("support exercises should be RDL, calf raises, and the hip rows on Squat Day; incline press, skull crushers, leg curls, and the hip rows on Deadlift Day; face pulls on Arms Day, got \(supportDays)")
        }
        if rotation.flatMap(\.exercises).contains(where: { $0.support && targets.contains($0.target) }) {
            errors.append("a support exercise must not claim an STR target")
        }

        // Optional rows: pistol squats and handstand push-ups only, last in their day, and one per day at most.
        let optionalTargets = rotation.flatMap { $0.exercises.filter(\.optional).map(\.target) }.sorted()
        if optionalTargets != ["Handstand push-ups", "Pistol squats"] {
            errors.append("only pistol squats and handstand push-ups should be optional, got \(optionalTargets)")
        }
        for day in rotation where day.exercises.filter(\.optional).count > MorningConstraints.standard.maxOptionalQuests
            || day.exercises.dropLast().contains(where: \.optional) {
            errors.append("\(day.name) should have at most \(MorningConstraints.standard.maxOptionalQuests) optional row, and only last")
        }

        // Pull-ups: three sessions, three jobs. Weighted strength is the only heavy one.
        let pullUps = rotation.compactMap { day in day.exercises.first { $0.target == "Pull-ups" }.map { (day.id, $0) } }
        if pullUps.map(\.0) != ["bench", "press", "arms"] || pullUps.map(\.1.role) != [.accessory, .main, .accessory]
            || pullUps.contains(where: { $0.1.note == nil }) || arms.exercises.first?.target != "Pull-ups" {
            errors.append("pull-ups should be volume on Bench, weighted on Press, and max effort first on Arms Day, got \(pullUps.map { "\($0.0) \($0.1.role)" })")
        }

        // Yellow takes one set off the main lift only; the support rows keep their sets.
        let yellow = apply(deadlift, to: catalog.makeBundle(mode: .performanceTraining, band: .green, dayKey: "2026-10-05", now: now), band: .yellow, now: now)
        if yellow.quests.first(where: { $0.title.hasPrefix("Deadlift") })?.title != "Deadlift 2×1-5"
            || !yellow.quests.contains(where: { $0.title == "Incline Bench Press 3×8-12" }) || yellow.quests.contains(where: { $0.title.hasPrefix("Squat") }) {
            errors.append("yellow should take a set off the main lift only, got \(yellow.quests.map(\.title))")
        }
        if yellow.quests.first(where: { $0.title.hasPrefix("Farmers Walk") })?.verification.params["minDurationSec"]?.doubleValue != 180 {
            errors.append("a timed exercise should check total seconds")
        }

        // No gym today: the lifts go, the header goes back to Training, and turning it off brings the day back.
        var noGym = GameSnapshot.fresh(catalog: catalog, now: now)
        _ = noGym.setNoGym(true, catalog: catalog, now: now)
        if noGym.bundle.headerLine != TrainingDay.header || noGym.bundle.quests.contains(where: { $0.stat == .STR }) {
            errors.append("a no-gym day should drop the split header and lifts, got \(noGym.bundle.headerLine)")
        }
        _ = noGym.setNoGym(false, catalog: catalog, now: now)
        if noGym.bundle.headerLine != "Bench Day" {
            errors.append("turning no gym off should bring back Bench Day, got \(noGym.bundle.headerLine)")
        }
        errors += customGoalChecks(catalog: catalog, now: now)
        return errors
    }

    /// Custom goals land on their split day, follow the full-day rule, and reach the offline day, the context,
    /// the generated bundle, and the Hevy check.
    private static func customGoalChecks(catalog: FallbackCatalog, now: Date) -> [String] {
        var errors: [String] = []
        let hipThrust = CustomStrengthGoal(exercise: "Hip Thrust", kind: .weightReps, targetLb: 225, targetReps: 5, day: "deadlift")
        let lSit = CustomStrengthGoal(exercise: "L-Sit", kind: .hold, targetSeconds: 30, day: "arms")

        // Deadlift Day has one free place: the first goal is added, and every exercise of the day stays.
        // The second goal takes the place of the last support exercise.
        let withThrust = adding([hipThrust], to: deadlift)
        let names = withThrust.exercises.map(\.exercise)
        if names != ["Deadlift", "Incline Bench Press", "Skullcrusher", "Lying Leg Curl", "Hip Adduction", "Hip Abduction", "Farmers Walk", "Hip Thrust"]
            || withThrust.exercises.first(where: \.custom)?.target != "Hip Thrust" {
            errors.append("Hip Thrust should be added to Deadlift Day, got \(names)")
        }
        let second = CustomStrengthGoal(exercise: "Glute Bridge", kind: .reps, targetReps: 15, day: "deadlift")
        if replaced(by: hipThrust, goals: []) != nil || replaced(by: second, goals: [hipThrust])?.exercise != "Lying Leg Curl" {
            errors.append("the sheet should say the first goal replaces nothing and the second replaces the Lying Leg Curl")
        }
        if rotation(with: [hipThrust]).filter({ $0.id != "deadlift" }) != rotation.filter({ $0.id != "deadlift" }) {
            errors.append("a goal should change only its own day")
        }
        let row = exercise(for: hipThrust)
        if row.role != .accessory || row.minReps != 5 || row.maxReps != 9 || row.sets != 3 || row.note == nil || row.support {
            errors.append("a weight × reps goal should be a 3×5-9 accessory with a note, got \(row)")
        }
        let hold = exercise(for: lSit)
        if hold.secondsPerSet != 15 || hold.note == nil {
            errors.append("a 30 sec hold goal should train 3 holds of 15 sec, got \(hold)")
        }

        // Full-day rule: never more than the day limit, never a scored or focus target cut, and no room means refused.
        let three = ["Glute Bridge", "Back Extension", "Nordic Curl"].map {
            CustomStrengthGoal(exercise: $0, kind: .reps, targetReps: 15, day: "deadlift")
        }
        let packed = adding([hipThrust] + three, to: deadlift)
        let scored = deadlift.exercises.filter { !$0.support }.map(\.target)
        if countedRows(packed.exercises) > maxExercisesPerDay || packed.exercises.filter(\.support) != hipRows
            || !Set(scored).isSubset(of: packed.exercises.map(\.target))
            || Set(packed.exercises.filter(\.custom).map(\.exercise)) != ["Back Extension", "Glute Bridge", "Hip Thrust", "Nordic Curl"] {
            errors.append("Deadlift Day should take 4 goals, one in its free place and 3 in place of its support exercises, got \(packed.exercises.map(\.exercise))")
        }
        if room(on: deadlift, goals: [hipThrust] + three) != 0 || room(on: bench, goals: []) != 0 || room(on: squat, goals: []) != 2 {
            errors.append("room should be 0 on a full day, 0 on Bench Day, and 2 on Squat Day")
        }
        var targets = StatTargets()
        for goal in [hipThrust] + three where targets.add(goal) != nil {
            errors.append("\(goal.exercise) should fit on Deadlift Day")
        }
        if targets.add(CustomStrengthGoal(exercise: "Reverse Hyper", kind: .reps, targetReps: 15, day: "deadlift")) == nil || targets.custom.count != 4 {
            errors.append("a fifth goal on a full Deadlift Day should be refused")
        }
        for day in rotation(with: targets.custom) {
            if countedRows(day.exercises) > maxExercisesPerDay {
                errors.append("\(day.name) should stay at \(maxExercisesPerDay) exercises or fewer")
            }
            for focus in focusTargets where (rotation.first { $0.id == day.id }?.exercises.contains { $0.target == focus } ?? false)
                && !day.exercises.contains(where: { $0.target == focus }) {
                errors.append("a goal must never cut the focus target \(focus) from \(day.name)")
            }
        }
        // A goal named like a support exercise takes that one's place.
        let calves = CustomStrengthGoal(exercise: "Standing Calf Raise", kind: .weightReps, targetLb: 300, targetReps: 10, day: "squat")
        if replaced(by: calves, goals: [])?.exercise != "Standing Calf Raise" {
            errors.append("a goal with a support exercise's name should replace that exercise")
        }

        // Auto picks the day of that body half with the most room: Deadlift Day for lower body, Arms Day for upper body.
        if autoDay(lowerBody: true, goals: [])?.id != "deadlift" || autoDay(lowerBody: false, goals: [])?.id != "arms"
            || autoDay(lowerBody: true, goals: targets.custom)?.id != "squat" || autoDay(lowerBody: false, goals: [lSit]) != nil {
            errors.append("auto should pick Deadlift Day, Arms Day, then Squat Day, and nil when no upper day has room")
        }

        // A skip counts today's split day as done yesterday and moves today to the next day, one time only.
        var skipped = GameSnapshot.fresh(catalog: catalog, now: now)
        let skipToday = QuestDay.key(for: now)
        let skipYesterday = QuestDay.key(byAddingDays: -1, to: skipToday)
        let benchDone = QuestRecord(title: "Bench Press 3×3-5", kind: .daily, stat: .STR, method: .hevySets, params: [:],
                                    target: 3, done: 3, unit: "sets", status: .completed)
        skipped.questHistory = [
            QuestDayRecord(dayKey: skipYesterday, mode: .fullRecovery, trainingBand: .green, noGym: false,
                           generatedBy: "mock", missedRequired: false, quests: []),
            QuestDayRecord(dayKey: QuestDay.key(byAddingDays: -4, to: skipToday), mode: .performanceTraining, trainingBand: .green, noGym: false,
                           splitDay: "bench", generatedBy: "mock", missedRequired: false, quests: [benchDone]),
        ]
        if skipped.skipSplitDay("press", catalog: catalog, now: now) == nil {
            errors.append("a skip should refuse a day that is not today's split day")
        }
        if skipped.skipSplitDay("squat", catalog: catalog, now: now) != nil || today(history: skipped.questHistory, dayKey: skipToday).id != "press"
            || skipped.bundle.headerLine != "Press Day" || skipped.generatedBundle != nil || skipped.generationAttemptDayKey != nil
            || skipped.questHistory.first?.mode != .fullRecovery || skipped.skipSplitDay("squat", catalog: catalog, now: now) == nil {
            errors.append("a skip should move today from Squat Day to Press Day, keep yesterday's mode, and run once")
        }
        // The skip changes no day that was done: the records keep their split days and quests, and Squat Day has no done date.
        if skipped.questHistory.first?.splitDay != nil || skipped.questHistory.first?.quests.isEmpty != true
            || lastDone(history: skipped.questHistory) != ["Bench Day": QuestDay.key(byAddingDays: -4, to: skipToday)] {
            errors.append("a skip should not change a past day or count as a done day, got \(lastDone(history: skipped.questHistory))")
        }
        // A real Bench Day yesterday stays a Bench Day after Squat Day is skipped.
        var afterBench = GameSnapshot.fresh(catalog: catalog, now: now)
        afterBench.questHistory = [QuestDayRecord(dayKey: skipYesterday, mode: .performanceTraining, trainingBand: .green, noGym: false,
                                                  splitDay: "bench", generatedBy: "mock", missedRequired: false, quests: [benchDone])]
        if afterBench.skipSplitDay("squat", catalog: catalog, now: now) != nil || afterBench.bundle.headerLine != "Press Day"
            || afterBench.questHistory.first?.splitDay != "bench" || afterBench.questHistory.first?.quests != [benchDone]
            || lastDone(history: afterBench.questHistory) != ["Bench Day": skipYesterday] {
            errors.append("a skip after a real Bench Day should keep that day as Bench Day")
        }
        // The app was closed yesterday: the skip goes on the newest past day. With no past day at all, it says why not.
        var gap = GameSnapshot.fresh(catalog: catalog, now: now)
        gap.questHistory = [QuestDayRecord(dayKey: QuestDay.key(byAddingDays: -3, to: skipToday), mode: .performanceTraining, trainingBand: .green,
                                           noGym: false, splitDay: "bench", generatedBy: "mock", missedRequired: false, quests: [benchDone])]
        var firstDay = GameSnapshot.fresh(catalog: catalog, now: now)
        if gap.skipSplitDay("squat", catalog: catalog, now: now) != nil || gap.bundle.headerLine != "Press Day"
            || firstDay.skipSplitDay("bench", catalog: catalog, now: now) == nil || firstDay.bundle.headerLine != "Bench Day" {
            errors.append("a skip should use the newest past day, and refuse with a reason when there is none")
        }
        // A day that became a rest day after its lifts still moves the split on.
        var rested = GameSnapshot.fresh(catalog: catalog, now: now)
        for quest in rested.bundle.quests where quest.stat == .STR && quest.kind == .daily {
            _ = rested.apply(.completed(evidence: Evidence.make(source: "manual_confirm", externalId: "rested-\(quest.id)", payload: quest.id, timestamp: now)),
                             questId: quest.id, now: now)
        }
        _ = rested.spendFullRecovery(catalog: catalog, now: now)
        rested.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if rested.questHistory.first?.mode != .fullRecovery || rested.questHistory.first?.splitDay != "bench" || rested.bundle.headerLine != "Squat Day" {
            errors.append("Bench Day lifts before a Full Recovery token should move the split to Squat Day, got \(rested.bundle.headerLine)")
        }

        // The offline day, the context, and the mock generator all carry the goal on Deadlift Day.
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        let pressDone = QuestRecord(title: "Overhead Press 3×1-5", kind: .daily, stat: .STR, method: .hevySets, params: [:],
                                    target: 4, done: 4, unit: "sets", status: .completed)
        snapshot.questHistory = [QuestDayRecord(dayKey: "2026-10-04", mode: .performanceTraining, trainingBand: .green, noGym: false,
                                                splitDay: "press", generatedBy: "mock", missedRequired: false, quests: [pressDone])]
        var goalCatalog = catalog
        goalCatalog.strengthGoals = [hipThrust]
        snapshot.rebuildBundle(catalog: goalCatalog, now: now)
        let titles = snapshot.bundle.quests.map(\.title)
        if snapshot.bundle.headerLine != "Deadlift Day" || !titles.contains("Hip Thrust 3×5-9") || !titles.contains(where: { $0.hasPrefix("Lying Leg Curl") }) {
            errors.append("the offline Deadlift Day should train Hip Thrust next to its own exercises, got \(snapshot.bundle.headerLine) \(titles)")
        }
        var kept = StatTargets()
        _ = kept.add(hipThrust)
        let context = ContextBuilder.make(snapshot: snapshot, now: now, targets: kept)
        let target = context.goals?.strength.first { $0.category == "Hip Thrust" }
        if context.split?.today.exercises.contains(where: { $0.exercise == "Hip Thrust" && $0.custom }) != true
            || target?.targetLb != 225 || target?.targetReps != 5 || target?.custom != true || target?.aliases != ["hip thrust"]
            || target?.splitDay != "Deadlift Day" || target?.goal != "225 lb × 5" {
            errors.append("the context should carry Hip Thrust as a strength target and on today's split day, got \(String(describing: target))")
        }
        let mock = MockQuestGenerateClient(catalog: catalog).bundle(for: context, now: now)
        guard let thrustRow = mock.quests.first(where: { $0.verification.params["exercise"]?.stringValue == "Hip Thrust" }) else {
            errors.append("the generated bundle should keep the Hip Thrust row, got \(mock.quests.map(\.title))")
            return errors
        }

        // The Hevy check finds the goal's sets by name, with the equipment in brackets.
        var lifted = DayIntegrationSnapshot.empty(dayKey: mock.dayKey)
        let sets = Array(repeating: StrengthLevel.workingSet(lb: 185, reps: 6), count: 3)
        lifted.hevy = HevyDayReading(available: true, configured: true, reason: "", dayKey: mock.dayKey,
                                     workouts: [StrengthLevel.workout([HevyExercise(title: "Hip Thrust (Barbell)", sets: sets)], daysAgo: 0, now: now)])
        let verification = VerificationContext(now: now, dayKey: mock.dayKey, assignedAt: now, manualConfirmsToday: 0, claimedKeys: [],
                                               timerElapsedSec: nil, userConfirmed: false, integrations: lifted)
        if case .completed = HevySetsVerifier().evaluate(quest: thrustRow, context: verification) {} else {
            errors.append("the Hevy check should complete Hip Thrust 3×5-9 from 3 sets of \"Hip Thrust (Barbell)\"")
        }
        return errors
    }
}

extension GameSnapshot {
    /// Skips today's split day: marks it as skipped on the newest past day, then plans today again from the next split day.
    /// That past day keeps its mode, its own split day, and its quests, so the rest count and the done dates do not change.
    /// It refuses a day with progress, so nothing done is lost. Returns why it was refused, or nil when the day was skipped.
    mutating func skipSplitDay(_ id: String, catalog: FallbackCatalog, now: Date) -> String? {
        let dayKey = QuestDay.key(for: now)
        guard let day = GymSplit.day(id: id) else {
            return "\"\(id)\" is not a split day. Use one of: \(GymSplit.rotation.map(\.id).joined(separator: ", "))."
        }
        guard bundle.dayKey == dayKey else { return "The quest day on screen is not today." }
        let planned = GymSplit.today(history: questHistory, dayKey: dayKey)
        guard planned.id == id else { return "Today's split day is \(planned.name), not \(day.name)." }
        guard !bundle.quests.contains(where: { $0.status == .completed }) else { return "A quest is already done today, so the day stays as it is." }
        guard runningTimers.isEmpty else { return "A timer is running, so the day stays as it is." }
        // Newest first, so this is the newest day that ended. `GymSplit.today` reads its skip before any done day.
        guard let index = questHistory.firstIndex(where: { $0.dayKey < dayKey }) else {
            return "No past quest day holds the skip yet. Skip from the second day on."
        }
        questHistory[index].skippedSplitDay = id
        generatedBundle = nil
        generationAttemptDayKey = nil
        rebuildBundle(catalog: catalog, now: now)
        return nil
    }
}

extension Quest {
    /// Sets done and sets asked of a lift row. The gym row adds them up, so each set found in Hevy shows at once,
    /// not only a lift with every set done. A timed row shows minutes; each of its sets is an equal share.
    var liftSets: (done: Int, total: Int) {
        let asked = verification.params["sets"]?.doubleValue ?? (progress.unit == "sets" ? progress.target : 1)
        let total = max(1, Int(asked.rounded()))
        if status == .completed { return (total, total) }
        guard progress.target > 0 else { return (0, total) }
        let share = progress.unit == "sets" ? progress.current : progress.current / progress.target * Double(total)
        return (min(total, max(0, Int(share + 0.001))), total)
    }
}
