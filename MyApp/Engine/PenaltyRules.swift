import Foundation

enum PenaltyRules {
    static func check() -> [String] {
        var errors: [String] = []
        guard let catalog = try? FallbackCatalog(data: Data(catalogJSON.utf8)),
              let dayOne = QuestDay.date(from: "2026-10-01"),
              let dayTwo = QuestDay.date(from: "2026-10-02"),
              let dayThree = QuestDay.date(from: "2026-10-03"),
              let dayFour = QuestDay.date(from: "2026-10-04"),
              let dayFive = QuestDay.date(from: "2026-10-05") else {
            return ["penalty catalog failed to parse"]
        }

        var missed = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        missed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if missed.player.penaltyTier != 1 || missed.bundle.mode != .penalty {
            errors.append("a missed required day should open penalty tier 1, got tier \(missed.player.penaltyTier) \(missed.bundle.mode.rawValue)")
        }
        if missed.bundle.headerLine != "Penalty Quest" {
            errors.append("penalty morning should use the fallback header")
        }
        missed.refreshIfNeeded(catalog: catalog, now: dayThree)
        missed.refreshIfNeeded(catalog: catalog, now: dayFour)
        missed.refreshIfNeeded(catalog: catalog, now: dayFive)
        if missed.player.penaltyTier != 3 {
            errors.append("penalty tier should cap at 3, got \(missed.player.penaltyTier)")
        }

        var rested = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        rested.signals.spendingFullRecovery = true
        rested.fullRecoveryDayKey = rested.bundle.dayKey
        rested.rebuildForTest(catalog: catalog, now: dayOne)
        if rested.bundle.mode != .fullRecovery {
            errors.append("spending a token should assign full recovery")
        }
        rested.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if rested.player.penaltyTier != 0 {
            errors.append("a Full Recovery day must not open a penalty, got tier \(rested.player.penaltyTier)")
        }

        var banked = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        banked.player.fullRecoveryBank = 1
        let assigned = banked.spendFullRecovery(catalog: catalog, now: dayOne)
        if banked.player.fullRecoveryBank != 0 || banked.bundle.mode != .fullRecovery || !assigned.contains("assigned") {
            errors.append("spend should assign today when nothing is completed, got \(assigned)")
        }
        banked.player.fullRecoveryBank = 1
        if !banked.spendFullRecovery(catalog: catalog, now: dayOne).contains("already") {
            errors.append("a second spend the same day should be refused")
        }
        if banked.player.fullRecoveryBank != 1 {
            errors.append("a refused second spend should keep the token")
        }

        var queued = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        queued.player.fullRecoveryBank = 1
        _ = queued.apply(.completed(evidence: evidence("done")), questId: queued.bundle.quests[0].id, now: dayOne)
        let later = queued.spendFullRecovery(catalog: catalog, now: dayOne)
        if queued.bundle.mode == .fullRecovery || !later.contains("tomorrow") {
            errors.append("a day in progress should queue Full Recovery")
        }
        queued.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if queued.bundle.mode != .fullRecovery {
            errors.append("the queued token should assign Full Recovery the next morning")
        }

        var cleared = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        cleared.player.penaltyTier = 1
        cleared.rebuildForTest(catalog: catalog, now: dayOne)
        let beforeXP = cleared.player.xp
        let quest = cleared.bundle.quests[0]
        _ = cleared.apply(.completed(evidence: evidence("pen")), questId: quest.id, now: dayOne)
        if cleared.player.penaltyTier != 0 {
            errors.append("finishing every penalty quest should drop the tier")
        }
        let taxed = GameSnapshot.xpGrant(for: quest, mode: .penalty)
        if taxed != 27 || cleared.bundle.quests[0].grantedXP != taxed {
            errors.append("penalty XP should be 0.9× once, got grant \(taxed) stored \(cleared.bundle.quests[0].grantedXP)")
        }
        if cleared.player.xp != beforeXP + taxed {
            errors.append("the 0.9× tax should be applied once")
        }
        if GameSnapshot.xpGrant(for: quest, mode: .penalty) != taxed {
            errors.append("asking for the grant again should not compound the tax")
        }
        cleared.undoQuest(id: quest.id)
        if cleared.player.penaltyTier != 1 {
            errors.append("undoing a penalty clear should restore the tier")
        }

        var optionalOnly = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        optionalOnly.bundle.quests[0].kind = .optional
        optionalOnly.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if optionalOnly.player.penaltyTier != 0 {
            errors.append("an optional miss should not open a penalty")
        }
        return errors
    }

    private static func evidence(_ id: String) -> Evidence {
        Evidence.make(source: "manual_confirm", externalId: id, payload: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static let catalogJSON = """
    {"schemaVersion":1,"entries":[
      {"mode":"performance_training","readinessBands":["green","yellow","red"],"headerLine":"Performance Training","narrative":"Train.","warnings":[],"quests":[
        {"id":"run","title":"Run","kind":"daily","stat":"END","verification":{"method":"manual_confirm","params":{}},"xp":30,"difficulty":"normal","targetId":null,"progress":{"current":0,"target":1,"unit":"session"},"reward":null}
      ]},
      {"mode":"penalty","readinessBands":["green","yellow","red"],"headerLine":"Penalty Quest","narrative":"Clear it.","warnings":[],"quests":[
        {"id":"pen","title":"Penalty Run","kind":"penalty","stat":"END","verification":{"method":"manual_confirm","params":{}},"xp":30,"difficulty":"penalty","targetId":null,"progress":{"current":0,"target":1,"unit":"session"},"reward":null}
      ]},
      {"mode":"full_recovery","readinessBands":["green","yellow","red"],"headerLine":"Full Recovery Day","narrative":"Rest.","warnings":[],"quests":[
        {"id":"rest","title":"Rest","kind":"daily","stat":"REC","verification":{"method":"manual_confirm","params":{}},"xp":10,"difficulty":"easy","targetId":null,"progress":{"current":0,"target":1,"unit":"session"},"reward":null}
      ]}
    ]}
    """
}

extension GameSnapshot {
    /// Test hook. Production rebuilds stay inside the day refresh.
    mutating func rebuildForTest(catalog: FallbackCatalog, now: Date) {
        rebuildBundle(catalog: catalog, now: now)
    }
}
