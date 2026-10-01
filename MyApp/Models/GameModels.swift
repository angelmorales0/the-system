import Foundation

/// Seven persistent stats. FIN is finance discipline (Mercury aggregates later).
enum Stat: String, Codable, CaseIterable, Equatable {
    case STR, END, INT, AGI, FOC, REC, FIN
}

enum QuestMode: String, Codable, CaseIterable, Equatable {
    case performanceTraining = "performance_training"
    case interviewPrep = "interview_prep"
    case studyBlock = "study_block"
    case recovery
    case fullRecovery = "full_recovery"
    case nutritionFocus = "nutrition_focus"
    case financeDiscipline = "finance_discipline"
    case focusDeepwork = "focus_deepwork"
    case hybrid
    case penalty

    /// Text inside `[Daily Quest: {headerLine} has arrived.]`
    var headerLine: String {
        switch self {
        case .performanceTraining: "Performance Training"
        case .interviewPrep: "Interview Prep"
        case .studyBlock: "Study Block"
        case .recovery: "Recovery"
        case .fullRecovery: "Full Recovery Day"
        case .nutritionFocus: "Nutrition Focus"
        case .financeDiscipline: "Finance Discipline"
        case .focusDeepwork: "Deep Work"
        case .hybrid: "Hybrid Training"
        case .penalty: "Penalty Quest"
        }
    }
}

enum QuestKind: String, Codable, Equatable {
    case daily
    case optional
    case targetInjection = "target_injection"
    case penalty
}

enum Difficulty: String, Codable, Equatable {
    case easy, normal, hard, penalty

    /// Stat points granted on completion. Penalty days tax XP, not this weight.
    var statWeight: Int {
        switch self {
        case .easy: 1
        case .normal: 2
        case .hard: 3
        case .penalty: 2
        }
    }
}

enum QuestStatus: String, Codable, Equatable {
    case pending, completed, failed, expired
}

enum ReadinessBand: String, Codable, CaseIterable, Equatable {
    case green, yellow, red
}

enum VerificationMethod: String, Codable, CaseIterable, Equatable {
    case whoopStrain = "whoop_strain"
    case whoopRecovery = "whoop_recovery"
    case stravaActivity = "strava_activity"
    case healthkitWorkout = "healthkit_workout"
    case healthkitNutrition = "healthkit_nutrition"
    case macrofactorProtein = "macrofactor_protein"
    case mercurySpendUnder = "mercury_spend_under"
    case screenTimeLimit = "screen_time_limit"
    case manualConfirm = "manual_confirm"
    case timerSession = "timer_session"
}

enum QuestRewardType: String, Codable, Equatable {
    case fullRecoveryToken = "full_recovery_token"
    case xpBonus = "xp_bonus"
    case none
}

/// Heterogeneous JSON used for verification params. Phase 2 verifiers read these.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct VerificationSpec: Codable, Equatable {
    var method: VerificationMethod
    var params: [String: JSONValue]
}

struct QuestProgress: Codable, Equatable {
    var current: Double
    var target: Double
    var unit: String

    /// Matches the existing row style: `[0/6]`, `[0/10min]`, `[0/150g]`.
    var bracketLabel: String {
        let currentText = Self.figure(current)
        let targetText = Self.figure(target)
        if Self.inlineUnits.contains(unit) {
            return "[\(currentText)/\(targetText)\(unit)]"
        }
        return "[\(currentText)/\(targetText)]"
    }

    private static let inlineUnits: Set<String> = ["min", "g", "h", "usd", "kcal"]

    private static func figure(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < Double(Int.max) {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

struct QuestReward: Codable, Equatable {
    var type: QuestRewardType
    var amount: Int
}

struct Quest: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var kind: QuestKind
    var stat: Stat
    var verification: VerificationSpec
    var deadline: Date
    var xp: Int
    var difficulty: Difficulty
    var mode: QuestMode
    var targetId: String?
    var progress: QuestProgress
    var reward: QuestReward?
    var status: QuestStatus
    /// Points actually applied, so a checkbox toggle can reverse the same grant.
    var grantedXP: Int
    var grantedStatPoints: Int
    var grantedRecoveryToken: Bool
    /// Observations that moved this quest. Empty until a verifier applies one.
    var evidence: [Evidence] = []
    /// Manual confirm waits 30 seconds after this. Model output cannot choose it.
    var assignedAt: Date = .distantPast
}

extension Quest {
    private enum CodingKeys: String, CodingKey {
        case id, title, kind, stat, verification, deadline, xp, difficulty, mode
        case targetId, progress, reward, status, grantedXP, grantedStatPoints, grantedRecoveryToken
        case evidence, assignedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(QuestKind.self, forKey: .kind)
        stat = try container.decode(Stat.self, forKey: .stat)
        verification = try container.decode(VerificationSpec.self, forKey: .verification)
        deadline = try container.decode(Date.self, forKey: .deadline)
        xp = try container.decode(Int.self, forKey: .xp)
        difficulty = try container.decode(Difficulty.self, forKey: .difficulty)
        mode = try container.decode(QuestMode.self, forKey: .mode)
        targetId = try container.decodeIfPresent(String.self, forKey: .targetId)
        progress = try container.decode(QuestProgress.self, forKey: .progress)
        reward = try container.decodeIfPresent(QuestReward.self, forKey: .reward)
        status = try container.decode(QuestStatus.self, forKey: .status)
        grantedXP = try container.decodeIfPresent(Int.self, forKey: .grantedXP) ?? 0
        grantedStatPoints = try container.decodeIfPresent(Int.self, forKey: .grantedStatPoints) ?? 0
        grantedRecoveryToken = try container.decodeIfPresent(Bool.self, forKey: .grantedRecoveryToken) ?? false
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        assignedAt = try container.decodeIfPresent(Date.self, forKey: .assignedAt) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(stat, forKey: .stat)
        try container.encode(verification, forKey: .verification)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(xp, forKey: .xp)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(targetId, forKey: .targetId)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(reward, forKey: .reward)
        try container.encode(status, forKey: .status)
        try container.encode(grantedXP, forKey: .grantedXP)
        try container.encode(grantedStatPoints, forKey: .grantedStatPoints)
        try container.encode(grantedRecoveryToken, forKey: .grantedRecoveryToken)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(assignedAt, forKey: .assignedAt)
    }
}

struct QuestBundle: Codable, Equatable {
    var schemaVersion: Int
    var dayKey: String
    var mode: QuestMode
    var headerLine: String
    var narrative: String
    var quests: [Quest]
    var warnings: [String]
    /// `"fallback"` in Phase 1. `"llm"` arrives with the backend.
    var generatedBy: String

    var goalQuests: [Quest] {
        quests.filter { $0.kind != .optional }
    }

    var warningCopy: String {
        let text = warnings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? Self.defaultWarning : text
    }

    static let defaultWarning = "Failure to complete\nthe daily quest will result\nin a penalty."

    /// Generated bundles may propose method and params only. Completion, evidence, and assign time are local.
    func strippingModelCompletion(assignedAt: Date) -> QuestBundle {
        var copy = self
        copy.quests = quests.map { quest in
            var quest = quest
            quest.status = .pending
            quest.evidence = []
            quest.grantedXP = 0
            quest.grantedStatPoints = 0
            quest.grantedRecoveryToken = false
            quest.progress.current = 0
            quest.assignedAt = assignedAt
            return quest
        }
        return copy
    }
}

struct StatValues: Codable, Equatable {
    var STR: Int
    var END: Int
    var INT: Int
    var AGI: Int
    var FOC: Int
    var REC: Int
    var FIN: Int

    static let starter = StatValues(STR: 142, END: 155, INT: 128, AGI: 134, FOC: 121, REC: 118, FIN: 110)

    subscript(stat: Stat) -> Int {
        get {
            switch stat {
            case .STR: STR
            case .END: END
            case .INT: INT
            case .AGI: AGI
            case .FOC: FOC
            case .REC: REC
            case .FIN: FIN
            }
        }
        set {
            switch stat {
            case .STR: STR = newValue
            case .END: END = newValue
            case .INT: INT = newValue
            case .AGI: AGI = newValue
            case .FOC: FOC = newValue
            case .REC: REC = newValue
            case .FIN: FIN = newValue
            }
        }
    }

    var radar: [(label: String, value: Double)] {
        Stat.allCases.map { (label: $0.rawValue, value: Double(self[$0])) }
    }
}

struct PlayerState: Codable, Equatable {
    static let fullRecoveryCap = 3

    var displayName: String
    var level: Int
    var xp: Int
    var xpToNext: Int
    var stats: StatValues
    var fullRecoveryBank: Int
    var penaltyTier: Int

    static let starter = PlayerState(
        displayName: "Angel",
        level: 42,
        xp: 3420,
        xpToNext: 5000,
        stats: .starter,
        fullRecoveryBank: 2,
        penaltyTier: 0
    )

    var statusDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Angel" : trimmed).uppercased()
    }

    var xpProgress: Double {
        guard xpToNext > 0 else { return 0 }
        return min(max(Double(xp) / Double(xpToNext), 0), 1)
    }

    var xpLabel: String {
        "XP     \(Self.grouped(xp)) / \(Self.grouped(xpToNext))"
    }

    mutating func addXP(_ amount: Int) {
        guard amount > 0 else { return }
        xp += amount
        let step = max(xpToNext, 1)
        while xp >= step {
            xp -= step
            level += 1
        }
    }

    mutating func removeXP(_ amount: Int) {
        guard amount > 0 else { return }
        xp -= amount
        let step = max(xpToNext, 1)
        while xp < 0 && level > 1 {
            level -= 1
            xp += step
        }
        if xp < 0 { xp = 0 }
    }

    @discardableResult
    mutating func depositRecoveryToken() -> Bool {
        guard fullRecoveryBank < Self.fullRecoveryCap else { return false }
        fullRecoveryBank += 1
        return true
    }

    mutating func withdrawRecoveryToken() {
        if fullRecoveryBank > 0 { fullRecoveryBank -= 1 }
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Placeholder morning inputs. WHOOP, calendar, and Targets replace these in later phases.
struct MorningSignals: Codable, Equatable {
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
    var activeTarget: Bool
    var calendarBusyMinutes: Int
    var spendingFullRecovery: Bool

    static let placeholder = MorningSignals(
        readinessBand: .green,
        sleepPerformance: 81,
        activeTarget: false,
        calendarBusyMinutes: 180,
        spendingFullRecovery: false
    )
}

enum QuestDay {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func isSunday(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    static func endOfDay(_ date: Date) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }
}
