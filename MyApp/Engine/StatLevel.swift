import Foundation

/// Shared math for the stat levels (STR, END, INT, AGI, FOC, FIN). Each stat scores its requirements from a
/// level 0 floor to its max target, weights them to a 0–100 score, and maps the score to 0–350.
/// The max level needs every strict requirement, not only a full score.
///
/// Missing data: a requirement whose input is not logged at all has `hasData == false`. It does not count.
/// It counts as 0 at its full weight, so it holds the level down until it is logged. Only a removed target leaves the score.
/// A requirement with some data counts, scaled down by how much is logged. A stat with no data at all is level 0.
enum StatLevel {
    static let maxLevel = 350

    /// Level 0 floor and max-level target for one metric. Lower-is-better metrics (run times) put the floor above the target.
    struct Band: Equatable {
        var floor: Double
        var target: Double

        func progress(_ value: Double) -> Double {
            guard target != floor else { return value >= target ? 1 : 0 }
            let raw = (value - floor) / (target - floor)
            return min(max(raw, 0), 1)
        }
    }

    static let poundsPerKilogram = 2.20462

    static func pounds(fromKilograms kg: Double) -> Double { kg * poundsPerKilogram }

    /// Epley estimated one-rep max: weight × (1 + reps / 30). One rep returns the weight.
    static func estimatedOneRepMax(weight: Double, reps: Int) -> Double {
        guard reps > 0, weight > 0 else { return 0 }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }
}

/// One scored requirement. `passed` is the strict max-level rule.
/// `progress` is 0 at the level 0 floor and 1 at the target.
struct StatRequirement: Equatable, Identifiable {
    var category: String
    var passed: Bool
    var progress: Double
    /// Share of the 100-point score. A stat's weights add to 100.
    var weight: Double
    var detail: String
    /// False when the input is not logged at all. The requirement then counts as 0 at its full weight
    /// (see `StatLevelReport.counted`). `passed` and `progress` are false and 0 for such a row.
    var hasData: Bool = true

    var id: String { category }
    var points: Double { progress * weight }
    /// Levels still available in this requirement.
    var levelsAvailable: Double { (weight - points) * Double(StatLevel.maxLevel) / 100 }
}

struct StatLevelReport: Equatable {
    var stat: Stat
    /// Every requirement, with and without data, in display order.
    var requirements: [StatRequirement]

    /// The requirements that score: every one, with or without data. A requirement without data scores 0 at its
    /// full weight, so an unlogged lift or metric holds the level down until it is logged.
    var counted: [StatRequirement] { Self.scaled(requirements) }

    /// The max level needs every requirement at once, logged and passed. No requirement: never the max.
    var isMaxLevel: Bool { !counted.isEmpty && counted.allSatisfy(\.passed) }
    /// Requirements that miss their strict rule, including those with no data.
    var failing: [StatRequirement] { counted.filter { !$0.passed } }
    var withoutData: [StatRequirement] { requirements.filter { !$0.hasData } }

    /// 0...100. Weighted sum of the counted requirements' progress.
    var score: Double { counted.reduce(0) { $0 + $1.points } }

    /// 0...350. Without every strict rule the level stops at 349.
    var level: Int {
        let scored = Int((Double(StatLevel.maxLevel) * score / 100 + 1e-9).rounded(.down))
        return isMaxLevel ? StatLevel.maxLevel : min(scored, StatLevel.maxLevel - 1)
    }

    var levelsToMax: Int { StatLevel.maxLevel - level }

    /// Counted requirements with the most levels left, best first.
    func topGains(_ count: Int = 3) -> [StatRequirement] {
        Array(counted.filter { $0.levelsAvailable > 0 }.sorted { $0.levelsAvailable > $1.levelsAvailable }.prefix(count))
    }

    /// Drops the removed targets and scales the weights of the rest back to 100, in the same ratio.
    /// Rows without data stay in the list and count as 0.
    /// Removing every target gives an empty report: score 0, level 0.
    func removing(_ removed: Set<String>) -> StatLevelReport {
        StatLevelReport(stat: stat, requirements: Self.scaled(requirements.filter { !removed.contains($0.category) }))
    }

    /// Self-check for the no-data rule, on a report whose other rows are perfect: each named row has no data,
    /// scores 0 at its full weight, fails, and blocks the max; the weights still add to 100; and the level is
    /// what the other rows earn alone. Empty when all of that holds.
    static func zeroCheck(_ report: StatLevelReport, noData: Set<String>, _ label: String) -> [String] {
        var errors: [String] = []
        let rows = report.counted.filter { noData.contains($0.category) }
        if Set(rows.map(\.category)) != noData || rows.contains(where: { $0.hasData || $0.progress != 0 || $0.passed }) {
            errors.append("\(label): \(noData.sorted()) should be counted with no data and 0 progress, got \(rows)")
        }
        if Set(report.failing.map(\.category)) != noData || report.isMaxLevel {
            errors.append("\(label): only \(noData.sorted()) should fail and block the max, got failing \(report.failing.map(\.category))")
        }
        if report.counted.count != report.requirements.count || abs(report.counted.reduce(0) { $0 + $1.weight } - 100) > 0.001 {
            errors.append("\(label): every row should count and the weights add to 100, got \(report.counted.map { "\($0.category) \($0.weight)" })")
        }
        let earned = 100 - rows.reduce(0) { $0 + $1.weight }
        let expected = min(StatLevel.maxLevel - 1, Int((Double(StatLevel.maxLevel) * earned / 100 + 1e-9).rounded(.down)))
        if report.level != expected { errors.append("\(label): the other rows alone should give level \(expected), got \(report.level)") }
        return errors
    }

    /// The same rows with their weights scaled to add to 100. Empty stays empty.
    static func scaled(_ rows: [StatRequirement]) -> [StatRequirement] {
        let total = rows.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        return rows.map { row in
            var scaled = row
            scaled.weight = row.weight * 100 / total
            return scaled
        }
    }
}
