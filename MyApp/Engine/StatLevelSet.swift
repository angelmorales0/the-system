import Foundation

/// The seven stat levels (0...146) that the status radar draws.
/// Each comes from its algorithm. A stat with no data yet scores 0; nothing falls back to XP points.
struct StatLevelSet: Equatable {
    var levels: [Stat: Int]

    subscript(stat: Stat) -> Int { levels[stat] ?? 0 }

    /// Radar order follows `Stat.allCases`, the same order the XP stats used.
    var radar: [(label: String, value: Double)] {
        Stat.allCases.map { (label: $0.rawValue, value: Double(self[$0])) }
    }

    /// Inputs the phone can read today. The empty lists are the data still to be wired
    /// (Hevy history, run and swim efforts, VO₂ max, zone 2, agility tests, Screen Time days, recovery days).
    static func compute(
        codeforces: CodeforcesReading,
        financeMonths: [FinanceMonth],
        now: Date
    ) -> StatLevelSet {
        StatLevelSet(levels: [
            .STR: StrengthLevel.evaluate(workouts: [], now: now).level,
            .END: EnduranceLevel.evaluate(efforts: [], swims: [], vo2: [], zoneTwo: [], now: now).level,
            .INT: IntelligenceLevel.evaluate(codeforces).level,
            .AGI: AgilityLevel.evaluate(measurements: [], now: now).level,
            .FOC: FocusLevel.evaluate(days: []).level,
            .REC: RecoveryLevel.evaluate(days: []).level,
            .FIN: FinanceLevel.evaluate(months: financeMonths).level,
        ])
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
    static let storageKey = "com.angelmorales.thesystem.statlevels.v1"

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
