import Foundation

/// The seven stat levels (0...350) that the status radar draws, and the overall level (0...146) they add up to.
/// Each stat comes from its algorithm. A stat with no data yet scores 0; nothing falls back to XP points.
struct StatLevelSet: Equatable {
    /// Overall level 146 means all seven stats are at their max (350).
    static let overallMaxLevel = 146

    var levels: [Stat: Int]
    /// Every target of each stat, removed ones included, before the weights are scaled. Empty for a reading loaded from history.
    var reports: [Stat: StatLevelReport] = [:]

    subscript(stat: Stat) -> Int { levels[stat] ?? 0 }

    var isAllMax: Bool { Stat.allCases.allSatisfy { self[$0] >= StatLevel.maxLevel } }

    /// 0...1: the seven stats together as a share of their combined max. Every stat counts the same.
    var overallFraction: Double {
        let total = Stat.allCases.reduce(0) { $0 + min(self[$1], StatLevel.maxLevel) }
        return Double(total) / Double(Stat.allCases.count * StatLevel.maxLevel)
    }

    /// 0...146. Only all seven stats at 350 reach 146; anything less stops at 145.
    var overallLevel: Int {
        let scored = Int((Double(Self.overallMaxLevel) * overallFraction + 1e-9).rounded(.down))
        return isAllMax ? Self.overallMaxLevel : min(scored, Self.overallMaxLevel - 1)
    }

    /// 0...1: how far the stats are from this overall level to the next one, for the progress bar.
    var overallProgress: Double {
        if isAllMax { return 1 }
        return min(max(Double(Self.overallMaxLevel) * overallFraction - Double(overallLevel), 0), 1)
    }

    /// Stat levels still needed for the next overall level, spread across any stats.
    var statLevelsToNextOverall: Int {
        guard !isAllMax else { return 0 }
        let perLevel = Double(Stat.allCases.count * StatLevel.maxLevel) / Double(Self.overallMaxLevel)
        let needed = Double(overallLevel + 1) * perLevel - overallFraction * Double(Stat.allCases.count * StatLevel.maxLevel)
        return max(1, Int(needed.rounded(.up)))
    }

    /// Radar order follows `Stat.allCases`, the same order the XP stats used.
    var radar: [(label: String, value: Double)] {
        Stat.allCases.map { (label: $0.rawValue, value: Double(self[$0])) }
    }

    /// Inputs the phone can read today. The empty lists are the data still to be wired
    /// (Hevy history, run and swim efforts, VO₂ max, zone 2, agility tests, Screen Time days, recovery days).
    /// `bodyMass` is the newest Apple Health weigh-in, for the END body weight target.
    static func compute(
        codeforces: CodeforcesReading,
        financeMonths: [FinanceMonth],
        bodyMass: [BodyMassReading] = [],
        targets: StatTargets = StatTargets(),
        now: Date
    ) -> StatLevelSet {
        let reports: [Stat: StatLevelReport] = [
            .STR: StrengthLevel.evaluate(workouts: [], now: now),
            .END: EnduranceLevel.evaluate(efforts: [], swims: [], vo2: [], zoneTwo: [], bodyMass: bodyMass, now: now),
            .INT: IntelligenceLevel.evaluate(codeforces),
            .AGI: AgilityLevel.evaluate(measurements: [], now: now),
            .FOC: FocusLevel.evaluate(days: []),
            .REC: RecoveryLevel.evaluate(days: []).statReport,
            .FIN: FinanceLevel.evaluate(months: financeMonths),
        ]
        return StatLevelSet(
            levels: reports.mapValues { $0.removing(targets.removed(for: $0.stat)).level },
            reports: reports
        )
    }

    static let empty = compute(
        codeforces: .disconnected(reason: "TODO: Codeforces is not connected."),
        financeMonths: [],
        now: Date(timeIntervalSince1970: 0)
    )

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        let now = QuestDay.date(from: "2026-10-17") ?? Date(timeIntervalSince1970: 0)

        let none = compute(codeforces: .disconnected(reason: "TODO"), financeMonths: [], now: now)
        if let stat = Stat.allCases.first(where: { none[$0] != 0 }) {
            errors.append("with no data every stat should be 0, got \(stat.rawValue) \(none[stat])")
        }
        if none.radar.map(\.label) != Stat.allCases.map(\.rawValue) {
            errors.append("radar should list every stat in order")
        }

        var rated = CodeforcesReading.disconnected(reason: "")
        rated.available = true
        rated.configured = true
        rated.rating = 2100
        rated.maxRating = 2100
        rated.contests = 20
        let month = FinanceMonth(month: "2026-09", postTaxIncomeUsd: 30_000, spendingUsd: 18_000, budgetUsd: 20_000, complete: true)
        let connected = compute(codeforces: rated, financeMonths: [month], now: now)
        if connected[.INT] != StatLevel.maxLevel || connected[.FIN] != StatLevel.maxLevel || connected[.STR] != 0 {
            errors.append("a 2100 rating and a perfect month should give INT and FIN 146, got INT \(connected[.INT]) FIN \(connected[.FIN])")
        }

        // A month still in progress does not count, so FIN stays 0.
        var partial = month
        partial.complete = false
        if compute(codeforces: rated, financeMonths: [partial], now: now)[.FIN] != 0 {
            errors.append("an in-progress month should not score FIN")
        }

        // History keeps one reading per day, newest wins, and drops days past the limit.
        var history = StatLevelHistory()
        history.record(none, on: "2026-10-01")
        history.record(connected, on: "2026-10-01")
        history.record(none, on: "2026-10-02")
        if history.days.count != 2 || history.days["2026-10-01"]?["INT"] != StatLevel.maxLevel {
            errors.append("history should keep the newest reading per day, got \(history.days)")
        }
        if history.series(for: .INT).map(\.level) != [StatLevel.maxLevel, 0] || history.latest?[.INT] != 0 {
            errors.append("history series should run oldest to newest, got \(history.series(for: .INT))")
        }
        for day in 1...130 {
            history.record(none, on: String(format: "2027-%02d-%02d", (day - 1) / 28 + 1, (day - 1) % 28 + 1))
        }
        if history.days.count != StatLevelHistory.keepDays || history.days["2026-10-01"] != nil {
            errors.append("history should keep only the newest \(StatLevelHistory.keepDays) days, got \(history.days.count)")
        }

        // Overall level: 146 only with all seven stats at 350. One stat at 349 stops at 145. Half of every stat is 73.
        func uniform(_ value: Int) -> StatLevelSet {
            StatLevelSet(levels: Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0, value) }))
        }
        if uniform(StatLevel.maxLevel).overallLevel != Self.overallMaxLevel || uniform(0).overallLevel != 0 || uniform(175).overallLevel != 73 {
            errors.append("overall should be 146 at all max, 0 at none, 73 at half, got \(uniform(StatLevel.maxLevel).overallLevel) \(uniform(0).overallLevel) \(uniform(175).overallLevel)")
        }
        var almost = uniform(StatLevel.maxLevel)
        almost.levels[.FIN] = StatLevel.maxLevel - 1
        if almost.overallLevel != Self.overallMaxLevel - 1 || almost.statLevelsToNextOverall != 1 {
            errors.append("one stat at 349 should stop at overall 145 and need 1 stat level, got \(almost.overallLevel) \(almost.statLevelsToNextOverall)")
        }
        // One stat at max and the rest at 0 is 1/7 of the way: overall 20.
        var single = uniform(0)
        single.levels[.STR] = StatLevel.maxLevel
        if single.overallLevel != 20 || single.overallProgress <= 0 || single.overallProgress >= 1 {
            errors.append("one maxed stat should be overall 20 with partial progress, got \(single.overallLevel) \(single.overallProgress)")
        }

        let keys = IntegrationClient.financeMonthKeys(dayKey: "2026-01-05")
        if keys.this != "2026-01" || keys.last != "2025-12" {
            errors.append("January should ask for this month and last December, got \(keys)")
        }
        return errors
    }
}

/// One saved reading of every stat level per local day, for the history charts. Newest reading of a day wins.
struct StatLevelHistory: Codable, Equatable {
    static let keepDays = 120
    /// v2: stat levels on the 0...350 scale. v1 readings were on 0...146 and are not mixed in.
    static let storageKey = "com.angelmorales.thesystem.statlevels.v2"

    /// dayKey → stat raw value → level.
    var days: [String: [String: Int]] = [:]

    mutating func record(_ set: StatLevelSet, on dayKey: String) {
        days[dayKey] = Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0.rawValue, set[$0]) })
        for key in days.keys.sorted().dropLast(Self.keepDays) {
            days.removeValue(forKey: key)
        }
    }

    /// Oldest to newest.
    func series(for stat: Stat) -> [(dayKey: String, level: Int)] {
        days.keys.sorted().map { (dayKey: $0, level: days[$0]?[stat.rawValue] ?? 0) }
    }

    /// The newest saved levels, shown at launch until fresh data arrives.
    var latest: StatLevelSet? {
        guard let key = days.keys.max(), let row = days[key] else { return nil }
        return StatLevelSet(levels: Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0, row[$0.rawValue] ?? 0) }))
    }

    static func load(from defaults: UserDefaults = .standard) -> StatLevelHistory {
        guard let data = defaults.data(forKey: storageKey),
              let history = try? JSONDecoder().decode(StatLevelHistory.self, from: data) else { return StatLevelHistory() }
        return history
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension Stat {
    var fullName: String {
        switch self {
        case .STR: return "Strength"
        case .END: return "Endurance"
        case .INT: return "Intelligence"
        case .AGI: return "Agility"
        case .FOC: return "Focus"
        case .REC: return "Recovery"
        case .FIN: return "Finance"
        }
    }
}
