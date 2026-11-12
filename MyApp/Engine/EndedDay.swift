import Foundation

/// A quest day that ended with a required quest open, kept as it ended.
/// The app judges a day from what it saw while it was open. A run or a gym session that finished after the app
/// was last open is not in that picture, so the day would be a miss with the work done.
/// The next refresh reads that day's own Strava, Hevy, WHOOP, and Apple Health data once more and settles it:
/// rows complete from their real evidence, the day's record is corrected, a penalty that only this day opened
/// is lifted, and a day that turns out perfect is paid. Work done after the day ended never counts for it.
struct EndedDay: Codable, Equatable {
    var bundle: QuestBundle
    /// The open penalty has a cause other than this day's miss: it was open before, or a missed month opened it.
    var owesOtherPenalty: Bool
    /// Reads so far. A service can be down, so the day is read again, at most `maxReads` times.
    var reads = 0

    static let maxReads = 3
}

/// What a late settle changed, for the store.
struct LateSettle: Equatable {
    var liftedPenalty = false
    var rebuiltToday = false
    var gold = 0
}

extension QuestBundle {
    /// Required rows still open. A Screen Time row under its cap holds until the day ends, so only a failed one is open.
    var openRequired: [Quest] {
        quests.filter { $0.kind != .optional && $0.status != .completed && !($0.id == ScreenTime.questId && $0.status == .pending) }
    }
}

extension GameSnapshot {
    /// Keeps the day that is ending when it misses its required set. Runs in `refreshIfNeeded`, before the penalty opens.
    mutating func keepEndedDay() {
        endedDay = missesRequiredSet ? EndedDay(bundle: bundle, owesOtherPenalty: player.penaltyOpen) : nil
    }

    /// Settles the ended day against its own data, `integrations`. Returns what changed.
    @discardableResult
    mutating func settleEndedDay(integrations: DayIntegrationSnapshot, catalog: FallbackCatalog, now: Date) -> LateSettle {
        guard var ended = endedDay else { return LateSettle() }
        let dayKey = ended.bundle.dayKey
        guard dayKey < bundle.dayKey else {
            endedDay = nil
            return LateSettle()
        }

        // The same verifier pass the store runs, on a copy that holds the ended day.
        var past = self
        past.bundle = ended.bundle
        let hadOpenPenaltyRow = PenaltyQuests.rows(in: past.bundle).contains { $0.status != .completed }
        for quest in ended.bundle.quests where quest.status != .completed {
            switch quest.verification.method {
            case .manualConfirm, .timerSession, .screenTimeLimit:
                continue
            default:
                break
            }
            let context = past.verificationContext(for: quest, now: now, timerElapsed: nil, userConfirmed: false, integrations: integrations)
            let result = VerifierRegistry.verifier(for: quest.verification.method).evaluate(quest: quest, context: context)
            switch result {
            case .progress, .completed:
                _ = past.apply(result, questId: quest.id, now: now)
            case .unchanged, .incomplete, .failed:
                break
            }
        }
        if let day = past.bundle.quests.first(where: { $0.id == DailyStretch.questId }).flatMap({ StretchSplit.day(of: $0) }) {
            let inHevy = Set(day.stretches.filter { StretchSplit.setsDone($0, workouts: integrations.hevy.workouts) >= $0.sets }.map(\.name))
            if let result = past.stretchCompletion(doneInHevy: inHevy, now: now) {
                _ = past.apply(result, questId: DailyStretch.questId, now: now)
            }
        }

        var settle = LateSettle()
        let stillMissed = !past.bundle.openRequired.isEmpty
        if past.bundle != ended.bundle {
            let splitBefore = GymSplit.today(history: questHistory, dayKey: bundle.dayKey).id
            let stretchBefore = StretchSplit.today(history: questHistory, dayKey: bundle.dayKey).id
            evidenceLog = past.evidenceLog
            if let index = questHistory.firstIndex(where: { $0.dayKey == dayKey }) {
                questHistory[index].quests = Self.questRecords(of: past.bundle)
                questHistory[index].missedRequired = stillMissed
            }
            // The penalty run of that day was done late: the older penalty is served.
            if hadOpenPenaltyRow, PenaltyQuests.isCleared(in: past.bundle) { ended.owesOtherPenalty = false }
            if !stillMissed {
                if !ended.owesOtherPenalty, player.penaltyOpen {
                    player.penaltyOpen = false
                    bundle.quests.removeAll { $0.kind == .penalty && $0.status != .completed }
                    settle.liftedPenalty = true
                }
                let required = past.bundle.quests.filter { $0.kind != .optional }
                let perfect = !required.isEmpty && required.allSatisfy { $0.status == .completed && !$0.skippedWithPotion }
                    && !potionLog.contains { $0.dayKey == dayKey }
                if perfect {
                    settle.gold = Gold.reward(for: dayKey)
                    gold += settle.gold
                    lastGoldReward = GoldReward(dayKey: dayKey, amount: settle.gold)
                }
            }
            // Lifts or stretches done late move their rotation. A day with nothing done yet is planned again from it.
            let moved = GymSplit.today(history: questHistory, dayKey: bundle.dayKey).id != splitBefore
                || StretchSplit.today(history: questHistory, dayKey: bundle.dayKey).id != stretchBefore
            let quiet = runningTimers.isEmpty && !bundle.quests.contains { $0.status == .completed }
            if moved, quiet, bundle.dayKey == QuestDay.key(for: now) {
                generatedBundle = nil
                generationAttemptDayKey = nil
                rebuildBundle(catalog: catalog, now: now)
                settle.rebuiltToday = true
            }
        }

        ended.bundle = past.bundle
        ended.reads += 1
        // A service that is set but did not answer may still hold the missing work.
        let everySourceRead = (!integrations.strava.configured || integrations.strava.available)
            && (!integrations.hevy.configured || integrations.hevy.available)
            && (!integrations.whoop.configured || integrations.whoop.available)
        endedDay = stillMissed && !everySourceRead && ended.reads < EndedDay.maxReads ? ended : nil
        return settle
    }
}

enum EndedDayRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let dayOne = QuestDay.start(of: "2026-10-05")?.addingTimeInterval(3_600) else { return ["could not build ended day dates"] }
        let dayTwo = dayOne.addingTimeInterval(86_400)
        let keyOne = QuestDay.key(for: dayOne)

        func finish(_ snapshot: inout GameSnapshot, where include: (Quest) -> Bool) {
            for quest in snapshot.bundle.quests where quest.kind != .optional && quest.status != .completed && include(quest) {
                let evidence = Evidence.make(source: "ended_check", externalId: "ended:\(quest.id)", payload: quest.id, timestamp: dayOne)
                snapshot.apply(.completed(evidence: evidence), questId: quest.id, now: dayOne)
            }
        }
        func isLift(_ quest: Quest) -> Bool { TrainingDay.isStrength(quest) && quest.id != DailyStretch.questId }
        let run = WorkoutEvent(source: "strava", externalId: "late-run", sport: "Run", start: dayOne.addingTimeInterval(50_000),
                               end: dayOne.addingTimeInterval(53_300), movingTimeSec: 3_300, distanceMeters: 10_020)
        func data(strava: [WorkoutEvent] = [], hevy: [HevyWorkout] = [], stravaUp: Bool = true) -> DayIntegrationSnapshot {
            DayIntegrationSnapshot.make(
                whoop: .disconnected(dayKey: keyOne, reason: ""),
                strava: StravaDayReading(available: stravaUp, configured: true, reason: "", dayKey: keyOne, activities: strava),
                health: .unavailable,
                hevy: HevyDayReading(available: true, configured: true, reason: "", dayKey: keyOne, workouts: hevy)
            )
        }

        // Everything done but the run, which was finished after the app was last open.
        var late = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        late.applyScreenTime(phoneMinutes: 30, workMinutes: nil)
        finish(&late) { !TrainingDay.isRaceRun($0) && $0.id != ScreenTime.questId }
        late.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if !late.player.penaltyOpen || late.endedDay?.bundle.dayKey != keyOne || late.questHistory.first?.missedRequired != true {
            errors.append("a day that ends with the run open should open a penalty and be kept for one more read")
        }
        let settled = late.settleEndedDay(integrations: data(strava: [run]), catalog: catalog, now: dayTwo)
        if !settled.liftedPenalty || late.player.penaltyOpen || !PenaltyQuests.rows(in: late.bundle).isEmpty || late.endedDay != nil
            || late.questHistory.first?.missedRequired != false || settled.gold != Gold.reward(for: keyOne) || late.gold != settled.gold {
            errors.append("a run found in the ended day's own data should lift its penalty, fix its record, and pay the day, got \(settled)")
        }
        if late.settleEndedDay(integrations: data(strava: [run]), catalog: catalog, now: dayTwo) != LateSettle() || late.gold != settled.gold {
            errors.append("an ended day should settle once")
        }

        // Nothing new in the data: the penalty stays, and the day is not read again.
        var missed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        missed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if missed.settleEndedDay(integrations: data(), catalog: catalog, now: dayTwo) != LateSettle() || !missed.player.penaltyOpen || missed.endedDay != nil {
            errors.append("an ended day with no late work should keep its penalty")
        }

        // A service that did not answer: the day waits, at most `maxReads` reads.
        var down = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        down.refreshIfNeeded(catalog: catalog, now: dayTwo)
        _ = down.settleEndedDay(integrations: data(stravaUp: false), catalog: catalog, now: dayTwo)
        if down.endedDay?.reads != 1 { errors.append("an ended day should wait for a service that did not answer") }
        for _ in 1..<EndedDay.maxReads { _ = down.settleEndedDay(integrations: data(stravaUp: false), catalog: catalog, now: dayTwo) }
        if down.endedDay != nil { errors.append("an ended day should stop after \(EndedDay.maxReads) reads") }

        // An older penalty stays owed: late work on the day's own rows does not serve it.
        var owed = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        owed.player.penaltyOpen = true
        owed.rebuildBundle(catalog: catalog, now: dayOne)
        owed.applyScreenTime(phoneMinutes: 30, workMinutes: nil)
        finish(&owed) { $0.kind != .penalty && !TrainingDay.isRaceRun($0) && $0.id != ScreenTime.questId }
        owed.refreshIfNeeded(catalog: catalog, now: dayTwo)
        // One late run cannot clear both the penalty 10K and the day's 10K.
        let owedSettle = owed.settleEndedDay(integrations: data(strava: [run]), catalog: catalog, now: dayTwo)
        if owedSettle.liftedPenalty || !owed.player.penaltyOpen || PenaltyQuests.rows(in: owed.bundle).isEmpty {
            errors.append("a late run should not lift a penalty that was open before the day")
        }

        // Lifts done late move the split: a day with nothing done yet is planned again from the next split day.
        var lifted = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        let sets = Array(repeating: HevySet(type: "normal", reps: 10, weightKg: 40, rpe: nil, durationSec: nil), count: 4)
        let gym = HevyWorkout(id: "late-gym", title: "Bench Day", start: dayOne.addingTimeInterval(40_000), end: dayOne.addingTimeInterval(44_000),
                              exercises: lifted.bundle.quests.filter(isLift).compactMap { $0.verification.params["exercise"]?.stringValue }
                                .map { HevyExercise(title: $0, templateId: nil, sets: sets) })
        lifted.refreshIfNeeded(catalog: catalog, now: dayTwo)
        let again = lifted.bundle.headerLine
        let liftedSettle = lifted.settleEndedDay(integrations: data(hevy: [gym]), catalog: catalog, now: dayTwo)
        if again != "Bench Day" || !liftedSettle.rebuiltToday || liftedSettle.liftedPenalty || lifted.bundle.headerLine != "Squat Day"
            || !lifted.player.penaltyOpen || PenaltyQuests.rows(in: lifted.bundle).isEmpty {
            errors.append("lifts found late should move today to Squat Day and keep the penalty for the open run, got \(lifted.bundle.headerLine)")
        }

        // A save keeps the ended day, and a save from before this field loads without one.
        if let data = try? late.encoded(), (try? GameSnapshot.decoded(data)) != late { errors.append("a save should keep the snapshot") }
        var waiting = down
        waiting.endedDay = EndedDay(bundle: down.bundle, owesOtherPenalty: false)
        if let data = try? waiting.encoded(), (try? GameSnapshot.decoded(data))?.endedDay != waiting.endedDay { errors.append("a save should keep the ended day") }
        return errors
    }
}
