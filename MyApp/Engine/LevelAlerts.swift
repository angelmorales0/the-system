import Foundation

/// The overall STATUS level went up or down. Shown as a card over every page and sent as a notification.
struct LevelChange: Equatable, Identifiable {
    struct StatMove: Equatable {
        var stat: Stat
        var from: Int
        var to: Int
    }

    var from: Int
    var to: Int
    /// The stats that moved, biggest move first.
    var stats: [StatMove]
    var id: String { "\(from)-\(to)" }
    var rose: Bool { to > from }
}

/// Finds a change of the overall level. Each new level is announced once: the last announced level is saved,
/// so a relaunch that reads the same level stays quiet.
enum LevelAlerts {
    static let announcedKey = "com.angelmorales.thesystem.level.announced"

    /// The change from `before` to `after`, or nil when the overall level is the same, is the one last announced,
    /// or a side has no reading (`.empty`, or no stat data at all).
    static func change(before: StatLevelSet, after: StatLevelSet, announced: Int?) -> LevelChange? {
        guard before != .empty, after != .empty, after.overallXP > 0,
              before.overallLevel != after.overallLevel, announced != after.overallLevel else { return nil }
        let stats = Stat.allCases
            .filter { before[$0] != after[$0] }
            .map { LevelChange.StatMove(stat: $0, from: before[$0], to: after[$0]) }
            .sorted { abs($0.to - $0.from) > abs($1.to - $1.from) }
        return LevelChange(from: before.overallLevel, to: after.overallLevel, stats: stats)
    }

    /// The change, after it is saved as announced.
    static func announce(before: StatLevelSet, after: StatLevelSet, defaults: UserDefaults = .standard) -> LevelChange? {
        let announced = defaults.object(forKey: announcedKey) as? Int
        guard let change = change(before: before, after: after, announced: announced) else { return nil }
        defaults.set(change.to, forKey: announcedKey)
        return change
    }

    static func title(_ change: LevelChange) -> String {
        change.rose ? "LEVEL UP: LV. \(change.to)" : "LEVEL DOWN: LV. \(change.to)"
    }

    /// "Level 41 → 42. STR 120 → 128, END 98 → 96."
    static func body(_ change: LevelChange) -> String {
        let stats = change.stats.prefix(3).map { "\($0.stat.rawValue) \($0.from) → \($0.to)" }.joined(separator: ", ")
        return "Level \(change.from) → \(change.to)." + (stats.isEmpty ? "" : " \(stats).")
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func check() -> [String] {
        var errors: [String] = []
        func set(_ value: Int, str: Int? = nil) -> StatLevelSet {
            var levels = Dictionary(uniqueKeysWithValues: Stat.allCases.map { ($0, value) })
            if let str { levels[.STR] = str }
            return StatLevelSet(levels: levels)
        }
        let low = set(100), high = set(100, str: 160)
        guard low.overallLevel != high.overallLevel else { return ["the test levels should differ"] }
        guard let up = change(before: low, after: high, announced: nil) else { return ["a higher level should announce"] }
        if !up.rose || up.stats.map(\.stat) != [.STR] || up.stats.first?.to != 160 {
            errors.append("a level up should name the stat that moved, got \(up.stats)")
        }
        if body(up) != "Level \(low.overallLevel) → \(high.overallLevel). STR 100 → 160." { errors.append("the body is wrong: \(body(up))") }
        if change(before: high, after: low, announced: nil)?.rose != false { errors.append("a lower level should announce a level down") }
        if change(before: low, after: high, announced: high.overallLevel) != nil { errors.append("a level already announced should stay quiet") }
        if change(before: low, after: low, announced: nil) != nil { errors.append("the same level should stay quiet") }
        if change(before: .empty, after: high, announced: nil) != nil { errors.append("the first reading should stay quiet") }
        if change(before: high, after: set(0), announced: nil) != nil { errors.append("a reading with no data should stay quiet") }
        return errors
    }
}
