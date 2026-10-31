import Foundation

/// Shared math for the stat levels (STR, END, INT, AGI, FOC, FIN). Each stat scores its requirements from a
/// level 0 floor to its max target, weights them to a 0–100 score, and maps the score to 0–350.
/// The max level needs every strict requirement, not only a full score.
///
/// Missing data: a requirement whose input is not logged at all has `hasData == false`. It does not count.
/// It drops out of the score and the other requirements share its weight, the same as a removed target.
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
    /// False when the input is not logged at all. The requirement then drops out of the score
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

    /// The requirements that score: those with data, their weights scaled back to 100 in the same ratio.
    var counted: [StatRequirement] { Self.scaled(requirements.filter(\.hasData)) }

    /// The max level needs every counted requirement at once. No counted requirement: never the max.
    var isMaxLevel: Bool { !counted.isEmpty && counted.allSatisfy(\.passed) }
    /// Counted requirements that miss their strict rule. A requirement without data is not failing; it is not counted.
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
    /// Rows without data stay in the list (so they can be shown) but still do not count.
    /// Removing every target gives an empty report: score 0, level 0.
    func removing(_ removed: Set<String>) -> StatLevelReport {
        StatLevelReport(stat: stat, requirements: Self.scaled(requirements.filter { !removed.contains($0.category) }))
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
