import Foundation

/// "No gym today": the player cannot get to the gym, so the Training day swaps its lifts for one added 10K.
/// The added 10K sits on top of whatever the 50 km window asked for today, and it never counts toward that
/// window (`TrainingHistory.noGymAddedKm`). The day stays under two 10Ks and 20 km, so a day the window already
/// filled with two 10Ks adds none. Finished work stays. Penalty rows are not changed. The setting lasts one quest day.
enum NoGymDay {
    /// The id slug of the 10K this setting adds. It is the app's own: the planner names its runs `run_10k_1`,
    /// `run_10k_2`, and so on, so a planned run can never pass for the added one.
    static let addedSlug = "run_10k_no_gym"
    /// The most runs a day holds: the window's runs plus the added 10K, never more than this.
    static let runCount = 2

    static func addedId(_ dayKey: String) -> String { "q_\(dayKey)_\(addedSlug)" }

    static func cardioOnly(_ bundle: QuestBundle, now: Date) -> QuestBundle {
        guard bundle.mode == .performanceTraining else { return bundle }
        var copy = bundle
        copy.quests.removeAll { isSwappable($0) && TrainingDay.isStrength($0) && $0.status != .completed }
        if !copy.quests.contains(where: { TrainingDay.isStrength($0) && $0.id != DailyStretch.questId }) {
            copy.headerLine = TrainingDay.header
        }
        // The day already holds its added 10K: a second pass, such as the next launch, adds nothing.
        guard !copy.quests.contains(where: { isAdded($0, dayKey: copy.dayKey) }) else { return addedRunFirst(copy) }
        let runs = copy.quests.filter { isSwappable($0) && TrainingDay.isRaceRun($0) }
        let km = runs.reduce(0.0) { $0 + ($1.verification.params["minDistanceMeters"]?.doubleValue ?? 0) / 1000 }
        guard runs.count < runCount, km + Double(TrainingHistory.noGymAddedKm) <= Double(TrainingHistory.maxRunKmPerDay) else { return copy }
        let added = tenK(from: runs.first { isTenK($0) }, bundle: copy, now: now)
        copy.quests.insert(added, at: copy.workoutInsertIndex)
        return addedRunFirst(copy)
    }

    /// Puts the added 10K before the day's own runs. Runs are checked in row order, so a real run then fills the
    /// added 10K first, and the day's run keeps its hand check and its potion. In the other order, a real run took
    /// the day's row and left the added one, which takes neither: the same work finished the day or not by its order.
    /// A plan the planner wrote for the no-gym day has the added 10K last, so this runs for that plan too.
    static func addedRunFirst(_ bundle: QuestBundle) -> QuestBundle {
        guard let from = bundle.quests.firstIndex(where: { isAdded($0, dayKey: bundle.dayKey) }),
              let to = bundle.quests.firstIndex(where: { isSwappable($0) && TrainingDay.isRaceRun($0) }), to < from else { return bundle }
        var copy = bundle
        copy.quests.insert(copy.quests.remove(at: from), at: to)
        return copy
    }

    /// True for the row this setting added, so turning it off can take the row away again.
    static func isAdded(_ quest: Quest, dayKey: String) -> Bool {
        quest.id == addedId(dayKey)
    }

    /// A plan written for a no-gym day already holds the added 10K. On a day whose window needs no run, that 10K
    /// is the plan's only run. It takes the app's id, so the swap adds no second one and "No gym" off removes it.
    static func claimingAddedRun(_ bundle: QuestBundle) -> QuestBundle {
        let runs = bundle.quests.indices.filter { isSwappable(bundle.quests[$0]) && TrainingDay.isRaceRun(bundle.quests[$0]) }
        guard bundle.mode == .performanceTraining, runs.count == 1, let index = runs.first, isTenK(bundle.quests[index]) else { return bundle }
        var copy = bundle
        copy.quests[index].id = addedId(bundle.dayKey)
        return copy
    }

    /// True when the day's data holds a run of 10 km that this evidence stands for.
    static func reachedTenK(_ evidence: [Evidence], in data: DayIntegrationSnapshot?) -> Bool {
        guard let data else { return false }
        return data.workouts.contains { workout in
            guard workout.sportFamily == .run, DistanceRule.meets(workout, TrainingDay.tenKMeters) else { return false }
            let ids = Set(workout.members.map(\.id) + [workout.id])
            return evidence.contains { use in
                !use.workoutIds.isDisjoint(with: ids)
                    || use.session.map { WorkoutDedupe.sameTime($0.start, $0.end, workout.start, workout.end) } ?? false
            }
        }
    }

    static func isTenK(_ quest: Quest) -> Bool {
        TrainingDay.isRaceRun(quest) && quest.verification.params["minDistanceMeters"]?.doubleValue == TrainingDay.tenKMeters
    }

    private static func isSwappable(_ quest: Quest) -> Bool {
        quest.kind == .daily && quest.id != DailyStretch.questId
    }

    /// A fresh copy of the day's 10K, or the catalog's 10K when the day has none.
    private static func tenK(from template: Quest?, bundle: QuestBundle, now: Date) -> Quest {
        Quest(
            id: addedId(bundle.dayKey),
            title: TrainingDay.tenKTitle,
            kind: .daily,
            stat: .END,
            verification: template?.verification ?? VerificationSpec(
                method: .stravaActivity,
                params: ["types": .array([.string("Run")]), "minDistanceMeters": .number(TrainingDay.tenKMeters)]
            ),
            deadline: QuestDay.endOfDay(now),
            difficulty: template?.difficulty ?? .normal,
            mode: bundle.mode,
            progress: QuestProgress(current: 0, target: 10, unit: "km"),
            status: .pending,
            evidence: [],
            assignedAt: now
        )
    }
}

extension QuestBundle {
    /// Where a workout row goes: after the day's own workouts, before Screen Time, Stretching, and optional rows.
    /// Penalty rows lead the list and stay first, so a run clears the penalty before it counts for the day.
    var workoutInsertIndex: Int {
        quests.firstIndex { $0.kind != .penalty && ($0.id == ScreenTime.questId || $0.id == DailyStretch.questId || $0.kind != .daily) } ?? quests.count
    }
}

extension GameSnapshot {
    var noGymToday: Bool {
        noGymDayKey == bundle.dayKey
    }

    /// Turns "No gym today" on or off for the current quest day.
    /// `integrations` is the day's data, when it is read: it shows how far the run on a 5K row went.
    mutating func setNoGym(_ on: Bool, catalog: FallbackCatalog, now: Date, integrations: DayIntegrationSnapshot? = nil) -> String {
        guard bundle.mode == .performanceTraining else {
            return "Today is a Full Recovery day. There is no training to change."
        }
        if on {
            noGymDayKey = bundle.dayKey
            bundle = finished(bundle, catalog: catalog, now: now)
            giveRealRunToAddedRow(integrations: integrations)
            return "No gym available. Strength quests are swapped for an added 10K. It does not count toward the 50 km window."
        }
        noGymDayKey = nil
        // A plan the planner wrote for the no-gym day has no lifts to bring back. Drop it: the split day comes back now,
        // and the planner plans the gym day at the next refresh while nothing is done yet.
        if noGymPlanDayKey == bundle.dayKey {
            generatedBundle = nil
            generationAttemptDayKey = nil
        }
        noGymPlanDayKey = nil
        giveAddedRunToDayRun(integrations: integrations)
        var fresh = self
        fresh.rebuildBundle(catalog: catalog, now: now)
        let dayKey = bundle.dayKey
        bundle.quests.removeAll { NoGymDay.isAdded($0, dayKey: dayKey) && $0.status != .completed }
        // By id, and by exercise: a row saved under an older id scheme is still that lift, and a second copy
        // could never complete, because its Hevy sets are already used.
        func exercise(_ quest: Quest) -> String { StrengthLevel.normalizedName(quest.verification.params["exercise"]?.stringValue ?? quest.title) }
        let held = Set(bundle.quests.filter { $0.verification.method == .hevySets && $0.id != DailyStretch.questId }.map(exercise))
        let lifts = fresh.bundle.quests.filter { lift in
            lift.kind == .daily && TrainingDay.isStrength(lift) && !bundle.quests.contains { $0.id == lift.id }
                && !(lift.verification.method == .hevySets && held.contains(exercise(lift)))
        }
        bundle.quests.insert(contentsOf: lifts, at: bundle.workoutInsertIndex)
        // The lifts come back over the window's runs: still two workouts, unless one is already finished.
        bundle = TrainingDay.cappingWorkouts(bundle)
        bundle.headerLine = fresh.bundle.headerLine
        return "Gym day again. Strength quests are back."
    }

    /// A real run of 10 km that the day's run took before the setting went on fills the added 10K, and the day's
    /// run is open again with its hand check. That is the day the same work gives when the setting goes on first:
    /// there the run fills the added 10K, which is checked first. Without this, the day asked for a second real 10K.
    /// A hand check or a potion is no real run, so such a row stays as it is. A 10K row was finished by 10 km.
    /// A 5K row can hold a shorter run, so the row or the day's data must show that its run reached 10 km.
    /// The switch can come before the day's data, so each pass that has the data does this too (`checkOpenRows`).
    mutating func giveRealRunToAddedRow(integrations: DayIntegrationSnapshot?) {
        let addedId = NoGymDay.addedId(bundle.dayKey)
        guard let added = bundle.quests.firstIndex(where: { $0.id == addedId && $0.status != .completed }),
              let ran = bundle.quests.firstIndex(where: { quest in
                  guard quest.kind == .daily, quest.id != addedId, TrainingDay.isRaceRun(quest), quest.status == .completed,
                        !quest.skippedWithPotion, !quest.evidence.isEmpty, quest.evidence.allSatisfy({ !$0.workoutIds.isEmpty }) else { return false }
                  return NoGymDay.isTenK(quest) || quest.progress.current >= 10 || NoGymDay.reachedTenK(quest.evidence, in: integrations)
              }) else { return }
        moveFinish(from: ran, to: added, integrations: integrations)
    }

    /// The other direction, when the setting goes off: a real 10K on the added row is the day's run while that run
    /// is open. The day is then the gym day it was, with its run done, and the record of the day holds no added 10K.
    private mutating func giveAddedRunToDayRun(integrations: DayIntegrationSnapshot?) {
        let addedId = NoGymDay.addedId(bundle.dayKey)
        guard let ran = bundle.quests.firstIndex(where: { $0.id == addedId && $0.status == .completed }),
              let open = bundle.quests.firstIndex(where: {
                  $0.kind == .daily && $0.id != addedId && TrainingDay.isRaceRun($0) && $0.status != .completed
              }) else { return }
        moveFinish(from: ran, to: open, integrations: integrations)
        bundle.quests.remove(at: ran)
    }

    /// One row gives its finish to another: the evidence, the uses of that evidence, and the hidden quest the run
    /// unlocked go with it. The first row is open again, so the same run cannot fill it a second time.
    private mutating func moveFinish(from: Int, to: Int, integrations: DayIntegrationSnapshot?) {
        let oldId = bundle.quests[from].id, newId = bundle.quests[to].id, dayKey = bundle.dayKey
        let target = bundle.quests[to].progress.target
        bundle.quests[to].status = .completed
        // A finished run row can show its real distance, such as 15.2 km. It goes with the finish. The day's data
        // gives it exactly: a 9.96 km run reads 10 on a 10K and 9.9 on a 5K.
        bundle.quests[to].progress.current = max(target, bundle.quests[from].progress.current)
        bundle.quests[to].evidence = bundle.quests[from].evidence
        bundle.quests[to].skippedWithPotion = false
        if let meters = HiddenQuests.completingWorkout(for: bundle.quests[to], in: integrations?.workouts ?? [])?.distanceMeters {
            bundle.quests[to].progress.current = max(target, DistanceRule.kilometers(meters))
        }
        // Beyond the Limit measures a run against the row it finished. A run that finished a 10K stays measured
        // against 10 km on a 5K row: the move pays for no run that did not earn it where it was done.
        let fromBase = HiddenQuests.baseMeters(bundle.quests[from]), toMinimum = DistanceRule.minimumMeters(bundle.quests[to]) ?? 0
        bundle.quests[to].verification.params[HiddenQuests.baseParam] = fromBase > toMinimum ? .number(fromBase) : nil
        bundle.quests[from].verification.params[HiddenQuests.baseParam] = nil
        bundle.quests[from].status = .pending
        bundle.quests[from].progress.current = 0
        bundle.quests[from].evidence = []
        for index in evidenceLog.indices where evidenceLog[index].dayKey == dayKey && evidenceLog[index].questId == oldId {
            evidenceLog[index].questId = newId
        }
        progressLog.removeAll { $0.dayKey == dayKey && $0.questId == newId }
        for index in hiddenUnlocks.indices where hiddenUnlocks[index].dayKey == dayKey && hiddenUnlocks[index].questId == oldId {
            hiddenUnlocks[index].questId = newId
        }
    }
}

enum NoGymDayRules {
    /// Stretching can be checked by Hevy too, so it is not a lift here.
    private static func isLift(_ quest: Quest) -> Bool {
        quest.id != DailyStretch.questId && TrainingDay.isStrength(quest)
    }

    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.date(from: "2026-10-01") else { return ["quest day failed to parse"] }
        var day = GameSnapshot.fresh(catalog: catalog, now: now)
        let before = day.bundle.quests.map(\.id)
        guard day.bundle.quests.contains(where: { isLift($0) }),
              day.bundle.quests.contains(where: { NoGymDay.isTenK($0) }) else {
            return ["the green Training day should have a lift and a 10K"]
        }

        _ = day.setNoGym(true, catalog: catalog, now: now)
        let ids = day.bundle.quests.map(\.id)
        if day.bundle.quests.contains(where: { isLift($0) }) {
            errors.append("no gym should remove the unfinished lifts, got \(ids)")
        }
        if day.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 2 {
            errors.append("no gym should give two 10K rows, got \(ids)")
        }
        if ids.last != DailyStretch.questId {
            errors.append("the second 10K should come before Stretching, got \(ids)")
        }
        if !day.noGymToday {
            errors.append("no gym should be on for today")
        }

        // A rebuild the same day, for example when WHOOP readiness arrives, keeps the swap.
        day.rebuildBundle(catalog: catalog, now: now)
        if day.bundle.quests.contains(where: { isLift($0) }) || day.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 2 {
            errors.append("a rebuild should keep the no-gym swap, got \(day.bundle.quests.map(\.id))")
        }
        let again = day.bundle
        _ = day.setNoGym(true, catalog: catalog, now: now)
        if day.bundle != again {
            errors.append("turning no gym on twice should change nothing")
        }

        _ = day.setNoGym(false, catalog: catalog, now: now)
        if day.bundle.quests.map(\.id) != before {
            errors.append("turning no gym off should restore the lifts, got \(day.bundle.quests.map(\.id)) expected \(before)")
        }

        // A lift already done stays done.
        var lifted = GameSnapshot.fresh(catalog: catalog, now: now)
        if let index = lifted.bundle.quests.firstIndex(where: { isLift($0) }) {
            lifted.bundle.quests[index].status = .completed
            let liftId = lifted.bundle.quests[index].id
            _ = lifted.setNoGym(true, catalog: catalog, now: now)
            if lifted.bundle.quests.first(where: { $0.id == liftId })?.status != .completed {
                errors.append("no gym must keep a finished lift")
            }
        }

        // The setting ends with the quest day.
        let tomorrow = now.addingTimeInterval(86_400)
        day.noGymDayKey = day.bundle.dayKey
        day.refreshIfNeeded(catalog: catalog, now: tomorrow)
        if day.noGymToday || !day.bundle.quests.contains(where: { isLift($0) }) {
            errors.append("no gym should end at the next quest day")
        }

        // A Full Recovery day is not changed.
        var rest = GameSnapshot.fresh(catalog: catalog, now: now)
        rest.signals.spendingFullRecovery = true
        rest.fullRecoveryDayKey = rest.bundle.dayKey
        rest.rebuildBundle(catalog: catalog, now: now)
        let restQuests = rest.bundle.quests
        _ = rest.setNoGym(true, catalog: catalog, now: now)
        if rest.bundle.quests != restQuests || rest.noGymToday {
            errors.append("no gym must not change a Full Recovery day")
        }

        // A planned run named like the planner names it (`run_10k_1`) is the window's own: no gym off keeps it.
        var planned = GameSnapshot.fresh(catalog: catalog, now: now)
        var plan = planned.bundle
        plan.generatedBy = "template"
        plan.quests.removeAll { $0.id == ScreenTime.questId || $0.id == DailyStretch.questId }
        if let index = plan.quests.firstIndex(where: { NoGymDay.isTenK($0) }) { plan.quests[index].id = "q_\(plan.dayKey)_run_10k_1" }
        planned.generatedBundle = plan
        planned.rebuildBundle(catalog: catalog, now: now)
        let plannedIds = planned.bundle.quests.map(\.id)
        _ = planned.setNoGym(true, catalog: catalog, now: now)
        _ = planned.setNoGym(false, catalog: catalog, now: now)
        if planned.bundle.quests.map(\.id) != plannedIds {
            errors.append("no gym on and off should give the planned day back, with its run, got \(planned.bundle.quests.map(\.id))")
        }

        // A day whose run window is full gets the one added 10K, and the next launch adds no second one.
        var full = GameSnapshot.fresh(catalog: catalog, now: now)
        let ran = QuestRecord(title: "10K Run", kind: .daily, stat: .END, method: .stravaActivity, params: [:], target: 10, done: 10, unit: "km", status: .completed)
        full.questHistory = (1...5).map { daysAgo in
            QuestDayRecord(dayKey: QuestDay.key(byAddingDays: -daysAgo, to: full.bundle.dayKey), mode: .performanceTraining, trainingBand: .green,
                           noGym: false, generatedBy: "fallback", missedRequired: false, quests: [ran])
        }
        full.rebuildBundle(catalog: catalog, now: now)
        _ = full.setNoGym(true, catalog: catalog, now: now)
        let swapped = full.bundle
        full.bundle = full.finished(TrainingDay.exerciseOnly(full.bundle) ?? full.bundle, catalog: catalog, now: now)
        if full.bundle != swapped || full.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 1 {
            errors.append("a launch should not add a second 10K to a no-gym day, got \(full.bundle.quests.map(\.id))")
        }
        // A plan the planner wrote for that day holds the added 10K as its only run: the app adds no second one.
        var written = GameSnapshot.fresh(catalog: catalog, now: now)
        var noGymPlan = plan
        noGymPlan.quests.removeAll { isLift($0) }
        noGymPlan = NoGymDay.claimingAddedRun(noGymPlan)
        written.noGymDayKey = written.bundle.dayKey
        written.noGymPlanDayKey = written.bundle.dayKey
        written.generatedBundle = noGymPlan
        written.rebuildBundle(catalog: catalog, now: now)
        if written.bundle.quests.filter({ NoGymDay.isTenK($0) }).count != 1 {
            errors.append("a plan written for a no-gym day should keep its one 10K, got \(written.bundle.quests.map(\.id))")
        }
        // No gym off drops that plan, so the lifts come back.
        _ = written.setNoGym(false, catalog: catalog, now: now)
        if !written.bundle.quests.contains(where: { isLift($0) }) || written.generatedBundle != nil || written.bundle.headerLine != "Bench Day" {
            errors.append("no gym off should bring the lifts back after a plan written for the no-gym day, got \(written.bundle.quests.map(\.id))")
        }

        // One real 10K and one hand check finish a no-gym day when the run comes before the setting too: the run
        // goes to the added 10K, and the day's run is open with its hand check. The run cannot fill both rows.
        // Off again gives the gym day back with its run done.
        var early = GameSnapshot.fresh(catalog: catalog, now: now)
        if let dayRun = early.bundle.quests.first(where: { NoGymDay.isTenK($0) }) {
            let start = now.addingTimeInterval(3_600)
            let real = Evidence.make(source: "strava", externalId: "\(Evidence.workoutPrefix)strava:early", payload: "early", timestamp: start.addingTimeInterval(3_300),
                                     recordings: ["strava:early"], sessionStart: start)
            _ = early.apply(.completed(evidence: real), questId: dayRun.id, now: now)
            let gymDay = early.bundle
            _ = early.setNoGym(true, catalog: catalog, now: now)
            let runs = early.bundle.quests.filter { TrainingDay.isRaceRun($0) }
            if runs.map(\.id) != [NoGymDay.addedId(early.bundle.dayKey), dayRun.id] || runs.first?.status != .completed
                || runs.last?.status == .completed || runs.last?.allowsCheckOff != true {
                errors.append("a real 10K before no gym should fill the added 10K and leave the day's run open, got \(runs.map { "\($0.id) \($0.status)" })")
            }
            var again = early
            if let open = runs.last, again.apply(.completed(evidence: real), questId: open.id, now: now) == .completed {
                errors.append("the run that filled the added 10K should not fill the day's run too")
            }
            let on = early.bundle
            _ = early.setNoGym(true, catalog: catalog, now: now)
            if early.bundle != on { errors.append("no gym on twice after a real run should change nothing") }
            _ = early.setNoGym(false, catalog: catalog, now: now)
            if early.bundle.quests.map(\.id) != gymDay.quests.map(\.id) || early.bundle.quests.first(where: { $0.id == dayRun.id })?.status != .completed
                || !early.evidenceLog.contains(where: { $0.questId == dayRun.id }) || early.evidenceLog.contains(where: { $0.questId == NoGymDay.addedId(gymDay.dayKey) }) {
                errors.append("no gym off should give the gym day back with its real run done, got \(early.bundle.quests.map { "\($0.id) \($0.status)" })")
            }
            // A hand check is no real run: the added 10K stays open and the checked row stays.
            var checked = GameSnapshot.fresh(catalog: catalog, now: now)
            _ = checked.applyLocalOverride(questId: dayRun.id, now: now)
            _ = checked.setNoGym(true, catalog: catalog, now: now)
            if checked.bundle.quests.first(where: \.isNoGymRun)?.status == .completed || checked.bundle.quests.first(where: { $0.id == dayRun.id })?.status != .completed {
                errors.append("a hand check before no gym should not fill the added 10K")
            }
        }

        // With a penalty open, the added 10K goes below the Penalty 10K, so the first run clears the penalty.
        var owed = GameSnapshot.fresh(catalog: catalog, now: now)
        owed.player.penaltyOpen = true
        owed.rebuildBundle(catalog: catalog, now: now)
        _ = owed.setNoGym(true, catalog: catalog, now: now)
        if owed.bundle.quests.first?.kind != .penalty || owed.bundle.quests.filter({ $0.kind == .daily && NoGymDay.isTenK($0) }).count != 2 {
            errors.append("the penalty row should stay first on a no-gym day, got \(owed.bundle.quests.map(\.id))")
        }
        _ = owed.setNoGym(false, catalog: catalog, now: now)
        if owed.bundle.quests.first?.kind != .penalty {
            errors.append("the penalty row should stay first after no gym off, got \(owed.bundle.quests.map(\.id))")
        }
        return errors
    }
}
