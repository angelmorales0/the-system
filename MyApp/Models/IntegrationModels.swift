import Foundation

/// Today's WHOOP recovery. This is not the REC stat.
struct ReadinessSnapshot: Codable, Equatable {
    var recoveryScore: Int
    var restingHr: Int?
    var hrv: Double?
    var sleepPerformance: Int?
    var band: ReadinessBand
    var capturedOn: String
}

/// Rolling placeholder for long-term recovery capacity.
/// Today's `recoveryScore` is never copied into `PlayerState.stats.REC`.
struct RecoveryComposite: Codable, Equatable {
    var scoresByDay: [String: Int] = [:]

    var sampleCount: Int { scoresByDay.count }

    /// Nil until a week of scores exists. The radar REC stat stays XP-driven until then.
    var rollingAverage: Double? {
        guard scoresByDay.count >= 7 else { return nil }
        let total = scoresByDay.values.reduce(0, +)
        return Double(total) / Double(scoresByDay.count)
    }

    mutating func record(score: Int, on dayKey: String) {
        scoresByDay[dayKey] = min(max(score, 0), 100)
        let overflow = scoresByDay.keys.sorted().dropLast(28)
        for key in overflow {
            scoresByDay.removeValue(forKey: key)
        }
    }
}

extension ReadinessBand {
    /// WHOOP bands: green 67–100, yellow 34–66, red 0–33.
    static func from(recoveryScore score: Int) -> ReadinessBand {
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }
}

enum HealthAccess: String, Codable, Equatable {
    case unavailable
    case notRequested
    case requested
}

struct HealthDaySummary: Equatable {
    var access: HealthAccess
    var proteinGrams: Double
    var proteinPrefersMacroFactor: Bool
    var energyKcal: Double
    var bodyMassKg: Double?
    var bodyMassPrefersMacroFactor: Bool
    var sleepAsleepHours: Double
    var workouts: [WorkoutEvent]

    static let unavailable = HealthDaySummary(
        access: .unavailable,
        proteinGrams: 0,
        proteinPrefersMacroFactor: false,
        energyKcal: 0,
        bodyMassKg: nil,
        bodyMassPrefersMacroFactor: false,
        sleepAsleepHours: 0,
        workouts: []
    )
}

struct WhoopDayReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var dayKey: String
    var recoveryScore: Int?
    var restingHr: Int?
    var hrv: Double?
    var sleepPerformance: Int?
    var dayStrain: Double?
    var scored: Bool
    var workouts: [WorkoutEvent]

    static func disconnected(dayKey: String, reason: String) -> WhoopDayReading {
        WhoopDayReading(
            available: false,
            configured: false,
            reason: reason,
            dayKey: dayKey,
            recoveryScore: nil,
            restingHr: nil,
            hrv: nil,
            sleepPerformance: nil,
            dayStrain: nil,
            scored: false,
            workouts: []
        )
    }
}

struct StravaDayReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var dayKey: String
    var activities: [WorkoutEvent]

    static func disconnected(dayKey: String, reason: String) -> StravaDayReading {
        StravaDayReading(available: false, configured: false, reason: reason, dayKey: dayKey, activities: [])
    }
}

/// Backend Mercury summary for one local day. No token and no raw transaction list.
struct MercuryDayReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var dayKey: String
    var discretionarySpendUsd: Double
    var necessarySpendUsd: Double
    var capUsd: Double
    var paceState: String
    var ytdIncomeUsd: Double
    var ytdGoalUsd: Double
    var discretionary7dUsd: Double
    var underCap: Bool
    var settled: Bool
    var synced: Bool

    static func disconnected(dayKey: String, reason: String) -> MercuryDayReading {
        MercuryDayReading(
            available: false,
            configured: false,
            reason: reason,
            dayKey: dayKey,
            discretionarySpendUsd: 0,
            necessarySpendUsd: 0,
            capUsd: 40,
            paceState: "NORMAL",
            ytdIncomeUsd: 0,
            ytdGoalUsd: 500_000,
            discretionary7dUsd: 0,
            underCap: false,
            settled: false,
            synced: false
        )
    }
}

/// Stored finance summary. The radar FIN number is quest XP plus a small projection, not a balance.
struct FinanceSnapshot: Codable, Equatable {
    var dayKey: String
    var discretionarySpendUsd: Double
    var necessarySpendUsd: Double
    var capUsd: Double
    var discretionary7dUsd: Double
    var paceState: String
    var ytdIncomeUsd: Double
    var ytdGoalUsd: Double
    var settled: Bool
}

enum FinanceProjection {
    /// Bounded points layered on quest-granted FIN. A full year toward $500K adds at most 12, pace at most 8.
    static func points(pace: String, ytdIncomeUsd: Double, ytdGoalUsd: Double) -> Int {
        let pacePoints: Int
        switch pace {
        case "NORMAL":
            pacePoints = 8
        case "CAUTION":
            pacePoints = 4
        case "WARNING":
            pacePoints = 1
        default:
            pacePoints = 0
        }
        let goal = ytdGoalUsd > 0 ? ytdGoalUsd : 500_000
        let ratio = min(max(ytdIncomeUsd / goal, 0), 1)
        let ytdPoints = Int((ratio * 12).rounded(.down))
        return min(pacePoints + ytdPoints, 20)
    }
}

struct DayIntegrationSnapshot: Equatable {
    var whoop: WhoopDayReading
    var strava: StravaDayReading
    var health: HealthDaySummary
    var mercury: MercuryDayReading = .disconnected(dayKey: "", reason: "TODO: Mercury is not connected.")
    var workouts: [CanonicalWorkout]

    static func empty(dayKey: String) -> DayIntegrationSnapshot {
        DayIntegrationSnapshot(
            whoop: .disconnected(dayKey: dayKey, reason: "TODO: WHOOP is not connected."),
            strava: .disconnected(dayKey: dayKey, reason: "TODO: Strava is not connected."),
            health: .unavailable,
            mercury: .disconnected(dayKey: dayKey, reason: "TODO: Mercury is not connected."),
            workouts: []
        )
    }

    static func make(
        whoop: WhoopDayReading,
        strava: StravaDayReading,
        health: HealthDaySummary,
        mercury: MercuryDayReading = .disconnected(dayKey: "", reason: "TODO: Mercury is not connected.")
    ) -> DayIntegrationSnapshot {
        let events = whoop.workouts + strava.activities + health.workouts
        return DayIntegrationSnapshot(
            whoop: whoop,
            strava: strava,
            health: health,
            mercury: mercury,
            workouts: WorkoutDedupe.canonical(events)
        )
    }
}
