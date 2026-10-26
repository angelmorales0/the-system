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

    /// A split day is up to 6 lifts plus up to two 10Ks.
    static let standard = MorningConstraints(
        maxRequiredQuests: 8,
        maxOptionalQuests: 1,
        preferAutoVerify: true,
        disallowUnsafeAdvice: true
    )
}

/// One assigned quest on a past day, and how far it got.
struct QuestRecord: Codable, Equatable {
    var title: String
    var kind: QuestKind
    var stat: Stat
    var method: VerificationMethod
    var params: [String: JSONValue]
    var target: Double
    var done: Double
    var unit: String
    var status: QuestStatus
}

/// One past quest day as it ended: the plan the app assigned and what was done.
/// Saved in the snapshot for 30 days so the generator can see what it planned before.
struct QuestDayRecord: Codable, Equatable {
    static let keepDays = 30

    var dayKey: String
    var mode: QuestMode
    var trainingBand: ReadinessBand
    var noGym: Bool
    /// `GymSplit.Day.id` when the day was a split day. Nil for older saves and days without lifts.
    var splitDay: String? = nil
    var generatedBy: String
    /// A required quest was still open at the end of the day, so the penalty tier rose.
    var missedRequired: Bool
    var quests: [QuestRecord]
}

/// One STR target the player kept, so the generator plans toward the real goals.
struct MorningStrengthTarget: Codable, Equatable {
    var category: String
    var goal: String
    /// Hevy exercise names (without equipment) that count toward this target.
    var aliases: [String]
    var targetLb: Double?
    var targetReps: Int?
    var unit: String
}

/// One END target the player kept, in words.
struct MorningTarget: Codable, Equatable {
    var category: String
    var goal: String
}

struct MorningBodyWeight: Codable, Equatable {
    var targetLb: Double
    var toleranceLb: Double
    var latestLb: Double?
    var measuredOn: String?
    var source: String?
}

/// The gym split the generator follows: today's day, its exercises, and when each day was last done.
struct MorningSplit: Codable, Equatable {
    var name: String
    var rotation: [String]
    var today: GymSplit.Day
    /// Split day name → the newest day it was done.
    var lastDone: [String: String]
}

/// The player's goals. The backend adds the 30-day training history that measures them.
struct MorningGoals: Codable, Equatable {
    var weeklyTenKs: Int
    /// STR targets to put first right now.
    var focus: [String] = []
    var strength: [MorningStrengthTarget]
    var endurance: [MorningTarget]
    var bodyWeight: MorningBodyWeight
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
    /// Up to 30 past quest days, newest first.
    var recentDays: [QuestDayRecord] = []
    var goals: MorningGoals? = nil
    var split: MorningSplit? = nil
}
