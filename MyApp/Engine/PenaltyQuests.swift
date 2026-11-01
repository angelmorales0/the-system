import Foundation

/// An open penalty (`player.penaltyOpen`) adds red `kind: .penalty` rows to the top of the normal day.
/// It does not change the day mode. A Full Recovery day adds none; the penalty waits for the next day.
/// While a row is open, every app is locked (see `PenaltyEnforcement`), so rows verify from Apple Health only.
/// The rows are always the same: a flat 10K. Another missed day while it is open changes nothing.
enum PenaltyQuests {

    /// Adds the rows once, above the day's quests. Existing penalty rows keep their progress.
    static func ensure(in bundle: QuestBundle, open: Bool, band: ReadinessBand, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        guard open, bundle.mode != .fullRecovery, !bundle.quests.isEmpty,
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
            difficulty: .penalty,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: template.progress.target, unit: template.progress.unit),
            status: .pending,
            evidence: [],
            assignedAt: now
        )
    }
}

extension GameSnapshot {
    /// Spends one banked Full Recovery token to end the open penalty: it closes and the penalty rows go.
    /// Today's own quests stay as they are, so the day is not a rest day.
    mutating func clearPenaltyWithFullRecovery() -> String {
        guard player.penaltyOpen else { return "No penalty is open." }
        guard player.fullRecoveryBank > 0 else { return "No Full Recovery token in the bank." }
        player.withdrawRecoveryToken()
        player.penaltyOpen = false
        bundle.quests.removeAll { $0.kind == .penalty }
        return "Full Recovery spent. The penalty is cleared. Today's quests stay."
    }
}
