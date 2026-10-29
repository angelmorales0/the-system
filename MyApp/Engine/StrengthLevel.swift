import Foundation

/// Deterministic STR level 0...350 from Hevy workouts.
/// Pure: the same workouts and `now` always give the same report. No network.
/// Only working sets from the last 180 days count, because strength fades.
/// Hevy cannot show "strict" form (no kipping, full range), so a logged set counts as strict.
enum StrengthLevel {
    static let windowDays = 180
    /// A set within 0.5% of the target weight passes, so 102.5 kg counts as 225 lb but 100 kg (220.5 lb) does not.
    static let weightTolerance = 0.005
    static let weight = 100.0 / 15

    /// One barbell or dumbbell lift scored by weight × reps.
    struct Lift: Equatable {
        var category: String
        var aliases: [String]
        /// Level 0 weight in lb, at the same reps as the target.
        var floorLb: Double
        var targetLb: Double
        var targetReps: Int
        /// True when the weight is added to bodyweight (a dip belt). A set with no weight then counts as 0 lb.
        var addedWeight = false

        /// Estimated one-rep max band in lb: floor weight × target reps up to target weight × target reps.
        var band: StatLevel.Band {
            StatLevel.Band(
                floor: StatLevel.estimatedOneRepMax(weight: floorLb, reps: targetReps),
                target: StatLevel.estimatedOneRepMax(weight: targetLb, reps: targetReps)
            )
        }
    }

    /// One bodyweight movement scored by reps in a single set.
    struct RepRule: Equatable {
        var category: String
        var aliases: [String]
        var targetReps: Int

        var band: StatLevel.Band { StatLevel.Band(floor: 0, target: Double(targetReps)) }
    }

    // Floors are a common untrained start (an empty bar or a light dumbbell); targets are the max level rules.
    static let squat = Lift(category: "Squat", aliases: ["squat"], floorLb: 95, targetLb: 315, targetReps: 1)
    static let deadlift = Lift(category: "Deadlift", aliases: ["deadlift"], floorLb: 135, targetLb: 405, targetReps: 1)
    static let bench = Lift(category: "Bench press", aliases: ["bench press"], floorLb: 95, targetLb: 225, targetReps: 3)
    /// Barbell presses only. "Shoulder press" is usually a dumbbell or machine press, so it does not count.
    static let overheadPress = Lift(category: "Overhead press", aliases: ["overhead press", "strict press"], floorLb: 45, targetLb: 155, targetReps: 1)
    static let row = Lift(category: "Barbell row", aliases: ["bent over row", "barbell row", "pendlay row"], floorLb: 95, targetLb: 225, targetReps: 3)
    static let lateralRaise = Lift(category: "Lateral raise", aliases: ["lateral raise"], floorLb: 5, targetLb: 30, targetReps: 8)
    static let curl = Lift(category: "Dumbbell curl", aliases: ["bicep curl", "biceps curl", "dumbbell curl"], floorLb: 10, targetLb: 40, targetReps: 8)
    /// Dumbbells, weight per hand as Hevy logs it. Scored per leg like pistol squats: one set per leg on the same day.
    static let bulgarianSplitSquat = Lift(category: "Bulgarian split squat", aliases: ["bulgarian split squat", "bulgarian split squats"], floorLb: 15, targetLb: 80, targetReps: 8)
    /// Added weight only: two plates (90 lb) on a belt for 5 reps. Bodyweight dips count as 0 lb added.
    static let dips = Lift(category: "Weighted dips", aliases: ["dip", "dips", "chest dip", "chest dips", "triceps dip", "triceps dips", "tricep dip", "tricep dips", "weighted dip", "weighted dips"], floorLb: 0, targetLb: 90, targetReps: 5, addedWeight: true)
    static let lifts = [squat, deadlift, bench, overheadPress, row, lateralRaise, curl, bulgarianSplitSquat, dips]

    /// Strict pull-ups only. Chin-ups use a supinated grip and do not count.
    static let pullUps = RepRule(category: "Pull-ups", aliases: ["pull up", "pull ups", "pullup", "pullups"], targetReps: 20)
    static let handstandPushUps = RepRule(category: "Handstand push-ups", aliases: ["handstand push up", "handstand push ups"], targetReps: 5)
    static let toesToBar = RepRule(category: "Toes-to-bar", aliases: ["toes to bar"], targetReps: 10)

    static let pistolAliases = ["pistol squat", "pistol squats"]
    static let pistolBand = StatLevel.Band(floor: 0, target: 10)

    static let farmerAliases = ["farmers walk", "farmer's walk", "farmers carry", "farmer's carry"]
    /// Weight per hand in lb and hold time in seconds.
    static let farmerTargetLb = 100.0
    static let farmerTargetSec = 60.0
    /// Band on the product min(1, lb / 100) × min(1, sec / 60).
    static let farmerBand = StatLevel.Band(floor: 0, target: 1)

    static let hangAliases = ["dead hang", "hang"]
    static let hangBand = StatLevel.Band(floor: 0, target: 120) // seconds

    /// Every built-in STR target, alias, and category, normalized. A custom goal may not use one of these names.
    static let builtInNames: Set<String> = {
        let aliases = lifts.flatMap(\.aliases) + [pullUps, handstandPushUps, toesToBar].flatMap(\.aliases)
            + pistolAliases + farmerAliases + hangAliases
        let categories = evaluate(workouts: [], now: Date(timeIntervalSince1970: 0)).requirements.map(\.category)
        return Set((aliases + categories).map { normalizedName($0) })
    }()

    /// `custom` are the player's own goals. Each one scores from the same Hevy sets as the built-in targets:
    /// weight × reps by the Epley e1RM (floor: a third of the target weight), reps by the best set, holds by the longest set.
    /// Weights: each custom goal first gets the average built-in weight; then all weights scale back to 100 in the same ratio.
    /// The max level needs every target passed, custom goals too.
    static func evaluate(workouts: [HevyWorkout], custom: [CustomStrengthGoal] = [], now: Date) -> StatLevelReport {
        let start = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let recent = workouts.filter { $0.start >= start && $0.start <= now }
        let builtIn = builtInRequirements(recent)
        return StatLevelReport(stat: .STR, requirements: withCustom(builtIn, custom.map { customGoal($0, recent) }))
    }

    /// Gives each custom requirement the average built-in weight, then scales every weight so they add to 100.
    /// 15 built-in targets at 6.67 and one custom goal: 16 targets at 6.25. Two custom goals: 17 at 5.88.
    static func withCustom(_ builtIn: [StatRequirement], _ custom: [StatRequirement]) -> [StatRequirement] {
        guard !custom.isEmpty, !builtIn.isEmpty else { return builtIn + custom }
        let average = builtIn.reduce(0) { $0 + $1.weight } / Double(builtIn.count)
        let all = builtIn + custom.map { requirement in
            var weighted = requirement
            weighted.weight = average
            return weighted
        }
        let total = all.reduce(0) { $0 + $1.weight }
        return all.map { requirement in
            var scaled = requirement
            scaled.weight = requirement.weight * 100 / total
            return scaled
        }
    }

    private static func customGoal(_ goal: CustomStrengthGoal, _ workouts: [HevyWorkout]) -> StatRequirement {
        if let rule = goal.lift { return lift(rule, workouts) }
        if let rule = goal.repRule { return repRule(rule, workouts) }
        return hold(goal.category, aliases: [goal.alias], band: StatLevel.Band(floor: 0, target: goal.targetSeconds), workouts)
    }

    private static func builtInRequirements(_ recent: [HevyWorkout]) -> [StatRequirement] {
        [
            lift(squat, recent),
            lift(deadlift, recent),
            lift(bench, recent),
            lift(overheadPress, recent),
            lift(row, recent),
            lift(dips, recent),
            repRule(pullUps, recent),
            farmersCarry(recent),
            pistolSquats(recent),
            perLegLift(bulgarianSplitSquat, recent),
            repRule(handstandPushUps, recent),
            lift(lateralRaise, recent),
            lift(curl, recent),
            repRule(toesToBar, recent),
            hold("Dead hang", aliases: hangAliases, band: hangBand, recent),
        ]
    }

    // MARK: - Exercise matching

    /// "Pull-Up (Weighted)" → "pull up". Hyphens become spaces so "Toes-To-Bar" and "Toes To Bar" match.
    static func normalizedName(_ title: String) -> String {
        HevySetsVerifier.baseName(title)
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Working sets of any exercise whose name matches one alias.
    private static func workingSets(_ aliases: [String], _ workouts: [HevyWorkout]) -> [HevySet] {
        workouts.flatMap { workingSets(aliases, in: $0) }
    }

    private static func workingSets(_ aliases: [String], in workout: HevyWorkout) -> [HevySet] {
        workout.exercises
            .filter { aliases.contains(normalizedName($0.title)) }
            .flatMap(\.sets)
            .filter(\.isWorking)
    }

    private static func meetsWeight(_ pounds: Double, _ target: Double) -> Bool {
        pounds * (1 + weightTolerance) >= target
    }

    // MARK: - Rules

    /// Strict rule: one working set at the target weight (0.5% tolerance) for the target reps.
    /// Progress: best estimated one-rep max on the e1RM band. A pass is full progress.
    private static func lift(_ rule: Lift, _ workouts: [HevyWorkout]) -> StatRequirement {
        let sets = workingSets(rule.aliases, workouts).compactMap { set -> (pounds: Double, reps: Int)? in
            guard let reps = set.reps, reps > 0 else { return nil }
            let kg = set.weightKg ?? 0
            guard kg > 0 || rule.addedWeight else { return nil }
            return (StatLevel.pounds(fromKilograms: max(kg, 0)), reps)
        }
        guard let best = sets.max(by: { e1RM($0) < e1RM($1) }) else { return missing(rule.category) }
        let passed = sets.contains { meetsWeight($0.pounds, rule.targetLb) && $0.reps >= rule.targetReps }
        let sign = rule.addedWeight ? "+" : ""
        return StatRequirement(
            category: rule.category,
            passed: passed,
            progress: passed ? 1 : rule.band.progress(e1RM(best)),
            weight: weight,
            detail: "best \(sign)\(format(best.pounds)) lb × \(best.reps) (e1RM \(format(e1RM(best))) lb)"
        )
    }

    /// Dumbbell lifts done one leg at a time. Hevy cannot tell the legs apart, so each day scores its
    /// second-best working set by e1RM (the reps need one set per leg). The best day in the window counts.
    /// Strict rule: one day with two working sets at the target weight (0.5% tolerance) for the target reps.
    private static func perLegLift(_ rule: Lift, _ workouts: [HevyWorkout]) -> StatRequirement {
        var setsByDay: [String: [(pounds: Double, reps: Int)]] = [:]
        for workout in workouts {
            let sets = workingSets(rule.aliases, in: workout).compactMap { set -> (pounds: Double, reps: Int)? in
                guard let kg = set.weightKg, kg > 0, let reps = set.reps, reps > 0 else { return nil }
                return (StatLevel.pounds(fromKilograms: kg), reps)
            }
            setsByDay[QuestDay.key(for: workout.start), default: []] += sets
        }
        guard setsByDay.values.contains(where: { !$0.isEmpty }) else { return missing(rule.category) }
        let secondBests = setsByDay.values.compactMap { sets -> (pounds: Double, reps: Int)? in
            let sorted = sets.sorted { e1RM($0) > e1RM($1) }
            return sorted.count >= 2 ? sorted[1] : nil
        }
        guard let best = secondBests.max(by: { e1RM($0) < e1RM($1) }) else {
            return StatRequirement(category: rule.category, passed: false, progress: 0, weight: weight,
                                   detail: "only one working set per day; log one set per leg")
        }
        let passed = setsByDay.values.contains { sets in
            sets.filter { meetsWeight($0.pounds, rule.targetLb) && $0.reps >= rule.targetReps }.count >= 2
        }
        return StatRequirement(
            category: rule.category,
            passed: passed,
            progress: passed ? 1 : rule.band.progress(e1RM(best)),
            weight: weight,
            detail: "best \(format(best.pounds)) lb/hand × \(best.reps) per leg (e1RM \(format(e1RM(best))) lb)"
        )
    }

    /// Strict rule and progress: most reps in one working set.
    private static func repRule(_ rule: RepRule, _ workouts: [HevyWorkout]) -> StatRequirement {
        let reps = workingSets(rule.aliases, workouts).compactMap(\.reps).filter { $0 > 0 }
        guard let best = reps.max() else { return missing(rule.category) }
        return StatRequirement(
            category: rule.category,
            passed: best >= rule.targetReps,
            progress: rule.band.progress(Double(best)),
            weight: weight,
            detail: "best \(best) reps"
        )
    }

    /// Hevy cannot tell the left leg from the right. Each day scores its second-best working set,
    /// so the reps need two sets (one per leg). The best day in the window counts.
    private static func pistolSquats(_ workouts: [HevyWorkout]) -> StatRequirement {
        var repsByDay: [String: [Int]] = [:]
        for workout in workouts {
            let reps = workingSets(pistolAliases, in: workout).compactMap(\.reps).filter { $0 > 0 }
            repsByDay[QuestDay.key(for: workout.start), default: []] += reps
        }
        guard repsByDay.values.contains(where: { !$0.isEmpty }) else { return missing("Pistol squats") }
        let best = repsByDay.values.map { reps -> Int in
            let sorted = reps.sorted(by: >)
            return sorted.count >= 2 ? sorted[1] : 0
        }.max() ?? 0
        return StatRequirement(
            category: "Pistol squats",
            passed: Double(best) >= pistolBand.target,
            progress: pistolBand.progress(Double(best)),
            weight: weight,
            detail: best > 0 ? "best \(best) reps per leg" : "only one working set per day; log one set per leg"
        )
    }

    /// Weight is per hand. A set needs a duration: a set with only distance does not count.
    /// Progress: best min(1, lb / 100) × min(1, sec / 60). Strict rule: one set at 100 lb (0.5% tolerance) for 60 sec.
    private static func farmersCarry(_ workouts: [HevyWorkout]) -> StatRequirement {
        let sets = workingSets(farmerAliases, workouts).compactMap { set -> (pounds: Double, seconds: Double)? in
            guard let kg = set.weightKg, kg > 0, let seconds = set.durationSec, seconds > 0 else { return nil }
            return (StatLevel.pounds(fromKilograms: kg), seconds)
        }
        func score(_ set: (pounds: Double, seconds: Double)) -> Double {
            min(1, set.pounds / farmerTargetLb) * min(1, set.seconds / farmerTargetSec)
        }
        guard let best = sets.max(by: { score($0) < score($1) }) else { return missing("Farmer's carry") }
        let passed = sets.contains { meetsWeight($0.pounds, farmerTargetLb) && $0.seconds >= farmerTargetSec }
        return StatRequirement(
            category: "Farmer's carry",
            passed: passed,
            progress: passed ? 1 : farmerBand.progress(score(best)),
            weight: weight,
            detail: "best \(format(best.pounds)) lb/hand × \(format(best.seconds)) sec"
        )
    }

    /// Strict rule and progress: longest single hold (the dead hang, or a custom hold goal).
    private static func hold(_ category: String, aliases: [String], band: StatLevel.Band, _ workouts: [HevyWorkout]) -> StatRequirement {
        let durations = workingSets(aliases, workouts).compactMap(\.durationSec).filter { $0 > 0 }
        guard let best = durations.max() else { return missing(category) }
        return StatRequirement(
            category: category,
            passed: best >= band.target,
            progress: band.progress(best),
            weight: weight,
            detail: "best \(format(best)) sec"
        )
    }

    // MARK: - Shared

    private static func e1RM(_ set: (pounds: Double, reps: Int)) -> Double {
        StatLevel.estimatedOneRepMax(weight: set.pounds, reps: set.reps)
    }

    private static func missing(_ category: String) -> StatRequirement {
        StatRequirement(category: category, passed: false, progress: 0, weight: weight, detail: "no logged sets in \(windowDays) days")
    }

    private static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func kilograms(_ pounds: Double) -> Double { pounds / StatLevel.poundsPerKilogram }

    static func workingSet(lb: Double? = nil, reps: Int? = nil, seconds: Double? = nil, type: String = "normal") -> HevySet {
        HevySet(type: type, reps: reps, weightKg: lb.map { $0 / StatLevel.poundsPerKilogram }, rpe: nil, durationSec: seconds)
    }

    static func workout(_ exercises: [HevyExercise], daysAgo: Double, now: Date, id: String = "w") -> HevyWorkout {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return HevyWorkout(id: id, title: "Workout", start: start, end: start.addingTimeInterval(3_600), exercises: exercises)
    }

    /// One workout that meets every the max level requirement. Tests edit a copy.
    static func perfectWorkouts(now: Date) -> [HevyWorkout] {
        [workout([
            HevyExercise(title: "Squat (Barbell)", sets: [workingSet(lb: 315, reps: 1)]),
            HevyExercise(title: "Deadlift (Barbell)", sets: [workingSet(lb: 405, reps: 1)]),
            HevyExercise(title: "Bench Press (Barbell)", sets: [workingSet(lb: 225, reps: 3)]),
            HevyExercise(title: "Overhead Press (Barbell)", sets: [workingSet(lb: 155, reps: 1)]),
            HevyExercise(title: "Bent Over Row (Barbell)", sets: [workingSet(lb: 225, reps: 3)]),
            HevyExercise(title: "Chest Dip (Weighted)", sets: [workingSet(lb: 90, reps: 5)]),
            HevyExercise(title: "Pull Up", sets: [workingSet(reps: 20)]),
            HevyExercise(title: "Farmers Walk", sets: [workingSet(lb: 100, seconds: 60)]),
            HevyExercise(title: "Pistol Squat", sets: [workingSet(reps: 10), workingSet(reps: 10)]),
            HevyExercise(title: "Bulgarian Split Squat (Dumbbell)", sets: [workingSet(lb: 80, reps: 8), workingSet(lb: 80, reps: 8)]),
            HevyExercise(title: "Handstand Push Up", sets: [workingSet(reps: 5)]),
            HevyExercise(title: "Lateral Raise (Dumbbell)", sets: [workingSet(lb: 30, reps: 8)]),
            HevyExercise(title: "Bicep Curl (Dumbbell)", sets: [workingSet(lb: 40, reps: 8)]),
            HevyExercise(title: "Toes-To-Bar", sets: [workingSet(reps: 10)]),
            HevyExercise(title: "Dead Hang", sets: [workingSet(seconds: 120)]),
        ], daysAgo: 1, now: now)]
    }

    /// One workout at every level 0 floor.
    static func floorWorkouts(now: Date) -> [HevyWorkout] {
        [workout([
            HevyExercise(title: "Squat (Barbell)", sets: [workingSet(lb: 95, reps: 1)]),
            HevyExercise(title: "Deadlift (Barbell)", sets: [workingSet(lb: 135, reps: 1)]),
            HevyExercise(title: "Bench Press (Barbell)", sets: [workingSet(lb: 95, reps: 3)]),
            HevyExercise(title: "Overhead Press (Barbell)", sets: [workingSet(lb: 45, reps: 1)]),
            HevyExercise(title: "Bent Over Row (Barbell)", sets: [workingSet(lb: 95, reps: 3)]),
            HevyExercise(title: "Lateral Raise (Dumbbell)", sets: [workingSet(lb: 5, reps: 8)]),
            HevyExercise(title: "Bicep Curl (Dumbbell)", sets: [workingSet(lb: 10, reps: 8)]),
            HevyExercise(title: "Bulgarian Split Squat (Dumbbell)", sets: [workingSet(lb: 15, reps: 8), workingSet(lb: 15, reps: 8)]),
            // Bodyweight dips: logged, but 0 lb added.
            HevyExercise(title: "Chest Dip", sets: [workingSet(reps: 12)]),
            HevyExercise(title: "Farmers Walk", sets: [workingSet(lb: 100, reps: nil, seconds: nil)]),
            HevyExercise(title: "Pistol Squat", sets: [workingSet(reps: 6)]),
        ], daysAgo: 1, now: now)]
    }

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let perfect = perfectWorkouts(now: now)
        let report = evaluate(workouts: perfect, now: now)
        if !report.isMaxLevel || report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 {
            errors.append("perfect workouts should reach the max level and score 100, got level \(report.level) score \(report.score), failing: "
                + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 15 {
            errors.append("STR should have 15 requirements, got \(report.requirements.count)")
        }
        let totalWeight = report.requirements.reduce(0) { $0 + $1.weight }
        if abs(totalWeight - 100) > 0.001 {
            errors.append("weights should add to 100, got \(totalWeight)")
        }

        let empty = evaluate(workouts: [], now: now)
        if empty.level != 0 || empty.score != 0 || empty.isMaxLevel {
            errors.append("no workouts must be level 0, got level \(empty.level) score \(empty.score)")
        }
        if empty.requirements.first?.detail != "no logged sets in 180 days" {
            errors.append("a missing exercise should say so, got \(String(describing: empty.requirements.first?.detail))")
        }

        let floorReport = evaluate(workouts: floorWorkouts(now: now), now: now)
        if floorReport.level != 0 || floorReport.score > 0.001 {
            errors.append("floor workouts should be level 0, got level \(floorReport.level) score \(floorReport.score): "
                + floorReport.requirements.map { "\($0.category) \($0.points)" }.joined(separator: ", "))
        }

        func row(_ category: String, _ workouts: [HevyWorkout]) -> StatRequirement? {
            evaluate(workouts: workouts, now: now).requirements.first { $0.category == category }
        }

        /// Replaces the sets (or the title) of one exercise in the perfect workout.
        func edited(_ title: String, newTitle: String? = nil, sets: [HevySet]? = nil) -> [HevyWorkout] {
            var copy = perfect
            for index in copy[0].exercises.indices where copy[0].exercises[index].title == title {
                if let newTitle { copy[0].exercises[index].title = newTitle }
                if let sets { copy[0].exercises[index].sets = sets }
            }
            return copy
        }

        func failsOnly(_ category: String, _ workouts: [HevyWorkout], line: Int = #line) {
            let result = evaluate(workouts: workouts, now: now)
            let failing = result.failing.map(\.category)
            if failing != [category] {
                errors.append("line \(line): expected only \(category) to fail, got \(failing)")
            }
            if result.level >= StatLevel.maxLevel {
                errors.append("line \(line): a failing \(category) must stay under the max level, got \(result.level)")
            }
            if result.topGains(1).first?.category != category {
                errors.append("line \(line): \(category) should be the top gain, got \(result.topGains(1).map(\.category))")
            }
        }

        failsOnly("Deadlift", edited("Deadlift (Barbell)", sets: [workingSet(lb: 315, reps: 1)]))
        failsOnly("Pull-ups", edited("Pull Up", sets: [workingSet(reps: 12)]))
        failsOnly("Dead hang", edited("Dead Hang", sets: [workingSet(seconds: 90)]))

        // Weight tolerance: 102.5 kg (226 lb) × 3 passes 225 lb; 100 kg (220.5 lb) × 3 does not.
        let kgBench = { (kg: Double) in edited("Bench Press (Barbell)", sets: [HevySet(type: "normal", reps: 3, weightKg: kg, rpe: nil, durationSec: nil)]) }
        if row("Bench press", kgBench(102.5))?.passed != true {
            errors.append("102.5 kg × 3 should pass the 225 lb bench")
        }
        failsOnly("Bench press", kgBench(100))

        // Warm-up sets never count.
        failsOnly("Squat", edited("Squat (Barbell)", sets: [workingSet(lb: 315, reps: 1, type: "warmup"), workingSet(lb: 225, reps: 1)]))

        // 205 lb × 5 bench: e1RM 239 lb on the 104.5 → 247.5 lb band.
        let partial = row("Bench press", edited("Bench Press (Barbell)", sets: [workingSet(lb: 205, reps: 5)]))
        let expected = bench.band.progress(StatLevel.estimatedOneRepMax(weight: 205, reps: 5))
        if partial?.passed != false || abs((partial?.progress ?? 0) - expected) > 0.0001 || partial?.detail != "best 205 lb × 5 (e1RM 239 lb)" {
            errors.append("205 lb × 5 bench should give progress \(expected) and fail, got \(String(describing: partial))")
        }

        // Sets older than 180 days do not count.
        let old = perfect.map { workout -> HevyWorkout in
            var copy = workout
            copy.start = now.addingTimeInterval(-181 * 86_400)
            return copy
        }
        let oldReport = evaluate(workouts: old, now: now)
        if oldReport.level != 0 {
            errors.append("workouts older than 180 days should not score, got level \(oldReport.level)")
        }

        // "Incline Bench Press (Dumbbell)" is a different lift.
        failsOnly("Bench press", edited("Bench Press (Barbell)", newTitle: "Incline Bench Press (Dumbbell)"))
        if row("Bench press", edited("Bench Press (Barbell)", newTitle: "Incline Bench Press (Dumbbell)"))?.progress != 0 {
            errors.append("incline bench should give no bench progress")
        }

        // Pistol squats need one set per leg on the same day.
        failsOnly("Pistol squats", edited("Pistol Squat", sets: [workingSet(reps: 10)]))
        let split = edited("Pistol Squat", sets: [workingSet(reps: 10)])
            + [workout([HevyExercise(title: "Pistol Squat", sets: [workingSet(reps: 10)])], daysAgo: 3, now: now)]
        failsOnly("Pistol squats", split)
        let uneven = row("Pistol squats", edited("Pistol Squat", sets: [workingSet(reps: 10), workingSet(reps: 6)]))
        if abs((uneven?.progress ?? 0) - 0.6) > 0.0001 {
            errors.append("pistol sets of 10 and 6 should score the weaker leg (0.6), got \(String(describing: uneven))")
        }

        // Farmer's carry at 100 lb for 30 sec is half progress and no pass.
        let halfFarmer = row("Farmer's carry", edited("Farmers Walk", sets: [workingSet(lb: 100, seconds: 30)]))
        if halfFarmer?.passed != false || abs((halfFarmer?.progress ?? 0) - 0.5) > 0.0001 {
            errors.append("farmer's carry 100 lb × 30 sec should be 0.5 progress and fail, got \(String(describing: halfFarmer))")
        }
        // A carry with distance but no duration does not count.
        failsOnly("Farmer's carry", edited("Farmers Walk", sets: [workingSet(lb: 100, reps: nil, seconds: nil)]))

        // Bulgarian split squats need one set per leg on the same day; the weaker set scores.
        failsOnly("Bulgarian split squat", edited("Bulgarian Split Squat (Dumbbell)", sets: [workingSet(lb: 80, reps: 8)]))
        let unevenSplit = row("Bulgarian split squat", edited("Bulgarian Split Squat (Dumbbell)", sets: [workingSet(lb: 80, reps: 8), workingSet(lb: 50, reps: 8)]))
        let unevenExpected = bulgarianSplitSquat.band.progress(StatLevel.estimatedOneRepMax(weight: 50, reps: 8))
        if unevenSplit?.passed != false || abs((unevenSplit?.progress ?? 0) - unevenExpected) > 0.0001 {
            errors.append("split squat sets of 80 and 50 lb should score the 50 lb leg (\(unevenExpected)), got \(String(describing: unevenSplit))")
        }

        // Dips count added weight only. Two plates × 5 passes; 70 lb does not; bodyweight dips log as +0 lb.
        failsOnly("Weighted dips", edited("Chest Dip (Weighted)", sets: [workingSet(lb: 70, reps: 5)]))
        if row("Weighted dips", edited("Chest Dip (Weighted)", newTitle: "Triceps Dip (Weighted)"))?.passed != true {
            errors.append("\"Triceps Dip (Weighted)\" should match weighted dips")
        }
        let bodyweightDips = row("Weighted dips", edited("Chest Dip (Weighted)", newTitle: "Dip", sets: [workingSet(reps: 15)]))
        if bodyweightDips?.progress != 0 || bodyweightDips?.detail != "best +0 lb × 15 (e1RM 0 lb)" {
            errors.append("bodyweight dips should log +0 lb and no progress, got \(String(describing: bodyweightDips))")
        }

        // Chin-ups are not strict pull-ups.
        failsOnly("Pull-ups", edited("Pull Up", newTitle: "Chin Up"))
        if row("Pull-ups", edited("Pull Up", newTitle: "Pull-Up (Weighted)"))?.passed != true {
            errors.append("\"Pull-Up (Weighted)\" should match pull-ups")
        }

        // Custom goals: each one gets the average built-in weight (100/15), then every weight scales back to 100.
        // One goal: 16 targets at 6.25. Two goals: 17 targets at 5.88.
        let hipThrust = CustomStrengthGoal(exercise: "Hip Thrust", kind: .weightReps, targetLb: 225, targetReps: 5, day: "deadlift")
        let lSit = CustomStrengthGoal(exercise: "L-Sit", kind: .hold, targetSeconds: 30, day: "arms")
        let muscleUp = CustomStrengthGoal(exercise: "Muscle Up", kind: .reps, targetReps: 10, day: "arms")
        for goals in [[hipThrust], [hipThrust, lSit]] {
            let custom = evaluate(workouts: perfect, custom: goals, now: now)
            let count = 15 + goals.count
            let weights = custom.requirements.map(\.weight)
            if weights.count != count || abs(weights.reduce(0, +) - 100) > 0.001
                || weights.contains(where: { abs($0 - 100 / Double(count)) > 0.001 }) {
                errors.append("\(goals.count) custom goal(s) should give \(count) targets at \(100 / Double(count)), got \(weights)")
            }
        }

        // The max level needs the custom goals passed too. Without their sets, 15 of 18 targets give level 291.
        let withGoal = evaluate(workouts: perfect, custom: [hipThrust, lSit, muscleUp], now: now)
        if withGoal.isMaxLevel || withGoal.level != 291
            || withGoal.failing.map(\.category) != ["Hip Thrust", "L-Sit", "Muscle Up"] {
            errors.append("unlogged custom goals should block the max level, got \(withGoal.level) failing \(withGoal.failing.map(\.category))")
        }
        var done = perfect
        done[0].exercises += [
            HevyExercise(title: "Hip Thrust (Barbell)", sets: [workingSet(lb: 225, reps: 5)]),
            HevyExercise(title: "L Sit", sets: [workingSet(seconds: 30)]),
            HevyExercise(title: "Muscle-Up", sets: [workingSet(reps: 10)]),
        ]
        let passedGoals = evaluate(workouts: done, custom: [hipThrust, lSit, muscleUp], now: now)
        if !passedGoals.isMaxLevel || passedGoals.level != StatLevel.maxLevel {
            errors.append("passed custom goals should reach the max level, got \(passedGoals.level) failing \(passedGoals.failing.map(\.category))")
        }
        // 205 lb × 5 on a 225 lb × 5 goal: e1RM 239 lb on the 87.5 → 262.5 lb band (floor 75 lb × 5).
        var partialGoal = perfect
        partialGoal[0].exercises.append(HevyExercise(title: "Hip Thrust (Barbell)", sets: [workingSet(lb: 205, reps: 5)]))
        let thrust = evaluate(workouts: partialGoal, custom: [hipThrust], now: now).requirements.first { $0.category == "Hip Thrust" }
        let thrustExpected = (StatLevel.estimatedOneRepMax(weight: 205, reps: 5) - StatLevel.estimatedOneRepMax(weight: 75, reps: 5))
            / (StatLevel.estimatedOneRepMax(weight: 225, reps: 5) - StatLevel.estimatedOneRepMax(weight: 75, reps: 5))
        if thrust?.passed != false || abs((thrust?.progress ?? 0) - thrustExpected) > 0.0001 {
            errors.append("205 lb × 5 hip thrust should give progress \(thrustExpected) and fail, got \(String(describing: thrust))")
        }
        var halfHold = perfect
        halfHold[0].exercises.append(HevyExercise(title: "L-Sit", sets: [workingSet(seconds: 15)]))
        if abs((evaluate(workouts: halfHold, custom: [lSit], now: now).requirements.first { $0.category == "L-Sit" }?.progress ?? 0) - 0.5) > 0.0001 {
            errors.append("a 15 sec L-sit should be half of a 30 sec goal")
        }
        if !builtInNames.contains("bench press") || !builtInNames.contains("dead hang") || builtInNames.contains("hip thrust") {
            errors.append("built-in names should hold every STR alias and category only")
        }
        return errors
    }
}
