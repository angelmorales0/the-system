import Foundation

/// A 4-day upper/lower split built around the STR targets and 5 10Ks a week.
/// Every muscle group is trained twice a rotation; lateral raises and curls, the current focus, three times.
/// Bench press, rows, and squats come twice (heavy and light). Deadlift and overhead press come once:
/// the deadlift is the most tiring lift next to the running, and bench and handstand push-ups train the press muscles again.
/// The two lower days are the only heavy leg days,
/// so the split stays inside the heavy-leg limits next to the running.
/// Days run in order. A day moves on only after one of its lifts is done, so a missed day comes back next.
enum GymSplit {
    static let name = "4-day upper/lower"

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
    }

    struct Day: Codable, Equatable {
        var id: String
        /// Shown in `[Daily Quest: {name} has arrived.]`.
        var name: String
        var focus: String
        var lowerBody: Bool
        var exercises: [Exercise]
    }

    private static func lift(_ exercise: String, _ role: Role, _ sets: Int, _ reps: ClosedRange<Int>, target: String, aliases: [String]) -> Exercise {
        Exercise(exercise: exercise, aliases: aliases, role: role, sets: sets, minReps: reps.lowerBound, maxReps: reps.upperBound, target: target)
    }

    private static func hold(_ exercise: String, _ sets: Int, seconds: Double, target: String, aliases: [String]) -> Exercise {
        Exercise(exercise: exercise, aliases: aliases, role: .accessory, sets: sets, minReps: 0, maxReps: 0, secondsPerSet: seconds, target: target)
    }

    static let bench = Day(id: "bench", name: "Bench Day", focus: "Upper body: chest, back, side delts, biceps", lowerBody: false, exercises: [
        lift("Bench Press", .main, 4, 3...5, target: "Bench press", aliases: StrengthLevel.bench.aliases),
        lift("Bent Over Row", .main, 4, 5...8, target: "Barbell row", aliases: StrengthLevel.row.aliases),
        lift("Lateral Raise", .accessory, 4, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 4, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
        lift("Pull Up", .accessory, 3, 5...20, target: "Pull-ups", aliases: StrengthLevel.pullUps.aliases),
        lift("Chest Dip", .accessory, 3, 5...8, target: "Weighted dips", aliases: StrengthLevel.dips.aliases),
    ])

    static let squat = Day(id: "squat", name: "Squat Day", focus: "Lower body: squat and single-leg work, plus side delts and biceps", lowerBody: true, exercises: [
        lift("Squat", .main, 4, 1...5, target: "Squat", aliases: StrengthLevel.squat.aliases),
        // Sets count both legs: 3 per leg.
        lift("Bulgarian Split Squat", .accessory, 6, 8...12, target: "Bulgarian split squat", aliases: StrengthLevel.bulgarianSplitSquat.aliases),
        lift("Lateral Raise", .accessory, 3, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 3, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
        lift("Pistol Squat", .accessory, 6, 3...10, target: "Pistol squats", aliases: StrengthLevel.pistolAliases),
        lift("Toes To Bar", .accessory, 3, 5...10, target: "Toes-to-bar", aliases: StrengthLevel.toesToBar.aliases),
    ])

    static let press = Day(id: "press", name: "Press Day", focus: "Upper body: shoulders, back, chest, biceps", lowerBody: false, exercises: [
        lift("Overhead Press", .main, 4, 1...5, target: "Overhead press", aliases: StrengthLevel.overheadPress.aliases),
        lift("Pull Up", .accessory, 4, 5...20, target: "Pull-ups", aliases: StrengthLevel.pullUps.aliases),
        lift("Lateral Raise", .accessory, 4, 8...12, target: "Lateral raise", aliases: StrengthLevel.lateralRaise.aliases),
        lift("Bicep Curl", .accessory, 4, 8...12, target: "Dumbbell curl", aliases: StrengthLevel.curl.aliases),
        lift("Bench Press", .light, 3, 6...8, target: "Bench press", aliases: StrengthLevel.bench.aliases),
        lift("Handstand Push Up", .accessory, 3, 1...5, target: "Handstand push-ups", aliases: StrengthLevel.handstandPushUps.aliases),
    ])

    static let deadlift = Day(id: "deadlift", name: "Deadlift Day", focus: "Lower body and back: deadlift, rows, grip, and core", lowerBody: true, exercises: [
        lift("Deadlift", .main, 3, 1...5, target: "Deadlift", aliases: StrengthLevel.deadlift.aliases),
        lift("Squat", .light, 3, 8...8, target: "Squat", aliases: StrengthLevel.squat.aliases),
        lift("Bent Over Row", .light, 3, 8...10, target: "Barbell row", aliases: StrengthLevel.row.aliases),
        hold("Farmers Walk", 3, seconds: 60, target: "Farmer's carry", aliases: StrengthLevel.farmerAliases),
        lift("Toes To Bar", .accessory, 3, 5...10, target: "Toes-to-bar", aliases: StrengthLevel.toesToBar.aliases),
        hold("Dead Hang", 3, seconds: 60, target: "Dead hang", aliases: StrengthLevel.hangAliases),
    ])

    /// The player's top focus right now. Each is trained 3 times a rotation, and is never dropped for time.
    static let focusTargets = ["Lateral raise", "Dumbbell curl"]
    /// At most this many lifts a day, so a day with two 10Ks still fits the quest limits.
    static let maxExercisesPerDay = 6

    /// Upper and lower alternate, so lifting on back-to-back days never puts two leg days together.
    static let rotation = [bench, squat, press, deadlift]

    static func day(named name: String) -> Day? {
        rotation.first { $0.name == name }
    }

    static func day(id: String) -> Day? {
        rotation.first { $0.id == id }
    }

    /// The next day in the rotation after the newest past day whose lifts were started.
    /// `history` is newest first. With no lifting yet, the split starts at Bench Day.
    static func today(history: [QuestDayRecord], dayKey: String) -> Day {
        let done = history.first { record in
            record.dayKey < dayKey && record.splitDay != nil && record.quests.contains { $0.stat == .STR && $0.status == .completed }
        }
        guard let id = done?.splitDay, let index = rotation.firstIndex(where: { $0.id == id }) else { return rotation[0] }
        return rotation[(index + 1) % rotation.count]
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
        func isLift(_ quest: Quest) -> Bool { TrainingDay.isStrength(quest) && quest.id != DailyStretch.questId && quest.kind == .daily }
        guard bundle.mode == .performanceTraining, bundle.quests.contains(where: isLift) else { return bundle }
        var copy = bundle
        copy.headerLine = day.name
        copy.quests.removeAll(where: isLift)
        let rows = day.exercises.map { quest(for: $0, band: band, dayKey: bundle.dayKey, now: now) }
        let insertAt = copy.quests.lastIndex { $0.kind == .daily }.map { $0 + 1 } ?? copy.quests.count
        copy.quests.insert(contentsOf: rows, at: insertAt)
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
            id: "q_\(dayKey)_\(slug)\(exercise.role == .light ? "_light" : "")",
            title: title,
            kind: .daily,
            stat: .STR,
            verification: VerificationSpec(method: .hevySets, params: params),
            deadline: QuestDay.endOfDay(now),
            xp: exercise.role == .main ? 25 : 15,
            difficulty: exercise.role == .main ? .hard : .normal,
            mode: .performanceTraining,
            progress: progress,
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: now
        )
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        guard let now = QuestDay.date(from: "2026-10-05") else { return ["quest day failed to parse"] }
        let catalog = FallbackCatalog.bundled()

        // Every exercise trains a real STR target, and every STR target is in the split.
        let targets = Set(StrengthLevel.evaluate(workouts: [], now: now).requirements.map(\.category))
        let trained = Set(rotation.flatMap { $0.exercises.map(\.target) })
        if !trained.isSubset(of: targets) || trained != targets {
            errors.append("the split should train exactly the STR targets, missing \(targets.subtracting(trained).sorted()), extra \(trained.subtracting(targets).sorted())")
        }
        if rotation.map(\.lowerBody) != [false, true, false, true] {
            errors.append("upper and lower days should alternate")
        }
        for day in rotation where day.exercises.count > maxExercisesPerDay {
            errors.append("\(day.name) should have at most \(maxExercisesPerDay) exercises so the day fits the quest limits")
        }
        if maxExercisesPerDay + NoGymDay.runCount > MorningConstraints.standard.maxRequiredQuests || maxExercisesPerDay + NoGymDay.runCount > QuestSafety.maxQuests {
            errors.append("a full split day with two 10Ks should fit the quest limits")
        }
        // Each target twice a rotation; the focus targets three times. The lifts below once, for the reasons above.
        let once: Set<String> = ["Deadlift", "Overhead press", "Pistol squats", "Farmer's carry", "Weighted dips", "Dead hang", "Handstand push-ups", "Bulgarian split squat"]
        for target in targets {
            let count = rotation.filter { day in day.exercises.contains { $0.target == target } }.count
            let expected = focusTargets.contains(target) ? 3 : once.contains(target) ? 1 : 2
            if count != expected {
                errors.append("\(target) should be trained \(expected) times a rotation, got \(count)")
            }
        }
        for day in rotation where day.exercises.contains(where: { StretchTime.isStretchExercise($0.exercise) }) {
            errors.append("\(day.name) must not hold a stretch; the Stretching row covers that")
        }

        // A fresh game starts at Bench Day, and the catalog day uses its exercises.
        var snapshot = GameSnapshot.fresh(catalog: catalog, now: now)
        if snapshot.bundle.headerLine != "Bench Day" || !snapshot.bundle.quests.contains(where: { $0.title == "Bench Press 4×3-5" }) {
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
        if snapshot.bundle.headerLine != "Bench Day" {
            errors.append("after Deadlift Day the split should start again at Bench Day, got \(snapshot.bundle.headerLine)")
        }
        if lastDone(history: snapshot.questHistory)["Squat Day"] != QuestDay.key(for: now.addingTimeInterval(2 * 86_400)) {
            errors.append("the last Squat Day should be the one that was done, got \(lastDone(history: snapshot.questHistory))")
        }

        // Yellow takes one set off the main lift only; the light squat stays a non-heavy 3×8.
        let yellow = apply(deadlift, to: catalog.makeBundle(mode: .performanceTraining, band: .green, dayKey: "2026-10-05", now: now), band: .yellow, now: now)
        if yellow.quests.first(where: { $0.title.hasPrefix("Deadlift") })?.title != "Deadlift 2×1-5"
            || !yellow.quests.contains(where: { $0.title == "Squat 3×8" && $0.verification.params["minReps"]?.doubleValue == 8 }) {
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
        return errors
    }
}
