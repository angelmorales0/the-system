import Foundation

/// Seven persistent stats. FIN is quest XP plus a small Mercury projection, not a balance.
enum Stat: String, Codable, CaseIterable, Equatable {
    case STR, END, INT, AGI, FOC, REC, FIN
}

enum QuestMode: String, Codable, CaseIterable, Equatable {
    case performanceTraining = "performance_training"
    case fullRecovery = "full_recovery"

    /// Text inside `[Daily Quest: {headerLine} has arrived.]`
    var headerLine: String {
        switch self {
        case .performanceTraining: "Training"
        case .fullRecovery: "Full Recovery Day"
        }
    }

    /// Old saves can name removed modes (`recovery`, `hybrid`, `interview_prep`, `study_block`, `nutrition_focus`,
    /// `finance_discipline`, `focus_deepwork`, `penalty`). Read those as Performance Training.
    /// An old Penalty day keeps its `kind: .penalty` rows, so clearing them still closes the penalty.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QuestMode(rawValue: raw) ?? .performanceTraining
    }
}

enum QuestKind: String, Codable, Equatable {
    case daily
    case optional
    case penalty
}

enum Difficulty: String, Codable, Equatable {
    case easy, normal, hard, penalty
}

enum QuestStatus: String, Codable, Equatable {
    case pending, completed, failed, expired
}

enum ReadinessBand: String, Codable, CaseIterable, Equatable {
    case green, yellow, red
}

enum VerificationMethod: String, Codable, CaseIterable, Equatable {
    case whoopStrain = "whoop_strain"
    case stravaActivity = "strava_activity"
    case hevySets = "hevy_sets"
    case healthkitWorkout = "healthkit_workout"
    case screenTimeLimit = "screen_time_limit"
    case manualConfirm = "manual_confirm"
    case timerSession = "timer_session"

    /// Old saves can name removed methods (`whoop_recovery`, `healthkit_nutrition`, `macrofactor_protein`,
    /// `mercury_spend_under`). Read those as a manual confirm, so the save still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VerificationMethod(rawValue: raw) ?? .manualConfirm
    }
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

    private static let inlineUnits: Set<String> = ["min", "g", "h", "usd", "kcal", "km"]

    private static func figure(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < Double(Int.max) {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

struct Quest: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var kind: QuestKind
    var stat: Stat
    var verification: VerificationSpec
    var deadline: Date
    var difficulty: Difficulty
    var mode: QuestMode
    var progress: QuestProgress
    var status: QuestStatus
    /// Observations that moved this quest. Empty until a verifier applies one.
    var evidence: [Evidence] = []
    /// Manual confirm waits 30 seconds after this. Model output cannot choose it.
    var assignedAt: Date = .distantPast
    /// True when a potion cleared this quest. It is `.completed` with no XP, and the day earns no gold.
    var skippedWithPotion: Bool = false
}

extension Quest {
    private enum CodingKeys: String, CodingKey {
        case id, title, kind, stat, verification, deadline, difficulty, mode
        case progress, status
        case evidence, assignedAt, skippedWithPotion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(QuestKind.self, forKey: .kind)
        stat = try container.decode(Stat.self, forKey: .stat)
        verification = try container.decode(VerificationSpec.self, forKey: .verification)
        deadline = try container.decode(Date.self, forKey: .deadline)
        difficulty = try container.decode(Difficulty.self, forKey: .difficulty)
        mode = try container.decode(QuestMode.self, forKey: .mode)
        progress = try container.decode(QuestProgress.self, forKey: .progress)
        // Model JSON omits status. A present value is still cleared by strippingModelCompletion.
        status = try container.decodeIfPresent(QuestStatus.self, forKey: .status) ?? .pending
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        assignedAt = try container.decodeIfPresent(Date.self, forKey: .assignedAt) ?? .distantPast
        skippedWithPotion = try container.decodeIfPresent(Bool.self, forKey: .skippedWithPotion) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(stat, forKey: .stat)
        try container.encode(verification, forKey: .verification)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(mode, forKey: .mode)
        try container.encode(progress, forKey: .progress)
        try container.encode(status, forKey: .status)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(assignedAt, forKey: .assignedAt)
        try container.encode(skippedWithPotion, forKey: .skippedWithPotion)
    }
}

/// Decodes one quest, or nil when its kind no longer exists.
private struct SkippableQuest: Decodable {
    var quest: Quest?

    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
        quest = QuestKind(rawValue: kind) == nil ? nil : try Quest(from: decoder)
    }
}

struct QuestBundle: Codable, Equatable {
    var schemaVersion: Int
    var dayKey: String
    var mode: QuestMode
    var headerLine: String
    var narrative: String
    /// The penalty screen's two sentences, written by the generator with the day. Nil keeps the app's own line.
    var threat: String?
    var quests: [Quest]
    var warnings: [String]
    /// `"fallback"` is the on-device catalog. `"mock"`, `"template"`, and `"llm"` are generated bundles.
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
            quest.skippedWithPotion = false
            quest.progress.current = 0
            quest.assignedAt = assignedAt
            return quest
        }
        return copy
    }
}

extension QuestBundle {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dayKey, mode, headerLine, narrative, threat, quests, warnings, generatedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        mode = try container.decode(QuestMode.self, forKey: .mode)
        let line = try container.decodeIfPresent(String.self, forKey: .headerLine) ?? ""
        headerLine = line.isEmpty ? mode.headerLine : line
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        threat = try container.decodeIfPresent(String.self, forKey: .threat)
        // Old saves can hold quests of a removed kind (Target quests). Skip those rows so the rest of the save still loads.
        quests = try container.decodeIfPresent([SkippableQuest].self, forKey: .quests)?.compactMap(\.quest) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        let author = try container.decodeIfPresent(String.self, forKey: .generatedBy) ?? ""
        generatedBy = author.isEmpty ? "llm" : author
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(mode, forKey: .mode)
        try container.encode(headerLine, forKey: .headerLine)
        try container.encode(narrative, forKey: .narrative)
        try container.encodeIfPresent(threat, forKey: .threat)
        try container.encode(quests, forKey: .quests)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(generatedBy, forKey: .generatedBy)
    }
}

/// What the player carries between days. The level and the seven stats are not here: `StatLevelSet` computes
/// them from the real histories, and old saves' `level`, `xp`, `xpToNext`, and `stats` keys are ignored, as are a quest's old `xp` and `reward` keys.
struct PlayerState: Equatable {
    var displayName: String
    var fullRecoveryBank: Int
    /// A penalty is open: a missed required set owes a 10K.
    var penaltyOpen: Bool

    static let starter = PlayerState(
        displayName: "Angel",
        fullRecoveryBank: 7,
        penaltyOpen: false
    )

    var statusDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Angel" : trimmed).uppercased()
    }

    /// The bank has no cap.
    mutating func depositRecoveryToken() {
        fullRecoveryBank += 1
    }

    mutating func withdrawRecoveryToken() {
        if fullRecoveryBank > 0 { fullRecoveryBank -= 1 }
    }
}

extension PlayerState: Codable {
    private enum CodingKeys: String, CodingKey {
        case displayName, fullRecoveryBank, penaltyOpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Angel"
        fullRecoveryBank = try container.decodeIfPresent(Int.self, forKey: .fullRecoveryBank) ?? 0
        penaltyOpen = try container.decodeIfPresent(Bool.self, forKey: .penaltyOpen) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(fullRecoveryBank, forKey: .fullRecoveryBank)
        try container.encode(penaltyOpen, forKey: .penaltyOpen)
    }
}

/// Placeholder morning inputs. Only `spendingFullRecovery` drives the day.
/// The band and sleep stay for old saves. The picker reads `GameSnapshot.readiness` captured today.
struct MorningSignals: Codable, Equatable {
    var readinessBand: ReadinessBand
    var sleepPerformance: Int?
    var spendingFullRecovery: Bool

    static let placeholder = MorningSignals(
        readinessBand: .green,
        sleepPerformance: 81,
        spendingFullRecovery: false
    )
}

enum QuestDay {
    /// The phone's current time zone, so the quest day starts at 5:00 local time while traveling.
    static var timeZone: TimeZone { .autoupdatingCurrent }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// A quest day runs from 5:00 local time to 5:00 the next morning. 1:00 AM still belongs to the day before.
    static let startHour = 5

    static func key(for date: Date) -> String {
        let local = calendar.component(.hour, from: date) < startHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// 5:00 local time on the quest day `key`.
    static func start(of key: String) -> Date? {
        guard let noon = date(from: key) else { return nil }
        return calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: noon)
    }

    /// The quest day that holds `date`, from its 5:00 start to the next day's 5:00.
    static func interval(for date: Date) -> DateInterval {
        let key = key(for: date)
        guard let start = Self.start(of: key),
              let end = Self.start(of: Self.key(byAddingDays: 1, to: key)) else {
            return DateInterval(start: date, duration: 86_400)
        }
        return DateInterval(start: start, end: end)
    }

    /// The last second before the next quest day starts at 5:00.
    static func endOfDay(_ date: Date) -> Date {
        interval(for: date).end.addingTimeInterval(-1)
    }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components)
    }

    static func key(byAddingDays days: Int, to key: String) -> String {
        guard let date = date(from: key), let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return self.key(for: shifted)
    }
}
