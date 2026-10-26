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
        if missed.player.penaltyTier != 1 || missed.bundle.mode != .performanceTraining {
            errors.append("a missed required day should open penalty tier 1 on a Training day, got tier \(missed.player.penaltyTier) \(missed.bundle.mode.rawValue)")
        }
        if missed.bundle.headerLine != "Performance Training" {
            errors.append("an open penalty must keep the day's own header")
        }
        let ids = missed.bundle.quests.map(\.id)
        if ids != ["q_2026-10-02_run", DailyStretch.questId, "q_2026-10-02_pen"] {
            errors.append("penalty rows should follow the day's quests and Stretching, got \(ids)")
        }
        if PenaltyQuests.rows(in: missed.bundle).first?.progress.target != 30 {
            errors.append("tier 1 should keep the base penalty time")
        }
        missed.refreshIfNeeded(catalog: catalog, now: dayThree)
        missed.refreshIfNeeded(catalog: catalog, now: dayFour)
        missed.refreshIfNeeded(catalog: catalog, now: dayFive)
        if missed.player.penaltyTier != 3 {
            errors.append("penalty tier should cap at 3, got \(missed.player.penaltyTier)")
        }
        let tierThree = PenaltyQuests.rows(in: missed.bundle)
        if tierThree.count != 1 || tierThree.first?.progress.target != 50
            || tierThree.first?.verification.params["minMovingTimeSec"]?.doubleValue != 3000 {
            errors.append("tier 3 should add 20 minutes to each penalty row, got \(tierThree.map(\.progress.target))")
        }

        var emergency = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        for quest in emergency.bundle.quests {
            _ = emergency.apply(.completed(evidence: evidence("done \(quest.id)")), questId: quest.id, now: dayOne)
        }
        if emergency.missesRequiredSet {
            errors.append("a fully completed day should not miss its required set")
        }
        emergency.emergencyFailedDayKey = emergency.bundle.dayKey
        emergency.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if emergency.player.penaltyTier != 1 {
            errors.append("a failed emergency quest should open penalty tier 1, got \(emergency.player.penaltyTier)")
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

        var restWithPenalty = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        restWithPenalty.player.penaltyTier = 2
        restWithPenalty.signals.spendingFullRecovery = true
        restWithPenalty.fullRecoveryDayKey = restWithPenalty.bundle.dayKey
        restWithPenalty.rebuildForTest(catalog: catalog, now: dayOne)
        if restWithPenalty.bundle.mode != .fullRecovery || !PenaltyQuests.rows(in: restWithPenalty.bundle).isEmpty {
            errors.append("a Full Recovery day must not add penalty rows")
        }
        restWithPenalty.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if restWithPenalty.player.penaltyTier != 2 || PenaltyQuests.rows(in: restWithPenalty.bundle).isEmpty {
            errors.append("the tier should wait through Full Recovery and return the next day")
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
        guard let quest = PenaltyQuests.rows(in: cleared.bundle).first,
              let penaltyIndex = cleared.bundle.quests.firstIndex(where: { $0.id == quest.id }) else {
            return errors + ["tier 1 should add a penalty row"]
        }
        _ = cleared.apply(.completed(evidence: evidence("pen")), questId: quest.id, now: dayOne)
        if cleared.player.penaltyTier != 0 {
            errors.append("finishing every penalty row should drop the tier, even with the day's quests open")
        }
        let taxed = GameSnapshot.xpGrant(for: quest)
        if taxed != 27 || cleared.bundle.quests[penaltyIndex].grantedXP != taxed {
            errors.append("penalty XP should be 0.9× once, got grant \(taxed) stored \(cleared.bundle.quests[penaltyIndex].grantedXP)")
        }
        if cleared.player.xp != beforeXP + taxed {
            errors.append("the 0.9× tax should be applied once")
        }
        if GameSnapshot.xpGrant(for: quest) != taxed {
            errors.append("asking for the grant again should not compound the tax")
        }
        let normal = cleared.bundle.quests[0]
        if normal.kind == .penalty || GameSnapshot.xpGrant(for: normal) != normal.xp {
            errors.append("a normal row on a penalty day should keep full XP")
        }
        cleared.undoQuest(id: quest.id)
        if cleared.player.penaltyTier != 1 {
            errors.append("undoing a penalty clear should restore the tier")
        }

        var optionalOnly = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        // Every row, including the fixed Stretching row, so the day has nothing required.
        for index in optionalOnly.bundle.quests.indices {
            optionalOnly.bundle.quests[index].kind = .optional
        }
        optionalOnly.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if optionalOnly.player.penaltyTier != 0 {
            errors.append("an optional miss should not open a penalty")
        }
        var capped = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        let run = capped.bundle.quests[0]
        capped.player.stats[run.stat] = StatValues.maximum - 1
        _ = capped.apply(.completed(evidence: evidence("cap")), questId: run.id, now: dayOne)
        if capped.player.stats[run.stat] != StatValues.maximum {
            errors.append("a quest must not raise a stat above \(StatValues.maximum), got \(capped.player.stats[run.stat])")
        }
        capped.undoQuest(id: run.id)
        if capped.player.stats[run.stat] != StatValues.maximum - 1 {
            errors.append("undo should remove only the capped grant, got \(capped.player.stats[run.stat])")
        }
        if StatValues.starter.capped() != StatValues.starter {
            errors.append("starter stats must be at or under the cap")
        }

        return errors
    }

    private static func evidence(_ id: String) -> Evidence {
        Evidence.make(source: "manual_confirm", externalId: id, payload: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static let catalogJSON = """
    {"schemaVersion":1,"entries":[
      {"mode":"performance_training","readinessBands":["green","yellow","red"],"headerLine":"Performance Training","narrative":"Train.","warnings":[],"quests":[
        {"id":"run","title":"Run","kind":"daily","stat":"END","verification":{"method":"manual_confirm","params":{}},"xp":30,"difficulty":"normal","progress":{"current":0,"target":1,"unit":"session"},"reward":null}
      ]},
      {"mode":"full_recovery","readinessBands":["green","yellow","red"],"headerLine":"Full Recovery Day","narrative":"Rest.","warnings":[],"quests":[
        {"id":"rest","title":"Rest","kind":"daily","stat":"REC","verification":{"method":"manual_confirm","params":{}},"xp":10,"difficulty":"easy","progress":{"current":0,"target":1,"unit":"session"},"reward":null}
      ]}
    ],"penaltyQuests":[
      {"readinessBands":["green","yellow","red"],"quests":[
        {"id":"pen","title":"Penalty Run","kind":"penalty","stat":"END","verification":{"method":"strava_activity","params":{"types":["Run"],"minMovingTimeSec":1800}},"xp":30,"difficulty":"penalty","progress":{"current":0,"target":30,"unit":"min"},"reward":null}
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
