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

extension ReadinessBand {
    /// WHOOP bands: green 67–100, yellow 34–66, red 0–33.
    static func from(recoveryScore score: Int) -> ReadinessBand {
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }

    /// A score inside the band, for self-checks.
    var sampleRecoveryScore: Int {
        switch self {
        case .green: 80
        case .yellow: 50
        case .red: 20
        }
    }
}

extension ReadinessSnapshot {
    /// A reading in `band`, captured on `dayKey`. Self-checks use it to set a day's readiness.
    static func sample(_ band: ReadinessBand, on dayKey: String, sleepPerformance: Int? = nil) -> ReadinessSnapshot {
        ReadinessSnapshot(
            recoveryScore: band.sampleRecoveryScore,
            restingHr: nil,
            hrv: nil,
            sleepPerformance: sleepPerformance,
            band: band,
            capturedOn: dayKey
        )
    }
}

enum HealthAccess: String, Codable, Equatable {
    case unavailable
    case notRequested
    case requested
}

struct HealthDaySummary: Equatable {
    var access: HealthAccess
    var workouts: [WorkoutEvent]

    static let unavailable = HealthDaySummary(access: .unavailable, workouts: [])
}

nonisolated struct WhoopDayReading: Codable, Equatable {
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

nonisolated struct StravaDayReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var dayKey: String
    var activities: [WorkoutEvent]

    static func disconnected(dayKey: String, reason: String) -> StravaDayReading {
        StravaDayReading(available: false, configured: false, reason: reason, dayKey: dayKey, activities: [])
    }
}

/// One set from Hevy. Weight is in kilograms; bodyweight and timed sets have no weight. Timed sets have a duration.
nonisolated struct HevySet: Codable, Equatable {
    var type: String
    var reps: Int?
    var weightKg: Double?
    var rpe: Double?
    /// Hold time for timed sets such as stretches.
    var durationSec: Double?
    /// Distance for distance sets: carries, and the AGI tests logged as a distance (see `AgilityHevy`).
    var distanceMeters: Double? = nil

    /// Warm-up sets do not count toward a quest.
    var isWorking: Bool { type.lowercased() != "warmup" }
}

nonisolated struct HevyExercise: Codable, Equatable {
    var title: String
    var templateId: String?
    var sets: [HevySet]
}

nonisolated struct HevyWorkout: Codable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var exercises: [HevyExercise]
}

/// Backend Hevy summary for one local day: exercises, sets, reps, and kg. No API key and no notes.
nonisolated struct HevyDayReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var dayKey: String
    var workouts: [HevyWorkout]

    static func disconnected(dayKey: String, reason: String) -> HevyDayReading {
        HevyDayReading(available: false, configured: false, reason: reason, dayKey: dayKey, workouts: [])
    }
}

/// Backend Mercury summary for one local day. No token and no raw transaction list.
nonisolated struct MercuryDayReading: Codable, Equatable {
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

struct DayIntegrationSnapshot: Equatable {
    var whoop: WhoopDayReading
    var strava: StravaDayReading
    var health: HealthDaySummary
    var mercury: MercuryDayReading = .disconnected(dayKey: "", reason: "TODO: Mercury is not connected.")
    var hevy: HevyDayReading = .disconnected(dayKey: "", reason: "TODO: Hevy is not connected.")
    var workouts: [CanonicalWorkout]

    static func empty(dayKey: String) -> DayIntegrationSnapshot {
        DayIntegrationSnapshot(
            whoop: .disconnected(dayKey: dayKey, reason: "TODO: WHOOP is not connected."),
            strava: .disconnected(dayKey: dayKey, reason: "TODO: Strava is not connected."),
            health: .unavailable,
            mercury: .disconnected(dayKey: dayKey, reason: "TODO: Mercury is not connected."),
            hevy: .disconnected(dayKey: dayKey, reason: "TODO: Hevy is not connected."),
            workouts: []
        )
    }

    static func make(
        whoop: WhoopDayReading,
        strava: StravaDayReading,
        health: HealthDaySummary,
        mercury: MercuryDayReading = .disconnected(dayKey: "", reason: "TODO: Mercury is not connected."),
        hevy: HevyDayReading = .disconnected(dayKey: "", reason: "TODO: Hevy is not connected.")
    ) -> DayIntegrationSnapshot {
        let events = whoop.workouts + strava.activities + health.workouts
        return DayIntegrationSnapshot(
            whoop: whoop,
            strava: strava,
            health: health,
            mercury: mercury,
            hevy: hevy,
            workouts: WorkoutDedupe.canonical(events)
        )
    }
}
