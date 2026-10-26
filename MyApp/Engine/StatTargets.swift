import Foundation

/// Targets the player removed from each stat. A removed target does not score, and the
/// remaining targets share its weight in the same ratio (see `StatLevelReport.removing`).
struct StatTargets: Codable, Equatable {
    static let storageKey = "com.angelmorales.thesystem.stattargets.v1"

    /// Stat raw value → removed target categories.
    var removed: [String: [String]] = [:]

    func removed(for stat: Stat) -> Set<String> { Set(removed[stat.rawValue] ?? []) }

    func isRemoved(_ category: String, from stat: Stat) -> Bool { removed(for: stat).contains(category) }

    /// Adds a removed target back, or removes an active one.
    mutating func toggle(_ category: String, in stat: Stat) {
        var set = removed(for: stat)
        if set.contains(category) { set.remove(category) } else { set.insert(category) }
        removed[stat.rawValue] = set.isEmpty ? nil : set.sorted()
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
        return errors
    }
}

extension Stat: Identifiable {
    var id: String { rawValue }
}
