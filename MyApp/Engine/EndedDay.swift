import Foundation

/// A quest day that ended with a required quest open, kept as it ended.
/// The app judges a day from what it saw while it was open. A run or a gym session that finished after the app
/// was last open is not in that picture, so the day would be a miss with the work done.
/// The next refresh reads that day's own Strava, Hevy, WHOOP, and Apple Health data once more and settles it:
/// rows complete from their real evidence, the day's record is corrected, a penalty that only this day opened
/// is lifted, and a day that turns out perfect is paid. Work done after the day ended never counts for it.
///
/// The Macs' screen minutes get the same last read. The phone's own count is read as the day ends, but the Macs
/// report to a Worker, and the app holds only what the Worker said at the last refresh. A day whose Screen Time row
/// passed on that old number is kept too: if the Macs' final minutes put the total over the limit, the row fails,
/// the day is a miss, its gold is taken back, and the penalty opens.
struct EndedDay: Codable, Equatable {
    var bundle: QuestBundle
    /// The open penalty has a cause other than this day's miss: it was open before the day ended.
    var owesOtherPenalty: Bool
    /// Reads so far. A service can be down, so the day is read again, at most `maxReads` times.
    var reads = 0
    /// The day counts as a miss now: it ended with a required quest open and no late read has completed it.
    /// False for a day kept only for the Macs' minutes, and after a late read found the day's work.
    var missed = true
    /// The day's screen minutes as it ended.
    var screenTime: ScreenTimeDay?
    /// Gold the day was paid as it ended.
    var paidGold = 0
    /// A penalty that is not the day's (a broken contract's penalty run) opened after this day ended. No late work on this day lifts it.
    /// The saved name stays for old saves.
    var monthPenalty = false

    static let maxReads = 3

    private enum CodingKeys: String, CodingKey {
        case bundle, owesOtherPenalty, reads, missed, screenTime, paidGold, monthPenalty
    }

    init(bundle: QuestBundle, owesOtherPenalty: Bool, reads: Int = 0, missed: Bool = true, screenTime: ScreenTimeDay? = nil, paidGold: Int = 0) {
        self.bundle = bundle
        self.owesOtherPenalty = owesOtherPenalty
        self.reads = reads
        self.missed = missed
        self.screenTime = screenTime
        self.paidGold = paidGold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundle = try container.decode(QuestBundle.self, forKey: .bundle)
        owesOtherPenalty = try container.decodeIfPresent(Bool.self, forKey: .owesOtherPenalty) ?? true
        reads = try container.decodeIfPresent(Int.self, forKey: .reads) ?? 0
        missed = try container.decodeIfPresent(Bool.self, forKey: .missed) ?? true
        screenTime = try container.decodeIfPresent(ScreenTimeDay.self, forKey: .screenTime)
        paidGold = try container.decodeIfPresent(Int.self, forKey: .paidGold) ?? 0
        monthPenalty = try container.decodeIfPresent(Bool.self, forKey: .monthPenalty) ?? false
    }
}

/// The Macs' minutes for the ended day, from a read made after it ended.
struct LateMacRead: Equatable {
    /// A Mac tracker is set up, so the day waits for its answer.
    var trackerSet = false
    /// The Worker answered. It can answer with no minutes for the day.
    var answered = false
    var workMinutes: Int?
    var overlapMinutes: Int?
}

/// What a late settle changed, for the store.
struct LateSettle: Equatable {
    var liftedPenalty = false
    /// A late result opened a penalty. The Screen Time row no longer does (2026-11-18).
    var openedPenalty = false
    var rebuiltToday = false
    /// The late result made the day perfect, and its bonus item was given.
    var perfectItem = false
}

extension QuestBundle {
    /// Required rows still open. The Screen Time row never counts: over the limit it turns red, but it opens no penalty.
    var openRequired: [Quest] {
        quests.filter { $0.kind != .optional && $0.status != .completed && $0.id != ScreenTime.questId }
    }
}

extension GameSnapshot {
    /// Keeps the day that is ending when it misses its required set, or when its Screen Time row passed and a Mac
    /// can still report minutes. Runs in `refreshIfNeeded`, before the penalty opens.
    mutating func keepEndedDay() {
        let missed = missesRequiredSet
        let rested = bundle.mode == .fullRecovery || signals.spendingFullRecovery || fullRecoveryDayKey == bundle.dayKey
        // A Screen Time row that passed, on a day a Mac counted or can count: the Macs' last minutes are not in yet.
        let macCounts = screenTimeToday.workMeasured || MacScreenSettings.load().baseURL != nil
        let screenPassed = !rested && macCounts
            && bundle.quests.contains { $0.id == ScreenTime.questId && $0.status == .completed && !$0.skippedWithPotion }
        guard missed || screenPassed else {
            endedDay = nil
            return
        }
        endedDay = EndedDay(bundle: bundle, owesOtherPenalty: player.penaltyOpen, missed: missed, screenTime: screenTimeToday,
                            paidGold: lastGoldReward?.dayKey == bundle.dayKey ? lastGoldReward?.amount ?? 0 : 0)
    }

    /// Settles the ended day against its own data, `integrations`, and the Macs' last minutes. Returns what changed.
    /// `healthRead` is false when Apple Health could not be read (a locked phone): its workouts may still be missing.
    @discardableResult
    mutating func settleEndedDay(integrations: DayIntegrationSnapshot, mac: LateMacRead = LateMacRead(), healthRead: Bool = true,
                                 catalog: FallbackCatalog, now: Date) -> LateSettle {
        guard var ended = endedDay else { return LateSettle() }
        let dayKey = ended.bundle.dayKey
        guard dayKey < bundle.dayKey else {
            endedDay = nil
            return LateSettle()
        }
        let asItEnded = ended.bundle
        var settle = LateSettle()

        // The Macs' last minutes first: a total over the limit fails the row, whatever else was done.
        if let workMinutes = mac.workMinutes, var day = ended.screenTime, let index = ended.bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId }) {
            day.workMinutes = max(day.workMinutes, workMinutes)
            day.workMeasured = true
            if let overlap = mac.overlapMinutes { day.overlapMinutes = overlap }
            ended.screenTime = day
            let row = ended.bundle.quests[index]
            if !row.skippedWithPotion, row.status != .failed {
                ended.bundle.quests[index].progress.current = Double(day.totalMinutes)
                if day.fails { ended.bundle.quests[index].status = .failed }
            }
            // A row that fails now only turns red in the record. It opens no penalty and takes no gold back.
        }

        // The same verifier pass the store runs, on a copy that holds the ended day.
        var past = self
        past.bundle = ended.bundle
        let hadOpenPenaltyRow = PenaltyQuests.rows(in: past.bundle).contains { $0.status != .completed }
        past.checkOpenRows(integrations: integrations, now: now, skipping: [.manualConfirm, .timerSession, .screenTimeLimit])
        if let day = past.bundle.quests.first(where: { $0.id == DailyStretch.questId }).flatMap({ StretchSplit.day(of: $0) }) {
            let inHevy = Set(day.stretches.filter { StretchSplit.setsDone($0, workouts: integrations.hevy.workouts) >= $0.sets }.map(\.name))
            if let result = past.stretchCompletion(doneInHevy: inHevy, now: now) {
                _ = past.apply(result, questId: DailyStretch.questId, now: now)
            }
        }

        progressLog = past.progressLog
        penaltyStarts = past.penaltyStarts
        let stillMissed = !past.bundle.openRequired.isEmpty
        if past.bundle != asItEnded {
            let splitBefore = GymSplit.today(history: questHistory, dayKey: bundle.dayKey).id
            let stretchBefore = StretchSplit.today(history: questHistory, dayKey: bundle.dayKey).id
            let runGoal = Double(TrainingDay.runKmPer7Days)
            let windowFullBefore = loggedRunKm(before: bundle.dayKey) >= runGoal
            evidenceLog = past.evidenceLog
            if let index = questHistory.firstIndex(where: { $0.dayKey == dayKey }) {
                questHistory[index].quests = Self.questRecords(of: past.bundle)
                questHistory[index].missedRequired = stillMissed
            }
            // The penalty run of that day was done late: the older penalty is served.
            if hadOpenPenaltyRow, PenaltyQuests.isCleared(in: past.bundle) { ended.owesOtherPenalty = false }
            if !stillMissed {
                if ended.missed, !ended.owesOtherPenalty, !ended.monthPenalty, player.penaltyOpen {
                    player.penaltyOpen = false
                    bundle.quests.removeAll { $0.kind == .penalty && $0.status != .completed }
                    settle.liftedPenalty = true
                }
                // The day is complete now. If the Macs' minutes arrive later and put it over the limit,
                // it fails like a day that was complete on time: gold back, penalty open.
                ended.missed = false
                let required = past.bundle.quests.filter { $0.kind != .optional && $0.id != ScreenTime.questId }
                let perfect = !required.isEmpty && required.allSatisfy { $0.status == .completed && !$0.skippedWithPotion }
                    && !potionLog.contains { $0.dayKey == dayKey }
                if perfect, grantPerfectDayItem(dayKey: dayKey) {
                    settle.perfectItem = true
                }
            }
            // Lifts or stretches done late move their rotation. Today is planned again from it, and finished work stays.
            // A day with a workout already done is left alone: its plan is underway, and a new plan would put an
            // open copy of a finished run or lift next to it (a planner row and a catalog row have different ids).
            let splitMoved = GymSplit.today(history: questHistory, dayKey: bundle.dayKey).id != splitBefore
            let stretchMoved = StretchSplit.today(history: questHistory, dayKey: bundle.dayKey).id != stretchBefore
            let done = bundle.quests.filter { $0.status == .completed }
            let workoutStarted = done.contains { $0.kind != .penalty && $0.id != ScreenTime.questId && $0.id != DailyStretch.questId }
            let stretchStarted = done.contains { $0.id == DailyStretch.questId } || !stretchesChecked.isEmpty
            let underway = workoutStarted || (stretchMoved && stretchStarted)
            // A run found late can fill the 50 km window (or a run that was only shown as progress can leave it):
            // the offline plan of today then holds a run too many, or one too few.
            let windowMoved = (loggedRunKm(before: bundle.dayKey) >= runGoal) != windowFullBefore
            if splitMoved || stretchMoved || windowMoved, !underway, runningTimers.isEmpty, bundle.dayKey == QuestDay.key(for: now) {
                generatedBundle = nil
                generationAttemptDayKey = nil
                rebuildBundle(catalog: catalog, now: now)
                keepFinished(done)
                // A finished penalty row goes back over the new row with its id. An open penalty still needs an open row.
                bundle = PenaltyQuests.ensure(in: bundle, open: player.penaltyOpen, band: trainingBand, catalog: catalog, now: now)
                settle.rebuiltToday = true
            }
        }

        ended.bundle = past.bundle
        // A service that is set but did not answer may still hold the missing work.
        let everyServiceRead = (!integrations.strava.configured || integrations.strava.available)
            && (!integrations.hevy.configured || integrations.hevy.available)
            && (!integrations.whoop.configured || integrations.whoop.available)
        let everySourceRead = everyServiceRead && healthRead
        // A read that only lacked Apple Health (a locked phone) is no real read: it does not use up the limit,
        // so the day still gets one read with Health open.
        if healthRead || !everyServiceRead { ended.reads += 1 }
        let waitsForWork = stillMissed && !everySourceRead
        let waitsForMacs = mac.trackerSet && !mac.answered
        endedDay = (waitsForWork || waitsForMacs) && ended.reads < EndedDay.maxReads ? ended : nil
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
            || late.questHistory.first?.missedRequired != false || !settled.perfectItem || !late.inventory.droppedKeys.contains(where: { $0.hasPrefix("\(keyOne)|perfect") }) {
            errors.append("a run found in the ended day's own data should lift its penalty, fix its record, and pay the day, got \(settled)")
        }
        if late.settleEndedDay(integrations: data(strava: [run]), catalog: catalog, now: dayTwo) != LateSettle() {
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

        // The Macs' last minutes: a day that passed on an old Mac count fails when the final count is over the limit.
        var mac = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        mac.applyScreenTime(phoneMinutes: 60, workMinutes: 300)
        finish(&mac) { $0.id != ScreenTime.questId }
        mac.refreshIfNeeded(catalog: catalog, now: dayTwo)
        let paid = mac.gold
        if mac.player.penaltyOpen || !mac.inventory.droppedKeys.contains(where: { $0.hasPrefix("\(keyOne)|perfect") }) || mac.endedDay?.missed != false {
            errors.append("a day that passed with Mac minutes should be paid and kept for the Macs' last read")
        }
        var waiting = mac
        _ = waiting.settleEndedDay(integrations: data(), mac: LateMacRead(trackerSet: true), catalog: catalog, now: dayTwo)
        if waiting.endedDay == nil || waiting.player.penaltyOpen { errors.append("a day should wait for a Mac tracker that did not answer") }
        var under = mac
        let fine = under.settleEndedDay(integrations: data(), mac: LateMacRead(trackerSet: true, answered: true, workMinutes: 400), catalog: catalog, now: dayTwo)
        if fine != LateSettle() || under.player.penaltyOpen || under.gold != paid || under.endedDay != nil
            || ContextBuilder.screenMinutesYesterday(snapshot: under, dayKey: under.bundle.dayKey) != 400 {
            errors.append("Mac minutes under the limit should change only the day's recorded minutes")
        }
        let over = mac.settleEndedDay(integrations: data(), mac: LateMacRead(trackerSet: true, answered: true, workMinutes: 840), catalog: catalog, now: dayTwo)
        let screenRecord = mac.questHistory.first?.quests.first { $0.method == .screenTimeLimit }
        if over.openedPenalty || mac.player.penaltyOpen || !PenaltyQuests.rows(in: mac.bundle).isEmpty || mac.gold != paid
            || mac.questHistory.first?.missedRequired == true || screenRecord?.status != .failed || mac.endedDay != nil {
            errors.append("the Macs' final minutes over the limit should turn the row red only: no penalty, gold kept, got \(over)")
        }
        // A day completed by a late run is paid. If the Macs then report a total over the limit, the row turns red only.
        var both = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        both.applyScreenTime(phoneMinutes: 60, workMinutes: 300)
        finish(&both) { !TrainingDay.isRaceRun($0) && $0.id != ScreenTime.questId }
        both.refreshIfNeeded(catalog: catalog, now: dayTwo)
        let ranLate = both.settleEndedDay(integrations: data(strava: [run]), mac: LateMacRead(trackerSet: true), catalog: catalog, now: dayTwo)
        if !ranLate.liftedPenalty || !ranLate.perfectItem || both.endedDay?.missed != false {
            errors.append("a late run should complete the day while it still waits for the Macs, got \(ranLate)")
        }
        let macLate = both.settleEndedDay(integrations: data(strava: [run]), mac: LateMacRead(trackerSet: true, answered: true, workMinutes: 840), catalog: catalog, now: dayTwo)
        if macLate.openedPenalty || both.player.penaltyOpen || !both.inventory.droppedKeys.contains(where: { $0.hasPrefix("\(keyOne)|perfect") }) {
            errors.append("Mac minutes over the limit should not fail a day that a late run completed, got \(macLate) gold \(both.gold)")
        }

        // A day with no Mac count and no tracker is not kept.
        var phoneOnly = GameSnapshot.fresh(catalog: catalog, now: dayOne)
        phoneOnly.applyScreenTime(phoneMinutes: 60, workMinutes: nil)
        finish(&phoneOnly) { $0.id != ScreenTime.questId }
        phoneOnly.refreshIfNeeded(catalog: catalog, now: dayTwo)
        if phoneOnly.endedDay != nil && MacScreenSettings.load().baseURL == nil { errors.append("a day with no Mac count should not wait for one") }

        // A save keeps the ended day, and a save from before this field loads without one.
        if let data = try? late.encoded(), (try? GameSnapshot.decoded(data)) != late { errors.append("a save should keep the snapshot") }
        var saved = down
        saved.endedDay = EndedDay(bundle: down.bundle, owesOtherPenalty: false)
        if let data = try? saved.encoded(), (try? GameSnapshot.decoded(data))?.endedDay != saved.endedDay { errors.append("a save should keep the ended day") }
        return errors
    }
}
