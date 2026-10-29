import Foundation

/// One STR goal that the player added, for example "Hip Thrust: 225 lb × 5".
/// It scores like a built-in STR target (see `StrengthLevel.evaluate`) and joins its split day (see `GymSplit.adding`).
/// The exercise name is also the target's category, so it must be unique among the STR targets.
struct CustomStrengthGoal: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Weight × reps in one working set. Scored by the Epley e1RM, like the built-in lifts.
        case weightReps
        /// Bodyweight reps in one working set.
        case reps
        /// Seconds held in one working set.
        case hold

        var id: String { rawValue }

        var label: String {
            switch self {
            case .weightReps: return "Weight × reps"
            case .reps: return "Reps"
            case .hold: return "Hold"
            }
        }
    }

    /// Longest exercise name, so a quest title such as "{name} 3×5-9" stays under 48 characters.
    static let maxNameLength = 32
    /// Level 0 weight for a weight × reps goal: a third of the target at the same reps (an empty bar under a 135 lb goal).
    static let floorShare = 1.0 / 3

    /// The Hevy exercise name without equipment, as the player typed it. "Hip Thrust" matches "Hip Thrust (Barbell)".
    var exercise: String
    var kind: Kind
    /// Weight × reps goals only.
    var targetLb: Double = 0
    /// Weight × reps and reps goals.
    var targetReps: Int = 0
    /// Hold goals only.
    var targetSeconds: Double = 0
    /// `GymSplit.Day.id` of the day that trains it. "Auto" picks this day when the goal is added.
    var day: String

    var id: String { category }
    var category: String { exercise }
    /// The name as the Hevy check and the STR scoring compare it.
    var alias: String { StrengthLevel.normalizedName(exercise) }

    /// The max level rule in words, like `StatTargets.goals`.
    var goal: String {
        switch kind {
        case .weightReps: return "\(Self.number(targetLb)) lb × \(targetReps)"
        case .reps: return "\(targetReps) reps in one set"
        case .hold: return "\(Self.number(targetSeconds)) sec in one hold"
        }
    }

    /// The lift rule of a weight × reps goal. Nil for the other kinds.
    var lift: StrengthLevel.Lift? {
        guard kind == .weightReps else { return nil }
        return StrengthLevel.Lift(category: category, aliases: [alias], floorLb: targetLb * Self.floorShare, targetLb: targetLb, targetReps: targetReps)
    }

    /// The rep rule of a reps goal. Nil for the other kinds.
    var repRule: StrengthLevel.RepRule? {
        kind == .reps ? StrengthLevel.RepRule(category: category, aliases: [alias], targetReps: targetReps) : nil
    }

    /// Why the goal cannot be saved, or nil when its fields are good. `StatTargets.add` checks the name and the day.
    var fieldProblem: String? {
        let name = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Type the Hevy exercise name." }
        if name.count > Self.maxNameLength { return "Use a name of \(Self.maxNameLength) characters or fewer." }
        if name.contains("(") || name.contains(")") { return "Type the name without the equipment, for example Hip Thrust." }
        if StretchTime.isStretchExercise(name) { return "Stretches are not strength goals. The Stretching quest covers them." }
        switch kind {
        case .weightReps:
            if !(1...1_500).contains(targetLb) { return "Type a weight from 1 to 1500 lb." }
            if !(1...50).contains(targetReps) { return "Type 1 to 50 reps." }
        case .reps:
            if !(1...200).contains(targetReps) { return "Type 1 to 200 reps." }
        case .hold:
            if !(1...3_600).contains(targetSeconds) { return "Type 1 to 3600 seconds." }
        }
        return nil
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Targets the player removed from each stat, and the STR goals the player added. A removed target does not score,
/// and the remaining targets share its weight in the same ratio (see `StatLevelReport.removing`).
struct StatTargets: Codable, Equatable {
    static let storageKey = "com.angelmorales.thesystem.stattargets.v1"

    /// Stat raw value → removed target categories.
    var removed: [String: [String]] = [:]
    /// STR goals the player added, oldest first. A save from before this field loads with none.
    var custom: [CustomStrengthGoal] = []

    enum CodingKeys: String, CodingKey {
        case removed
        case custom
    }

    func removed(for stat: Stat) -> Set<String> { Set(removed[stat.rawValue] ?? []) }

    func isRemoved(_ category: String, from stat: Stat) -> Bool { removed(for: stat).contains(category) }

    /// Adds a removed target back, or removes an active one.
    mutating func toggle(_ category: String, in stat: Stat) {
        var set = removed(for: stat)
        if set.contains(category) { set.remove(category) } else { set.insert(category) }
        removed[stat.rawValue] = set.isEmpty ? nil : set.sorted()
    }

    /// Adds a custom STR goal. Returns why it was refused, or nil when it was added.
    /// The name must not match a built-in STR target or another custom goal, and its split day must have room
    /// (see `GymSplit.adding` for the full-day rule).
    mutating func add(_ goal: CustomStrengthGoal) -> String? {
        var goal = goal
        goal.exercise = goal.exercise.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = goal.fieldProblem { return problem }
        if StrengthLevel.builtInNames.contains(goal.alias) {
            return "\(goal.exercise) is already a built-in STR target."
        }
        if custom.contains(where: { $0.alias == goal.alias }) {
            return "\(goal.exercise) is already one of your goals."
        }
        guard let day = GymSplit.day(id: goal.day) else { return "Pick a split day." }
        if GymSplit.room(on: day, goals: custom) == 0 {
            return "\(day.name) is full: no support exercise is left to give its place. Pick another day."
        }
        custom.append(goal)
        return nil
    }

    /// Deletes a custom goal. The STR level is then calculated without it.
    mutating func deleteCustom(_ category: String) {
        custom.removeAll { $0.category == category }
        if var set = removed[Stat.STR.rawValue] {
            set.removeAll { $0 == category }
            removed[Stat.STR.rawValue] = set.isEmpty ? nil : set
        }
    }

    func isCustom(_ category: String) -> Bool { custom.contains { $0.category == category } }

    /// The max level rule of a target in words: a custom goal first, then the built-in `goals`.
    func goal(for category: String) -> String? {
        custom.first { $0.category == category }?.goal ?? Self.goals[category]
    }

    static func load(from defaults: UserDefaults = .standard) -> StatTargets {
        guard let data = defaults.data(forKey: storageKey),
              let targets = try? JSONDecoder().decode(StatTargets.self, from: data) else { return StatTargets() }
        return targets
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Goals

    /// The max level rule of each target, in words. Keyed by category; every category name is unique across stats.
    static let goals: [String: String] = {
        var goals: [String: String] = [:]
        for lift in StrengthLevel.lifts {
            let sign = lift.addedWeight ? "+" : ""
            let perLeg = lift.category == StrengthLevel.bulgarianSplitSquat.category ? "/hand × \(lift.targetReps) per leg" : " × \(lift.targetReps)"
            goals[lift.category] = "\(sign)\(Int(lift.targetLb)) lb\(perLeg)"
        }
        for rule in [StrengthLevel.pullUps, StrengthLevel.handstandPushUps, StrengthLevel.toesToBar] {
            goals[rule.category] = "\(rule.targetReps) reps in one set"
        }
        goals["Pistol squats"] = "\(Int(StrengthLevel.pistolBand.target)) reps per leg"
        goals["Farmer's carry"] = "\(Int(StrengthLevel.farmerTargetLb)) lb/hand for \(Int(StrengthLevel.farmerTargetSec)) sec"
        goals["Dead hang"] = "\(Int(StrengthLevel.hangBand.target)) sec"

        goals["1-mile run"] = "\(clock(EnduranceLevel.mileBand.target)) or faster"
        goals["5K run"] = "\(clock(EnduranceLevel.fiveKBand.target)) or faster"
        goals["10K easy run"] = "\(clock(EnduranceLevel.tenKBand.target)) or faster"
        goals["VO₂ max"] = "\(Int(EnduranceLevel.vo2Band.target)) mL/kg/min"
        goals["Zone 2 endurance"] = "\(Int(EnduranceLevel.zoneTwoBand.target)) min unbroken in zone 2"
        goals["1-mile swim"] = "\(clock(EnduranceLevel.swimMileBand.target)) or faster"
        goals["Body weight"] = "\(Int(EnduranceLevel.bodyWeightTargetLb)) lb, within \(Int(EnduranceLevel.bodyWeightToleranceLb)) lb"

        goals["Codeforces rating"] = "\(Int(IntelligenceLevel.ratingBand.target)) rating (Master)"

        goals["Vertical jump"] = "\(Int(AgilityLevel.verticalJumpBand.target)) in"
        goals["Front splits"] = "Full splits, both legs"
        goals["Side splits"] = "Full side splits"
        goals["Apley scratch test"] = "Fingers touch, both sides"
        goals["Knee-to-wall test"] = "\(Int(AgilityLevel.kneeToWallBand.target)) cm, both sides"
        goals["90/90 hip switches"] = "\(Int(AgilityLevel.hipSwitchBand.target)) reps without hands"

        goals["Daily screen time"] = "Under \(FocusLevel.screenLimitMinutes / 60) h on \(Int(FocusLevel.screenPassShare * 100))% of days"
        goals["Social media"] = "0 min every day"

        goals["Sleep duration"] = "100% sleep need on \(Int(RecoveryLevel.sleepNeedBand.target * 100))% of nights"
        goals["Sleep consistency"] = "\(Int(RecoveryLevel.sleepConsistencyBand.target))% average"
        goals["Sleep efficiency"] = "\(Int(RecoveryLevel.sleepEfficiencyBand.target))% average"
        goals["Sleep debt"] = "\(Int(RecoveryLevel.sleepDebtBand.target)) min or less average"
        goals["Caffeine"] = "0 mg every day"
        goals["Nutrition"] = "Protein, fat, carbs, and calories on target"
        goals["Training recovery"] = "Rest and light days every week, at most \(Int(RecoveryLevel.veryHighDaysBand.target)) very hard"
        goals["HRV"] = "30-day median at or above the 90-day median"
        goals["Resting heart rate"] = "\(Int(RecoveryLevel.restingHrMin))–\(Int(RecoveryLevel.restingHrBand.target)) bpm average"
        goals["Circadian rhythm"] = "Sleep times drift \(Int(RecoveryLevel.circadianBand.target)) min or less"

        goals["Savings rate"] = "Save \(Int(FinanceLevel.savingsBand.target * 100))% of post-tax income"
        goals["Budget adherence"] = "$0 over budget"
        goals["Monthly income"] = "$\(Int(FinanceLevel.incomeBand.target).formatted()) post-tax a month"
        return goals
    }()

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let set = StatLevelSet.compute(codeforces: .disconnected(reason: ""), financeMonths: [], now: now)
        for stat in Stat.allCases {
            guard let report = set.reports[stat] else {
                errors.append("\(stat.rawValue) should have a target report")
                continue
            }
            for requirement in report.requirements where goals[requirement.category] == nil {
                errors.append("\(stat.rawValue) target \(requirement.category) has no goal text")
            }
        }

        // Removing a target scales the rest back to 100 in the same ratio (FIN 60/30/10 → 66.7/33.3).
        let finance = FinanceLevel.evaluate(months: [])
        let scaled = finance.removing(["Monthly income"])
        if scaled.requirements.map(\.category) != ["Savings rate", "Budget adherence"]
            || abs(scaled.requirements.reduce(0, { $0 + $1.weight }) - 100) > 0.001
            || abs((scaled.requirements.first?.weight ?? 0) - 200.0 / 3) > 0.001 {
            errors.append("removing Monthly income should leave 66.7/33.3, got \(scaled.requirements.map(\.weight))")
        }
        if finance.removing(Set(finance.requirements.map(\.category))).level != 0 {
            errors.append("a stat with every target removed should be level 0")
        }

        // Only the failing deadlift: removing it reaches the max level, and the level is recalculated.
        var workouts = StrengthLevel.perfectWorkouts(now: now)
        for index in workouts[0].exercises.indices where workouts[0].exercises[index].title == "Deadlift (Barbell)" {
            workouts[0].exercises[index].sets = [StrengthLevel.workingSet(lb: 135, reps: 1)]
        }
        let strength = StrengthLevel.evaluate(workouts: workouts, now: now)
        let trimmed = strength.removing(["Deadlift"])
        if strength.level >= StatLevel.maxLevel || trimmed.level != StatLevel.maxLevel {
            errors.append("removing a failing deadlift should give the max level, got \(strength.level) → \(trimmed.level)")
        }

        // Toggle twice gives the first state back, and removed targets are kept per stat.
        var targets = StatTargets()
        targets.toggle("Deadlift", in: .STR)
        if !targets.isRemoved("Deadlift", from: .STR) || targets.isRemoved("Deadlift", from: .END) {
            errors.append("toggle should remove Deadlift from STR only")
        }
        targets.toggle("Deadlift", in: .STR)
        if targets != StatTargets() {
            errors.append("a second toggle should add the target back, got \(targets.removed)")
        }

        // A save from before custom goals still loads, with its removed targets and no custom goals.
        let oldSave = Data(#"{"removed":{"STR":["Deadlift"],"END":["1-mile swim"]}}"#.utf8)
        let decoded = try? JSONDecoder().decode(StatTargets.self, from: oldSave)
        if decoded?.removed(for: .STR) != ["Deadlift"] || decoded?.isRemoved("1-mile swim", from: .END) != true || decoded?.custom != [] {
            errors.append("an old save should load with its removed targets and no custom goals, got \(String(describing: decoded))")
        }
        if (try? JSONDecoder().decode(StatTargets.self, from: Data("{}".utf8))) != StatTargets() {
            errors.append("an empty save should load as no changes")
        }

        // Custom goals: saved and loaded, shown with a goal text, and refused when the name or the day is wrong.
        var mine = StatTargets()
        let hipThrust = CustomStrengthGoal(exercise: " Hip Thrust ", kind: .weightReps, targetLb: 225, targetReps: 5, day: "deadlift")
        if let problem = mine.add(hipThrust) {
            errors.append("a hip thrust goal on Deadlift Day should be added, got \(problem)")
        }
        if mine.custom.first?.exercise != "Hip Thrust" || mine.goal(for: "Hip Thrust") != "225 lb × 5" || mine.goal(for: "Squat") != goals["Squat"] {
            errors.append("a custom goal should be trimmed and read 225 lb × 5, got \(mine.custom.map(\.exercise)) \(String(describing: mine.goal(for: "Hip Thrust")))")
        }
        if let data = try? JSONEncoder().encode(mine), (try? JSONDecoder().decode(StatTargets.self, from: data)) != mine {
            errors.append("custom goals should survive a save")
        }
        let refusals: [(CustomStrengthGoal, String)] = [
            (CustomStrengthGoal(exercise: "Bench Press", kind: .weightReps, targetLb: 315, targetReps: 1, day: "deadlift"), "a built-in target"),
            (CustomStrengthGoal(exercise: "hip thrust", kind: .reps, targetReps: 20, day: "squat"), "a second hip thrust"),
            (CustomStrengthGoal(exercise: "Ring Dip", kind: .reps, targetReps: 20, day: "bench"), "a goal on full Bench Day"),
            (CustomStrengthGoal(exercise: "Hip Thrust (Barbell)", kind: .weightReps, targetLb: 225, targetReps: 5, day: "squat"), "a name with equipment"),
            (CustomStrengthGoal(exercise: "Couch Stretch", kind: .hold, targetSeconds: 60, day: "squat"), "a stretch"),
            (CustomStrengthGoal(exercise: "Sled Push", kind: .weightReps, targetLb: 0, targetReps: 5, day: "squat"), "no weight"),
        ]
        for (goal, label) in refusals where mine.add(goal) == nil {
            errors.append("\(label) should be refused")
        }
        if mine.custom.count != 1 {
            errors.append("refused goals must not be saved, got \(mine.custom.map(\.exercise))")
        }

        // Removing a built-in target and adding a custom goal together: Deadlift out, Hip Thrust in, 15 targets at 6.67.
        mine.toggle("Deadlift", in: .STR)
        let both = StrengthLevel.evaluate(workouts: [], custom: mine.custom, now: now).removing(mine.removed(for: .STR))
        let weights = both.requirements.map(\.weight)
        if both.requirements.count != 15 || both.requirements.contains(where: { $0.category == "Deadlift" })
            || !both.requirements.contains(where: { $0.category == "Hip Thrust" })
            || weights.contains(where: { abs($0 - 100.0 / 15) > 0.001 }) {
            errors.append("Deadlift removed and Hip Thrust added should give 15 targets at 6.67, got \(both.requirements.map { "\($0.category) \($0.weight)" })")
        }
        let levels = StatLevelSet.compute(codeforces: .disconnected(reason: ""), financeMonths: [], targets: mine, now: now)
        if levels.reports[.STR]?.requirements.contains(where: { $0.category == "Hip Thrust" }) != true {
            errors.append("the stat levels should score the custom goal")
        }
        mine.deleteCustom("Hip Thrust")
        if !mine.custom.isEmpty || !mine.isRemoved("Deadlift", from: .STR) {
            errors.append("deleting a custom goal should keep the removed targets, got \(mine)")
        }
        return errors
    }
}

extension StatTargets {
    /// A save from before `custom` has no such field. It still loads, so no player loses a removed target or a level.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removed = try container.decodeIfPresent([String: [String]].self, forKey: .removed) ?? [:]
        custom = try container.decodeIfPresent([CustomStrengthGoal].self, forKey: .custom) ?? []
    }
}

extension Stat: Identifiable {
    var id: String { rawValue }
}
