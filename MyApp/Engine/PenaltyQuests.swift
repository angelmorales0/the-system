import Foundation

/// An open penalty (`player.penaltyOpen`) adds red `kind: .penalty` rows to the top of the normal day.
/// It does not change the day mode. A Full Recovery day adds none; the penalty waits for the next day.
/// While a row is open, every app is locked (see `PenaltyEnforcement`), so a run in Strava or Apple Health clears it.
/// The rows are always the same: a flat 10K. Another missed day or month while it is open changes nothing.
enum PenaltyQuests {

    /// Adds the rows once, above the day's quests. Open penalty rows keep their progress.
    /// A penalty that opens after the day's penalty run is a new debt (a missed month, judged later that day):
    /// the finished row does not serve it, so it gets its own open row, with its own id.
    static func ensure(in bundle: QuestBundle, open: Bool, band: ReadinessBand, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        guard open, bundle.mode != .fullRecovery, !bundle.quests.isEmpty,
              !bundle.quests.contains(where: { $0.kind == .penalty && $0.status != .completed }) else { return bundle }
        var copy = bundle
        var rows: [Quest] = []
        for template in catalog.penaltyTemplates(band: band) {
            var row = quest(from: template, bundle: bundle, now: now)
            var number = 2
            let base = row.id
            while (copy.quests + rows).contains(where: { $0.id == row.id }) {
                row.id = "\(base)_\(number)"
                number += 1
            }
            rows.append(row)
        }
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
