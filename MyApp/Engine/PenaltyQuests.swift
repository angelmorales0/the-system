import Foundation

/// An open penalty (`penaltyTier` 1...3) adds red `kind: .penalty` rows to the top of the normal day.
/// It does not change the day mode. A Full Recovery day adds none; the tier waits for the next day.
/// While a row is open, every app is locked (see `PenaltyEnforcement`), so rows verify from Apple Health only.
enum PenaltyQuests {
    /// Each tier above 1 adds this much time to every timed penalty row: 30 / 40 / 50 min on green.
    static let extraSecondsPerTier = 600.0
    private static let durationKeys = ["minMovingTimeSec", "minDurationSec"]

    /// Adds the rows once, above the day's quests. Existing penalty rows keep their progress.
    static func ensure(in bundle: QuestBundle, tier: Int, band: ReadinessBand, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        guard tier > 0, bundle.mode != .fullRecovery, !bundle.quests.isEmpty,
              !bundle.quests.contains(where: { $0.kind == .penalty }) else { return bundle }
        let rows = catalog.penaltyTemplates(band: band).map { quest(from: $0, tier: tier, bundle: bundle, now: now) }
        var copy = bundle
        copy.quests.insert(contentsOf: rows, at: 0)
        return copy
    }

    static func rows(in bundle: QuestBundle) -> [Quest] {
        bundle.quests.filter { $0.kind == .penalty }
    }

    static func isCleared(in bundle: QuestBundle) -> Bool {
        let rows = rows(in: bundle)
        return !rows.isEmpty && rows.allSatisfy { $0.status == .completed }
    }

    private static func quest(from template: QuestTemplate, tier: Int, bundle: QuestBundle, now: Date) -> Quest {
        let extra = Double(min(3, max(1, tier)) - 1) * extraSecondsPerTier
        var verification = template.verification
        for key in durationKeys {
            if let seconds = verification.params[key]?.doubleValue {
                verification.params[key] = .number(seconds + extra)
            }
        }
        let target = template.progress.target + (template.progress.unit == "min" ? extra / 60 : 0)
        return Quest(
            id: "q_\(bundle.dayKey)_\(template.id)",
            title: template.title,
            kind: .penalty,
            stat: template.stat,
            verification: verification,
            deadline: QuestDay.endOfDay(now),
            xp: template.xp,
            difficulty: .penalty,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: target, unit: template.progress.unit),
            reward: nil,
            status: .pending,
            grantedXP: 0,
            grantedStatPoints: 0,
            grantedRecoveryToken: false,
            evidence: [],
            assignedAt: now
        )
    }
}
