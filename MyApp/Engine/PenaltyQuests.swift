import Foundation

/// A penalty is a quest type, not a day mode. A missed day adds the catalog's penalty quests
/// to the top of the next day's own quests. The phone stays locked until every penalty quest is done.
enum PenaltyQuests {
    static let idPrefix = "penalty_"

    /// Adds the penalty quests for `band` once. A bundle that already holds penalty quests keeps them and their progress.
    static func adding(to bundle: QuestBundle, catalog: FallbackCatalog, band: ReadinessBand, now: Date) -> QuestBundle {
        guard !bundle.quests.contains(where: { $0.kind == .penalty }) else { return bundle }
        let source = catalog.makeBundle(mode: .penalty, band: band, dayKey: bundle.dayKey, now: now)
        let penalties = source.quests.map { template -> Quest in
            var quest = template
            // Penalty and day quests can share a catalog id such as `mobility`.
            let marker = "q_\(bundle.dayKey)_"
            let slug = quest.id.hasPrefix(marker) ? String(quest.id.dropFirst(marker.count)) : quest.id
            quest.id = marker + (slug.hasPrefix(idPrefix) ? slug : idPrefix + slug)
            quest.kind = .penalty
            quest.difficulty = .penalty
            quest.mode = bundle.mode
            return quest
        }
        var copy = bundle
        copy.quests = penalties + bundle.quests
        return copy
    }
}
