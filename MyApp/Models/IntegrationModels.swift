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

struct DayIntegrationSnapshot: Equatable {
    var whoop: WhoopDayReading
    var strava: StravaDayReading
    var health: HealthDaySummary
    var workouts: [CanonicalWorkout]

    static func empty(dayKey: String) -> DayIntegrationSnapshot {
        DayIntegrationSnapshot(
            whoop: .disconnected(dayKey: dayKey, reason: "TODO: WHOOP is not connected."),
            strava: .disconnected(dayKey: dayKey, reason: "TODO: Strava is not connected."),
            health: .unavailable,
            workouts: []
        )
    }

    static func make(whoop: WhoopDayReading, strava: StravaDayReading, health: HealthDaySummary) -> DayIntegrationSnapshot {
        let events = whoop.workouts + strava.activities + health.workouts
        return DayIntegrationSnapshot(
            whoop: whoop,
            strava: strava,
            health: health,
            workouts: WorkoutDedupe.canonical(events)
        )
    }
}
