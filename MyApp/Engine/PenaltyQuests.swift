import Foundation

/// An open penalty (`penaltyTier` 1...3) adds red `kind: .penalty` rows to the top of the normal day.
/// It does not change the day mode. A Full Recovery day adds none; the tier waits for the next day.
/// While a row is open, every app is locked (see `PenaltyEnforcement`), so rows verify from Apple Health only.
/// The rows are the same at every tier: a flat 10K. The tier counts missed days in a row.
enum PenaltyQuests {

    /// Adds the rows once, above the day's quests. Existing penalty rows keep their progress.
    static func ensure(in bundle: QuestBundle, tier: Int, band: ReadinessBand, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        guard tier > 0, bundle.mode != .fullRecovery, !bundle.quests.isEmpty,
              !bundle.quests.contains(where: { $0.kind == .penalty }) else { return bundle }
        let rows = catalog.penaltyTemplates(band: band).map { quest(from: $0, bundle: bundle, now: now) }
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

    private static func quest(from template: QuestTemplate, bundle: QuestBundle, now: Date) -> Quest {
        Quest(
            id: "q_\(bundle.dayKey)_\(template.id)",
            title: template.title,
            kind: .penalty,
            stat: template.stat,
            verification: template.verification,
            deadline: QuestDay.endOfDay(now),
            xp: template.xp,
            difficulty: .penalty,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: template.progress.target, unit: template.progress.unit),
            reward: nil,
            status: .pending,
            evidence: [],
            assignedAt: now
        )
    }
}
