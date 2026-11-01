import Foundation

/// On-device check for a generated bundle. The fallback catalog does not pass through here.
enum QuestSafety {
    static let yellowRunLimitSec = 90.0 * 60
    static let calorieFloor = 1500.0
    /// Six split lifts, two 10Ks, and one optional quest.
    static let maxQuests = 9

    private static let unsafePhrases = ["starve", "all-nighter", "all nighter", "ignore injury", "max debt"]

    static func issues(in bundle: QuestBundle, context: MorningContext) -> [String] {
        var issues: [String] = []
        if bundle.schemaVersion != 1 {
            issues.append("schemaVersion must be 1")
        }
        if bundle.dayKey != context.player.localDate {
            issues.append("dayKey does not match the local quest day")
        }
        if bundle.mode != context.modeDecision.selectedMode {
            issues.append("locked mode \(context.modeDecision.selectedMode.rawValue) overridden by \(bundle.mode.rawValue)")
        }
        if bundle.narrative.count > 280 {
            issues.append("narrative is too long")
        }
        if bundle.headerLine.count > 80 {
            issues.append("headerLine is too long")
        }
        if let threat = bundle.threat, threat.count > PenaltyDecay.threatMaxCharacters {
            issues.append("threat is too long")
        }

        let requiredCap = context.constraints.maxRequiredQuests
        let optionalCap = context.constraints.maxOptionalQuests
        let required = bundle.quests.filter { $0.kind != .optional }.count
        let optional = bundle.quests.filter { $0.kind == .optional }.count
        if bundle.quests.isEmpty {
            issues.append("bundle has no quests")
        }
        if bundle.quests.count > maxQuests {
            issues.append("too many quests")
        }
        if required > requiredCap {
            issues.append("too many required quests")
        }
        if optional > optionalCap {
            issues.append("too many optional quests")
        }

        var seen: Set<String> = []
        for quest in bundle.quests {
            if quest.id.count < 8 || quest.id.count > 64 {
                issues.append("quest id length")
            }
            if !seen.insert(quest.id).inserted {
                issues.append("duplicate quest id")
            }
            if quest.kind == .penalty || quest.difficulty == .penalty {
                // Only the app adds penalty rows, from the tier.
                issues.append("generated penalty quest")
            }
            let title = quest.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count < 3 || title.count > 48 {
                issues.append("quest title length")
            }
            if !quest.progress.target.isFinite || quest.progress.target <= 0 {
                issues.append("progress target must be positive")
            }
            if quest.progress.current < 0 {
                issues.append("progress current cannot be negative")
            }
            issues.append(contentsOf: bounds(for: quest, band: context.modeDecision.trainingBand))
        }

        let haystack = (
            [bundle.narrative, bundle.headerLine, bundle.threat ?? ""] + bundle.warnings + bundle.quests.map(\.title) + stringParams(in: bundle)
        ).joined(separator: "\n").lowercased()
        if unsafePhrases.contains(where: { haystack.contains($0) }) {
            issues.append("unsafe phrasing")
        }
        if let calories = firstCalorieMention(in: haystack), calories < calorieFloor {
            issues.append("calorie suggestion below the floor")
        }
        return issues
    }

    /// Drops completion, evidence, and grants. Forces the rules-locked mode onto every row.
    static func accepting(_ bundle: QuestBundle, context: MorningContext, assignedAt: Date) -> QuestBundle? {
        guard issues(in: bundle, context: context).isEmpty else { return nil }
        var copy = bundle.strippingModelCompletion(assignedAt: assignedAt)
        copy.mode = context.modeDecision.selectedMode
        if copy.headerLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.headerLine = copy.mode.headerLine
        }
        copy.quests = copy.quests.map { quest in
            var quest = quest
            quest.mode = copy.mode
            return quest
        }
        if copy.generatedBy.isEmpty {
            copy.generatedBy = "llm"
        }
        return copy
    }

    private static func bounds(for quest: Quest, band: ReadinessBand) -> [String] {
        var issues: [String] = []
        if band == .yellow, isRun(quest), let seconds = durationSec(quest), seconds > yellowRunLimitSec {
            issues.append("run longer than 90 minutes on yellow readiness")
        }
        for key in ["minKcal", "calorieTarget", "calories", "maxKcal", "calorieFloor"] {
            if let value = quest.verification.params[key]?.doubleValue, value < calorieFloor {
                issues.append("calorie suggestion below the floor")
            }
        }
        if quest.progress.unit == "kcal", quest.progress.target < calorieFloor {
            issues.append("calorie suggestion below the floor")
        }
        return issues
    }

    private static func isRun(_ quest: Quest) -> Bool {
        if case .array(let values) = quest.verification.params["types"] {
            let names = values.compactMap(\.stringValue).map { $0.lowercased() }
            if names.contains("run") { return true }
            if !names.isEmpty { return false }
        }
        let title = quest.title.lowercased()
        if title.contains("walk"), !title.contains("run") { return false }
        return title.contains("run")
    }

    private static func durationSec(_ quest: Quest) -> Double? {
        if let seconds = quest.verification.params["minMovingTimeSec"]?.doubleValue { return seconds }
        if let seconds = quest.verification.params["minDurationSec"]?.doubleValue { return seconds }
        if let seconds = quest.verification.params["minSec"]?.doubleValue, isRun(quest) { return seconds }
        if quest.progress.unit == "min" { return quest.progress.target * 60 }
        if quest.progress.unit == "sec" { return quest.progress.target }
        return nil
    }

    private static func stringParams(in bundle: QuestBundle) -> [String] {
        bundle.quests.flatMap { quest in
            quest.verification.params.values.compactMap(\.stringValue)
        }
    }

    private static func firstCalorieMention(in haystack: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{3,4})\s*(kcal|calories)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: haystack) else {
            return nil
        }
        return Double(haystack[valueRange])
    }
}
