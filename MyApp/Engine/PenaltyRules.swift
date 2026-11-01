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
        if ids != ["q_2026-10-02_pen", "q_2026-10-02_run", ScreenTime.questId, DailyStretch.questId] {
            errors.append("penalty rows should come above the day's quests, Screen Time, and Stretching, got \(ids)")
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
        if tierThree.count != 1 || tierThree.first?.progress.target != 30
            || tierThree.first?.verification.params["minMovingTimeSec"]?.doubleValue != 1800 {
            errors.append("tier 3 should keep the same penalty rows as tier 1, got \(tierThree.map(\.progress.target))")
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

        // From the penalty screen: one token clears the penalty and keeps the day as it is.
        var paid = GameSnapshot.fresh(catalog: catalog, now: dayOne, signals: .placeholder)
        paid.player.penaltyTier = 2
        paid.rebuildForTest(catalog: catalog, now: dayOne)
        paid.player.fullRecoveryBank = 0
        if !paid.clearPenaltyWithFullRecovery().contains("No Full Recovery") || paid.player.penaltyTier != 2 {
            errors.append("clearing a penalty needs a token")
        }
        paid.player.fullRecoveryBank = 1
        _ = paid.clearPenaltyWithFullRecovery()
        if paid.player.penaltyTier != 0 || paid.player.fullRecoveryBank != 0 || !PenaltyQuests.rows(in: paid.bundle).isEmpty || paid.bundle.mode != .performanceTraining {
            errors.append("a token should clear the penalty and keep the day, got tier \(paid.player.penaltyTier) bank \(paid.player.fullRecoveryBank)")
        }
        if paid.clearPenaltyWithFullRecovery() != "No penalty is open." { errors.append("clearing twice should change nothing") }

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
        guard let quest = PenaltyQuests.rows(in: cleared.bundle).first else {
            return errors + ["tier 1 should add a penalty row"]
        }
        _ = cleared.apply(.completed(evidence: evidence("pen")), questId: quest.id, now: dayOne)
        if cleared.player.penaltyTier != 0 {
            errors.append("finishing every penalty row should drop the tier, even with the day's quests open")
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

        // The bundled penalty is one flat 10K at every tier and band.
        let bundled = FallbackCatalog.bundled()
        for band in ReadinessBand.allCases {
            var day = GameSnapshot.fresh(catalog: bundled, now: dayOne, signals: .placeholder)
            day.readiness = .sample(band, on: QuestDay.key(for: dayOne))
            day.player.penaltyTier = 3
            day.rebuildForTest(catalog: bundled, now: dayOne)
            let runs = PenaltyQuests.rows(in: day.bundle)
            if runs.count != 1 || runs.contains(where: { !TrainingDay.isRaceRun($0) || $0.progress.target != 10 || $0.progress.unit != "km"
                || $0.verification.params["minDistanceMeters"]?.doubleValue != TrainingDay.tenKMeters }) {
                errors.append("a \(band.rawValue) tier 3 penalty run should be a 10K, got \(runs.map { "\($0.title) \($0.verification.params)" })")
            }
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
