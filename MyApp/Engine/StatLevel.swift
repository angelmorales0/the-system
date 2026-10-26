import Foundation

/// Shared math for the stat levels (STR, END, INT, AGI, FOC, FIN). Each stat scores its requirements from a
/// level 0 floor to its max target, weights them to a 0–100 score, and maps the score to 0–350.
/// The max level needs every strict requirement, not only a full score.
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

    var id: String { category }
    var points: Double { progress * weight }
    /// Levels still available in this requirement.
    var levelsAvailable: Double { (weight - points) * Double(StatLevel.maxLevel) / 100 }
}

struct StatLevelReport: Equatable {
    var stat: Stat
    var requirements: [StatRequirement]

    var isMaxLevel: Bool { !requirements.isEmpty && requirements.allSatisfy(\.passed) }
    var failing: [StatRequirement] { requirements.filter { !$0.passed } }

    /// 0...100. Weighted sum of requirement progress.
    var score: Double { requirements.reduce(0) { $0 + $1.points } }

    /// 0...350. Without every strict rule the level stops at 349.
    var level: Int {
        let scored = Int((Double(StatLevel.maxLevel) * score / 100 + 1e-9).rounded(.down))
        return isMaxLevel ? StatLevel.maxLevel : min(scored, StatLevel.maxLevel - 1)
    }

    var levelsToMax: Int { StatLevel.maxLevel - level }

    /// Requirements with the most levels left, best first.
    func topGains(_ count: Int = 3) -> [StatRequirement] {
        Array(requirements.filter { $0.levelsAvailable > 0 }.sorted { $0.levelsAvailable > $1.levelsAvailable }.prefix(count))
    }

    /// Drops the removed targets and scales the weights of the rest back to 100, in the same ratio.
    /// Removing every target gives an empty report: score 0, level 0.
    func removing(_ removed: Set<String>) -> StatLevelReport {
        let kept = requirements.filter { !removed.contains($0.category) }
        let total = kept.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return StatLevelReport(stat: stat, requirements: []) }
        return StatLevelReport(stat: stat, requirements: kept.map { requirement in
            var scaled = requirement
            scaled.weight = requirement.weight * 100 / total
            return scaled
        })
    }
}
