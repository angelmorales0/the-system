import Foundation

enum TargetKind: String, Codable, CaseIterable, Equatable {
    case interviewPrep = "interview_prep"
    case study
    case cut
    case custom

    var title: String {
        switch self {
        case .interviewPrep: "Interview Prep"
        case .study: "Study"
        case .cut: "Cut"
        case .custom: "Custom"
        }
    }
}

enum TargetStatus: String, Codable, CaseIterable, Equatable {
    case draft, scheduled, active, completed, expired, aborted

    var label: String { rawValue.uppercased() }
}

struct TargetDailyRequirement: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var quota: Double
    var unit: String
    var stat: Stat
    var verification: VerificationMethod
    var xp: Int
}

/// Time-bounded campaign. At most one Target is active.
struct Target: Identifiable, Codable, Equatable {
    static let completionXP = 150

    var id: String
    var title: String
    var kind: TargetKind
    var status: TargetStatus
    /// Local dates `yyyy-MM-dd` in America/Los_Angeles.
    var startsOn: String
    var endsOn: String
    var dailyRequirements: [TargetDailyRequirement]
    var unitsGoal: Int?
    var unitsDone: Int
    var daysCleared: Int
    var clearedDayKeys: [String]
    /// Quest ids that already added their quota, so a bundle rebuild cannot count the same row twice.
    var countedQuestIds: [String]
    var completionBonusGranted: Bool

    var spanDays: Int { QuestDay.daySpan(from: startsOn, to: endsOn) }

    func contains(_ dayKey: String) -> Bool {
        dayKey >= startsOn && dayKey <= endsOn
    }

    func dayNumber(on dayKey: String) -> Int {
        QuestDay.daySpan(from: startsOn, to: min(max(dayKey, startsOn), endsOn))
    }

    var progressFraction: Double {
        let goal = unitsGoal ?? spanDays
        guard goal > 0 else { return 0 }
        if unitsGoal != nil {
            return min(max(Double(unitsDone) / Double(goal), 0), 1)
        }
        return min(max(Double(daysCleared) / Double(goal), 0), 1)
    }

    var progressLabel: String {
        if let unitsGoal {
            return "\(unitsDone) / \(unitsGoal)"
        }
        return "\(daysCleared) / \(spanDays) days"
    }

    func isSatisfied(today: String) -> Bool {
        if let unitsGoal, unitsDone >= unitsGoal { return true }
        return daysCleared >= spanDays && today > endsOn
    }

    /// Returns whether the caller should grant the one-time XP bonus.
    mutating func markCompletedIfNeeded(today: String) -> Bool {
        guard status == .active, isSatisfied(today: today) else { return false }
        status = .completed
        let grant = !completionBonusGranted
        completionBonusGranted = true
        return grant
    }

    /// Returns whether the caller should take back the completion bonus.
    mutating func reopenIfIncomplete(today: String) -> Bool {
        guard status == .completed, completionBonusGranted, !isSatisfied(today: today) else { return false }
        status = .active
        completionBonusGranted = false
        return true
    }

    mutating func noteQuestCompleted(questId: String, quota: Int, dayKey: String, dayFullyCleared: Bool) {
        if !countedQuestIds.contains(questId) {
            countedQuestIds.append(questId)
            unitsDone += max(quota, 0)
        }
        if dayFullyCleared, !clearedDayKeys.contains(dayKey) {
            clearedDayKeys.append(dayKey)
            daysCleared = clearedDayKeys.count
        }
    }

    mutating func noteQuestUndone(questId: String, quota: Int, dayKey: String, dayFullyCleared: Bool) {
        if countedQuestIds.contains(questId) {
            countedQuestIds.removeAll { $0 == questId }
            unitsDone = max(0, unitsDone - max(quota, 0))
        }
        if !dayFullyCleared {
            clearedDayKeys.removeAll { $0 == dayKey }
            daysCleared = clearedDayKeys.count
        }
    }

    func makeQuest(requirement: TargetDailyRequirement, dayKey: String, now: Date, mode: QuestMode) -> Quest {
        Quest(
            id: "q_\(dayKey)_tgt_\(id)_\(requirement.id)",
            title: requirement.title,
            kind: .targetInjection,
            stat: requirement.stat,
            verification: VerificationSpec(method: requirement.verification, params: requirement.params),
            deadline: QuestDay.endOfDay(now),
            xp: requirement.xp,
            difficulty: .normal,
            mode: mode,
            targetId: id,
            progress: QuestProgress(current: 0, target: requirement.quota, unit: requirement.unit),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: now
        )
    }

    static func interviewPrep(starting dayKey: String) -> Target {
        let end = QuestDay.key(byAddingDays: 13, to: dayKey)
        return Target(
            id: "tgt_\(UUID().uuidString.prefix(8))",
            title: "Interview Prep",
            kind: .interviewPrep,
            status: .draft,
            startsOn: dayKey,
            endsOn: end,
            dailyRequirements: [
                TargetDailyRequirement(
                    id: "leetcode",
                    title: "LeetCode Mediums",
                    quota: 3,
                    unit: "problems",
                    stat: .INT,
                    verification: .manualConfirm,
                    xp: 40
                )
            ],
            unitsGoal: 42,
            unitsDone: 0,
            daysCleared: 0,
            clearedDayKeys: [],
            countedQuestIds: [],
            completionBonusGranted: false
        )
    }
}

extension TargetDailyRequirement {
    var params: [String: JSONValue] {
        switch verification {
        case .manualConfirm:
            return ["prompt": .string("Confirm \(title)")]
        case .timerSession:
            let seconds = unit == "min" ? quota * 60 : quota
            return ["minSec": .number(seconds), "label": .string(title)]
        default:
            return [:]
        }
    }
}

extension QuestBundle {
    /// Catalog placeholders are replaced by this Target's daily requirements. Training rows stay.
    func injecting(_ target: Target, now: Date) -> QuestBundle {
        var copy = self
        let training = quests.filter { $0.kind != .targetInjection }
        let injected = target.dailyRequirements.map {
            target.makeQuest(requirement: $0, dayKey: dayKey, now: now, mode: mode)
        }
        copy.quests = injected + training
        return copy
    }
}

enum TargetRules {
    static func check() -> [String] {
        var errors: [String] = []
        let today = "2026-10-01"
        let sample = Target.interviewPrep(starting: today)
        if sample.spanDays != 14 || sample.endsOn != "2026-10-14" || sample.unitsGoal != 42 {
            errors.append("interview prep should be 14 days ending 2026-10-14 with 42 units")
        }
        if sample.dayNumber(on: today) != 1 || sample.dayNumber(on: "2026-10-04") != 4 {
            errors.append("day number should be inclusive from the start")
        }
        if !sample.contains(today) || sample.contains("2026-10-15") {
            errors.append("window check failed")
        }

        let placeholder = Quest(
            id: "catalog_leetcode",
            title: "Catalog LeetCode",
            kind: .targetInjection,
            stat: .INT,
            verification: VerificationSpec(method: .manualConfirm, params: [:]),
            deadline: Date(timeIntervalSince1970: 1_700_000_000),
            xp: 10,
            difficulty: .easy,
            mode: .hybrid,
            targetId: "catalog",
            progress: QuestProgress(current: 0, target: 3, unit: "problems"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false
        )
        let training = Quest(
            id: "run",
            title: "Easy Run",
            kind: .daily,
            stat: .END,
            verification: VerificationSpec(method: .stravaActivity, params: [:]),
            deadline: placeholder.deadline,
            xp: 20,
            difficulty: .easy,
            mode: .hybrid,
            targetId: nil,
            progress: QuestProgress(current: 0, target: 20, unit: "min"),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false
        )
        let bundle = QuestBundle(
            schemaVersion: 1,
            dayKey: today,
            mode: .hybrid,
            headerLine: "Hybrid Training",
            narrative: "",
            quests: [training, placeholder],
            warnings: [],
            generatedBy: "fallback"
        )
        let now = QuestDay.date(from: today) ?? Date(timeIntervalSince1970: 1_700_000_000)
        let injected = bundle.injecting(sample, now: now)
        let titles = injected.quests.map(\.title)
        if titles != ["LeetCode Mediums", "Easy Run"] {
            errors.append("injection should replace catalog target rows, got \(titles)")
        }
        if injected.quests[0].kind != .targetInjection || injected.quests[0].targetId != sample.id {
            errors.append("injected row should point at the Target")
        }

        var progress = sample
        progress.status = .active
        progress.noteQuestCompleted(questId: "q1", quota: 3, dayKey: today, dayFullyCleared: true)
        if progress.unitsDone != 3 || progress.daysCleared != 1 {
            errors.append("one cleared day should add quota and one day")
        }
        progress.noteQuestCompleted(questId: "q1", quota: 3, dayKey: today, dayFullyCleared: true)
        if progress.daysCleared != 1 {
            errors.append("the same day should not clear twice")
        }
        if progress.markCompletedIfNeeded(today: today) {
            errors.append("3 of 42 units should not complete the Target")
        }
        progress.unitsDone = 42
        if !progress.markCompletedIfNeeded(today: today) || progress.status != .completed {
            errors.append("meeting the unit goal should complete the Target")
        }
        return errors
    }
}
