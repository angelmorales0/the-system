import Foundation

struct MorningStreaks: Codable, Equatable {
    var dailyQuestClear: Int
    var training: Int
    var proteinHit: Int
    var missedLastNDays: Int

    static let unknown = MorningStreaks(dailyQuestClear: 0, training: 0, proteinHit: 0, missedLastNDays: 0)
}

struct MorningPlayer: Codable, Equatable {
    var timezone: String
    var localDate: String
    var weekday: String
    var level: Int
    var xp: Int
    var xpToNext: Int
    var stats: StatValues
    var fullRecoveryBank: Int
    var penaltyTier: Int
    var streaks: MorningStreaks
}

struct MorningModeDecision: Codable, Equatable {
    var selectedMode: QuestMode
    /// Band the generator sizes Training quests to. `whoop.readinessBand` stays the raw WHOOP band.
    var trainingBand: ReadinessBand
    var reasonCodes: [String]
    var lockedByRules: Bool

    init(_ decision: ModeDecision) {
        selectedMode = decision.selectedMode
        trainingBand = decision.trainingBand
        reasonCodes = decision.reasonCodes
        lockedByRules = decision.lockedByRules
    }
}

struct MorningWhoop: Codable, Equatable {
    var available: Bool
    var recoveryScore: Int?
    var restingHr: Int?
    var hrv: Int?
    var sleepPerformance: Int?
    var dayStrainYesterday: Double?
    var readinessBand: ReadinessBand
}

struct MorningGoalBias: Codable, Equatable {
    var id: String
    var title: String
    var statHint: String
    var progress: Double
}

struct MorningNutrition: Codable, Equatable {
    var source: String
    var available: Bool
    var proteinG: Double?
    var proteinTargetG: Int?
    var calories: Double?
    var calorieTarget: Int?
    var asOf: String?
}

struct MorningMercury: Codable, Equatable {
    var available: Bool
    var spendTodayUsd: Double?
    var softDailyCapUsd: Double?
    var discretionary7dUsd: Double?
    var state: String
}

struct MorningFocus: Codable, Equatable {
    var screenTimeAvailable: Bool
    var distractingMinutesYesterday: Int?
    var deepWorkMinutesYesterday: Int?
    var pickupCountYesterday: Int?
}

struct MorningFreshness: Codable, Equatable {
    var whoop: String
    var strava: String
    var healthkit: String
    var mercury: String
    var screenTime: String

    static let offline = MorningFreshness(
        whoop: "unavailable",
        strava: "unavailable",
        healthkit: "unavailable",
        mercury: "unavailable",
        screenTime: "unavailable"
    )
}

struct MorningConstraints: Codable, Equatable {
    var maxRequiredQuests: Int
    var maxOptionalQuests: Int
    var preferAutoVerify: Bool
    var disallowUnsafeAdvice: Bool
    /// The player has no gym today: no strength quests, two 10K runs instead.
    var noGymToday = false

    static let standard = MorningConstraints(
        maxRequiredQuests: 5,
        maxOptionalQuests: 1,
        preferAutoVerify: true,
        disallowUnsafeAdvice: true
    )
}

/// Redacted morning summary. Mercury is category totals only, and only after a backend snapshot.
struct MorningContext: Codable, Equatable {
    var schemaVersion: Int
    var player: MorningPlayer
    var modeDecision: MorningModeDecision
    var whoop: MorningWhoop
    var goalsBias: [MorningGoalBias]
    var nutrition: MorningNutrition
    var mercury: MorningMercury
    var focus: MorningFocus
    var integrationsFreshness: MorningFreshness
    var recentQuestTitles: [String]
    var constraints: MorningConstraints
}
