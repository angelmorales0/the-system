import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum GamePersistence {
    /// Saved on this device. Checkbox completion and XP survive relaunch.
    case standard
    /// Previews and checks. Does not touch UserDefaults.
    case memory
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var snapshot: GameSnapshot {
        didSet {
            let dayKey = snapshot.bundle.dayKey
            let cues = SoundCues.sounds(from: oldValue, to: snapshot, dayCuePlayed: dayCueDayKey == dayKey)
            if cues.contains(.dayClear) { dayCueDayKey = dayKey }
            // The day's lifts changed (a plan, a rest day, "No gym today", a new day): Hevy's routine follows.
            if HevyRoutine.rowsKey(oldValue.bundle) != HevyRoutine.rowsKey(snapshot.bundle) { writeHevyRoutine(now: .now) }
            guard soundsOn else { return }
            for sound in cues { sound.play() }
        }
    }
    /// The quest day whose day cue played, so a run that "No gym today" moves back does not play it again.
    private var dayCueDayKey: String? = UserDefaults.standard.string(forKey: GameStore.dayCueKey) {
        didSet { if persistence == .standard { UserDefaults.standard.set(dayCueDayKey, forKey: GameStore.dayCueKey) } }
    }
    private static let dayCueKey = "dayCueDayKey"
    @Published private(set) var verificationNote: String?
    /// What the last write of the day's routine to Hevy did, with the quest day it was for. Nil before any write.
    @Published private var hevyRoutineResult: (dayKey: String, note: String)? = {
        guard let note = UserDefaults.standard.string(forKey: GameStore.hevyRoutineNoteKey),
              let dayKey = UserDefaults.standard.string(forKey: GameStore.hevyRoutineNoteKey + ".day") else { return nil }
        return (dayKey, note)
    }()
    /// The line under the lifts: where today's workout is ready. Nil when the last write was for another day.
    var hevyRoutineNote: String? {
        guard hevyRoutineResult?.dayKey == snapshot.bundle.dayKey, let note = hevyRoutineResult?.note, !note.isEmpty,
              !note.hasPrefix("Hevy refused") else { return nil }
        return note
    }
    private static let hevyRoutineNoteKey = "hevyRoutineNote"
    private var writingHevyRoutine = false
    /// The rows changed while a write was on its way: one more write follows it.
    private var hevyRoutineAgain = false
    @Published private(set) var clock = Date()
    @Published private(set) var dayClock: DayClock
    /// Stat levels for the Status page. 0 until a stat's data arrives.
    @Published private(set) var statLevels: StatLevelSet = .empty
    /// One saved reading per day for the stat history charts.
    @Published private(set) var statHistory = StatLevelHistory()
    /// Targets the player removed from each stat's score.
    @Published private(set) var statTargets = StatTargets()

    /// Carries the player's own STR goals (`statTargets.custom`), so the offline split day trains them.
    private var catalog: FallbackCatalog
    private let generator: any QuestGenerating
    private let persistence: GamePersistence
    /// Armed once `init` has settled the saved day, so a launch plays only the launch cue.
    private var soundsArmed = false
    /// Previews and checks use a memory store and stay silent.
    private var soundsOn: Bool { soundsArmed && persistence == .standard }
    private var ticker: Timer?
    private var integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    /// The quest day `integrations` was loaded for.
    private var integrationsDayKey = ""
    /// The loaded workouts and readings, for the quest day on screen only. After a new day starts, the data in memory
    /// is yesterday's until the next refresh: read through this, yesterday's run would clear today's 10K at once.
    private var dayData: DayIntegrationSnapshot {
        integrationsDayKey == snapshot.bundle.dayKey ? integrations : .empty(dayKey: snapshot.bundle.dayKey)
    }
    private var refreshingIntegrations = false
    private var lastStretchRefresh = Date.distantPast
    /// The last live stat inputs, so a target change can recalculate without a new fetch. Nil until the first refresh.
    /// `inputs` holds the histories (Hevy, WHOOP, Strava, Health), loaded after the day's snapshot by `refreshStatInputs`.
    private var statInputs: (codeforces: CodeforcesReading, typing: MonkeytypeReading, financeMonths: [FinanceMonth], bodyMass: BodyMassReading?, focusDays: [FocusDay], inputs: StatInputs)?
    private var refreshingStatInputs = false
    /// True once the stat histories (Hevy, WHOOP, Strava, Apple Health) loaded one time. Before that the levels keep
    /// their last saved values: levels from empty histories read 0, and the lower max HP would cut the player's HP.
    private var statHistoriesLoaded = false

    init(persistence: GamePersistence = .standard) {
        #if DEBUG
        let problems = VerificationFixtures.check() + QuestGenerationRules.check() + IntegrationRules.check() + PenaltyRules.check() + RecoveryLevel.check()
            + StrengthLevel.check() + EnduranceLevel.check() + IntelligenceLevel.check()
            + AgilityLevel.check() + FocusLevel.check() + FinanceLevel.check() + StatLevelSet.check() + StatTargets.check() + FocusTracking.check() + MacScreenClient.check()
            + HiddenQuestRules.check() + RecoveryHolidayRules.check() + ShopRules.check()
            + DailyStretch.check() + StretchSplit.check() + TrainingDay.check() + ModePicker.checkFixtures() + GymSplit.check() + ScreenTimeRules.check()
            + NoGymDayRules.check() + PenaltyDecay.check() + RestRules.check() + RestScore.check() + SecretStore.check() + SecretSeed.check() + ConnectionStatusStore.check()
            + HevyClient.check() + OAuthClient.check() + StravaClient.check() + WhoopClient.check() + CodeforcesClient.check() + MonkeytypeClient.check() + MercuryClient.check()
            + TrainingHistory.check() + QuestPlanner.check() + HitPoints.check() + Fatigue.check()
            + AgilityHevy.check() + WhoopRecovery.check() + EnduranceEfforts.check() + ZoneTwo.check() + StatInputLoader.check()
            + EndedDayRules.check() + WorkoutClaimRules.check() + RebuiltRowRules.check() + PlanAndLockRules.check()
            + HevyRoutine.check() + HabitRules.check()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        // The write to Hevy is checked with replies made in the check: it calls no server.
        Task { @MainActor in
            let writeProblems = await HevyRoutine.checkWrites()
            precondition(writeProblems.isEmpty, writeProblems.joined(separator: "\n"))
        }
        let ringProblems = DayClockRules.check()
        precondition(ringProblems.isEmpty, ringProblems.joined(separator: "\n"))
        #endif

        // The build's API key goes into the Keychain before anything plans, so an Xcode install needs no typing.
        if persistence == .standard { SecretSeed.apply() }

        // The targets load first: today's split day needs the player's own goals.
        let targets = persistence == .standard ? StatTargets.load() : StatTargets()
        var catalog = FallbackCatalog.bundled()
        catalog.strengthGoals = targets.custom
        catalog.splitEdits = targets.split
        self.catalog = catalog
        self.generator = QuestGenerateClient.make(catalog: catalog)
        self.persistence = persistence
        // Previews and checks load no histories, so their levels come from the first refresh as before.
        statHistoriesLoaded = persistence == .memory
        dayClock = DayClock.resolve(
            current: persistence == .standard ? DayClock.load() : nil,
            now: .now
        )
        switch persistence {
        case .memory:
            snapshot = GameSnapshot.fresh(catalog: catalog)
        case .standard:
            snapshot = GameSnapshot.loadFromUserDefaults() ?? GameSnapshot.fresh(catalog: catalog)
            snapshot.habits.homeEvents = HomeEvents.load()
            snapshot.refreshIfNeeded(catalog: catalog)
            snapshot.claimQueuedRecoveryForToday(catalog: catalog, now: .now)
            snapshot.bundle = GymSplit.withoutOldRows(snapshot.bundle)
            // The saved plan too: a rebuild later in the day reads it, and would put the row back.
            snapshot.generatedBundle = snapshot.generatedBundle.map(GymSplit.withoutOldRows)
            // A day saved before the Stretching row, the exercise-only Training rule, or penalty rows gets them now.
            snapshot.bundle = snapshot.finished(TrainingDay.exerciseOnly(snapshot.bundle) ?? snapshot.bundle, catalog: catalog, now: .now)
            // A one-time grant the player asked for on 2026-11-13: 5 Full Recovery tokens. The flag keeps it to one launch.
            let grantKey = "grantFullRecovery-2026-11-13"
            if !UserDefaults.standard.bool(forKey: grantKey) {
                snapshot.player.fullRecoveryBank += 5
                snapshot.saveToUserDefaults()
                UserDefaults.standard.set(true, forKey: grantKey)
            }
        }
        #if DEBUG
        // Launch with `-skipSplitDay squat` to skip that split day and plan today again from the next one.
        // The option lasts one launch, and it does nothing once the split has moved past that day.
        // The result shows under the quest list and in the Xcode console, so a refused skip says why.
        if persistence == .standard, let skip = UserDefaults.standard.string(forKey: "skipSplitDay") {
            let refused = snapshot.skipSplitDay(skip, catalog: catalog, now: .now)
            let result = refused.map { "Split day not skipped. \($0)" } ?? "Skipped \(GymSplit.day(id: skip)?.name ?? skip). Today is \(snapshot.bundle.headerLine)."
            verificationNote = result
            print("[skipSplitDay] \(result)")
        }
        #endif
        if persistence == .standard {
            statHistory = StatLevelHistory.load()
            statTargets = targets
            statLevels = statHistory.latest ?? .empty
        }
        advanceTimers(now: .now)
        evaluateConnectedVerifiers(now: .now)
        persist()
        ensureTicker()
        observeHealthUpdates()
        // The home tracker is made at launch, so iOS can hand it the enter and leave events it woke the app for.
        if persistence == .standard {
            HomeTracker.shared.onEvent = { [weak self] in self?.homeEventArrived() }
            HomeTracker.shared.resume()
        }
        refreshIntegrations(now: .now)
        enforcePenalty()
        #if DEBUG
        // Launch with `-grantFullRecovery 2` to add tokens. The option lasts one launch, so a normal open adds nothing.
        let grant = UserDefaults.standard.integer(forKey: "grantFullRecovery")
        if persistence == .standard, (1...10).contains(grant) {
            snapshot.player.fullRecoveryBank += grant
            persist()
        }
        // Launch with `-clearPenalty 1` to end an open penalty without spending a token: the flag closes, the open
        // penalty rows go, and the lock lifts. The option lasts one launch; a later miss opens a penalty as usual.
        if persistence == .standard, UserDefaults.standard.bool(forKey: "clearPenalty"), snapshot.player.penaltyOpen {
            snapshot.player.penaltyOpen = false
            snapshot.bundle.quests.removeAll { $0.kind == .penalty && $0.status != .completed }
            verificationNote = "Penalty cleared from the launch option. No token was spent."
            print("[clearPenalty] Penalty cleared. Tokens: \(snapshot.player.fullRecoveryBank)")
            persist()
            enforcePenalty()
        }
        #endif
        if persistence == .standard {
            EmergencyCleanup.run()
            ScreenTimeEnforcement.syncMonitoring()
            #if os(iOS)
            FocusTracking.syncMonitoring()
            #endif
        }
        soundsArmed = true
    }

    private func cue(_ sound: SystemSound) {
        if soundsOn { sound.play() }
    }

    /// After the phone screen time picker saves, restart the daily count with the new apps.
    func savePhoneScreenSelection() {
        if persistence == .standard {
            ScreenTimeEnforcement.syncMonitoring(restart: true)
        }
        refreshIntegrations(now: .now)
    }

    /// A new quest day started while the app stayed open. The old day ends first, with its penalty, gold, and record.
    /// The caller then drops its action: the player chose it for the day that ended, so it must not change that day
    /// after its end or land on the new day by surprise.
    private func startedNewDay(now: Date) -> Bool {
        guard QuestDay.key(for: now) > snapshot.bundle.dayKey else { return false }
        refreshForToday(now: now)
        verificationNote = "A new day started. Nothing was changed."
        return true
    }

    func spendFullRecovery(now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.spendFullRecovery(catalog: catalog, now: now)
        let spent = next.player.fullRecoveryBank < snapshot.player.fullRecoveryBank
        snapshot = next
        verificationNote = message
        clock = now
        cue(spent ? .fullRecovery : .questFail)
        persist()
        enforcePenalty()
    }

    /// From Settings: spends one of this week's free rest days on today.
    func useRestDay(now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.useRestDay(catalog: catalog, now: now)
        let used = next.restDayKeys.count != snapshot.restDayKeys.count
        snapshot = next
        verificationNote = message
        clock = now
        cue(used ? .fullRecovery : .questFail)
        if used { runningTimersRemoveMissing() }
        persist()
        enforcePenalty()
    }

    /// From the penalty screen: one token ends the open penalty. The cleared cue plays from the flag change.
    func clearPenaltyWithFullRecovery(now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.clearPenaltyWithFullRecovery()
        let spent = next.player.fullRecoveryBank < snapshot.player.fullRecoveryBank
        snapshot = next
        verificationNote = message
        clock = now
        if !spent { cue(.questFail) }
        persist()
        enforcePenalty()
    }

    func buyFullRecovery(now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.buyFullRecovery()
        let bought = next.gold < snapshot.gold
        snapshot = next
        verificationNote = message
        clock = now
        cue(bought ? .purchase : .questFail)
        persist()
    }

    func usePotion(_ potion: Potion, now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.usePotion(potion, now: now)
        let drunk = next.potionLog.count > snapshot.potionLog.count
        snapshot = next
        verificationNote = message
        clock = now
        cue(drunk ? .potion : .questFail)
        recomputeStatLevels(now: now)
        persist()
        enforcePenalty()
    }

    func setNoGym(_ on: Bool, now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        let message = next.setNoGym(on, catalog: catalog, now: now, integrations: dayData)
        snapshot = next
        verificationNote = message
        clock = now
        persist()
        enforcePenalty()
    }

    /// After the owner saves or removes a key in Status → Connections: read the services again.
    func connectionsChanged() {
        allowGenerationAfterNewKey(now: .now)
        refreshIntegrations(now: .now)
    }

    /// A Claude key saved after this morning's offline plan: plan today again, if nothing is done yet.
    private func allowGenerationAfterNewKey(now: Date) {
        let dayKey = QuestDay.key(for: now)
        guard OnDeviceQuestGenerateClient.hasKey, snapshot.bundle.dayKey == dayKey,
              snapshot.generationAttemptDayKey == dayKey,
              ["mock", "fallback"].contains(snapshot.bundle.generatedBy),
              !snapshot.bundle.quests.contains(where: { $0.status == .completed }),
              snapshot.runningTimers.isEmpty else { return }
        var next = snapshot
        next.generationAttemptDayKey = nil
        next.generatedBundle = nil
        snapshot = next
        persist()
    }

    /// The Penalty Zone lists changed: reapply an open penalty so it takes effect at once.
    func saveTargetSelections() {
        enforcePenalty()
    }

    /// Adds a removed target back to a stat, or removes an active one, then recalculates the stat level.
    func toggleStatTarget(_ category: String, in stat: Stat) {
        statTargets.toggle(category, in: stat)
        if persistence == .standard { statTargets.save() }
        recomputeStatLevels(now: .now, announce: false)
        persist()
    }

    /// Adds the player's own STR goal. Returns why it was refused, or nil when it was saved.
    /// The STR level is calculated again at once. The split day trains it from the next plan on;
    /// today's quests stay as they are, so no logged set is lost.
    func addStrengthGoal(_ goal: CustomStrengthGoal) -> String? {
        var next = statTargets
        if let problem = next.add(goal) { return problem }
        saveStatTargets(next)
        return nil
    }

    /// Deletes one of the player's own STR goals, then calculates the STR level again.
    func deleteStrengthGoal(_ category: String) {
        var next = statTargets
        next.deleteCustom(category)
        saveStatTargets(next)
    }

    /// Saves today's behavior log note. An empty note removes it.
    func setLogNote(_ text: String) {
        var next = snapshot
        next.setLogNote(text)
        guard next != snapshot else { return }
        snapshot = next
        persist()
    }

    /// The habit streaks for the systems view, with caffeine from Apple Health once it is loaded.
    var systemsTracks: [SystemsView.Track] {
        let caffeine = Dictionary((statInputs?.inputs.recoveryDays ?? []).compactMap { day in day.caffeineMg.map { (day.dayKey, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return SystemsView.tracks(snapshot, caffeine: caffeine)
    }

    /// Saves the phone's location as home. Home by 9 pm starts with the next day.
    func setHomeHere() {
        guard persistence == .standard else { return }
        let tracker = HomeTracker.shared
        tracker.onSetHome = { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.verificationNote = problem
                return
            }
            var next = self.snapshot
            next.habits.homeSet = true
            next.habits.homeEvents = HomeEvents.load()
            self.snapshot = next
            self.verificationNote = "Home saved. Home by 9 pm starts tomorrow."
            self.persist()
        }
        tracker.setHomeHere()
    }

    /// The phone came home or left: judge the row again.
    private func homeEventArrived(now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        var next = snapshot
        next.habits.homeEvents = HomeEvents.load()
        next.applyHomeBy(now: now)
        guard next != snapshot else { return }
        snapshot = next
        persist()
        enforcePenalty()
    }

    /// Signs a contract. Returns why it was refused, or nil when it was signed.
    func signContract(_ draft: Contract, now: Date = .now) -> String? {
        var next = snapshot
        if let problem = next.signContract(draft, now: now) { return problem }
        snapshot = next
        persist()
        return nil
    }

    /// The newest weigh-in, in lb, for the contract form.
    var latestWeightLb: Double? {
        statInputs?.bodyMass.map { ($0.pounds * 10).rounded() / 10 } ?? snapshot.habits.weights.max { $0.key < $1.key }?.value
    }

    /// Saves the player's beliefs: trimmed, empty lines dropped, 10 at most.
    func setBeliefs(_ lines: [String]) {
        var next = snapshot
        next.habits.beliefs = Beliefs.cleaned(lines)
        guard next != snapshot else { return }
        snapshot = next
        persist()
    }

    /// Today's belief, for the quest screen.
    var beliefToday: String? { Beliefs.today(snapshot.habits.beliefs, dayKey: snapshot.bundle.dayKey) }

    /// The split with the player's goals and edits, for the editor.
    var editedRotation: [GymSplit.Day] { GymSplit.rotation(with: statTargets.custom, edits: statTargets.split) }

    /// Saves the player's change to one exercise of one split day: its sets, or whether it is optional.
    /// When today is that split day, today's open rows of the exercise change at once, and the Hevy routine follows.
    /// A finished row stays as it is.
    func editSplit(day id: String, exercise: String, sets: Int? = nil, optional: Bool? = nil, now: Date = .now) {
        let key = GymSplit.editKey(day: id, exercise: exercise)
        var next = statTargets
        var edit = next.split[key] ?? GymSplit.SplitEdit()
        if let sets { edit.sets = sets }
        if let optional { edit.optional = optional }
        // An edit back to the split's own values is no edit.
        if let base = GymSplit.rotation(with: next.custom).first(where: { $0.id == id })?.exercises
            .first(where: { GymSplit.editKey(day: id, exercise: $0.exercise) == key }) {
            if edit.sets == base.sets { edit.sets = nil }
            if edit.optional == base.optional { edit.optional = nil }
        }
        next.split[key] = edit == GymSplit.SplitEdit() ? nil : edit
        guard next != statTargets else { return }
        saveStatTargets(next)
        guard !startedNewDay(now: now),
              let day = GymSplit.plannedDay(of: snapshot.bundle, goals: next.custom, edits: next.split), day.id == id else { return }
        var updated = snapshot
        updated.bundle = GymSplit.applyingEdit(updated.bundle, day: day, exercise: exercise, band: updated.trainingBand)
        updated.generatedBundle = updated.generatedBundle.map { GymSplit.applyingEdit($0, day: day, exercise: exercise, band: updated.trainingBand) }
        guard updated != snapshot else { return }
        snapshot = updated
        persist()
    }

    private func saveStatTargets(_ targets: StatTargets) {
        statTargets = targets
        catalog.strengthGoals = targets.custom
        catalog.splitEdits = targets.split
        if persistence == .standard { statTargets.save() }
        recomputeStatLevels(now: .now, announce: false)
        persist()
    }

    /// Before the first refresh there are no live inputs; the next refresh applies the new targets.
    /// `announce` plays the level-up cue when the STATUS level rises; an edit to the targets stays quiet.
    private func recomputeStatLevels(now: Date, announce: Bool = true) {
        guard let statInputs, statHistoriesLoaded else { return }
        let before = statLevels
        defer {
            if announce, before != .empty, statLevels.overallLevel > before.overallLevel {
                cue(.levelUp)
            }
        }
        // A failed Codeforces or Monkeytype read keeps the last good reading for the level. The monthly quests
        // still read the live one, so a failed read can never judge a month.
        let saves = persistence == .standard
        statLevels = StatLevelSet.compute(
            codeforces: LastGoodReadings.codeforces(statInputs.codeforces, save: saves),
            typing: LastGoodReadings.typing(statInputs.typing, save: saves),
            financeMonths: statInputs.financeMonths,
            bodyMass: statInputs.bodyMass.map { [$0] } ?? [],
            focusDays: statInputs.focusDays,
            inputs: statInputs.inputs,
            targets: statTargets,
            excuses: snapshot.potionExcuses,
            now: now
        )
        statHistory.record(statLevels, on: QuestDay.key(for: now))
        syncMaxHP()
    }

    /// Max HP follows the stat levels. A new max moves the cap and keeps HP under it.
    private func syncMaxHP() {
        guard var hp = snapshot.hitPoints else { return }
        let maxHP = HitPoints.maxHP(for: statLevels)
        guard hp.max != maxHP else { return }
        hp.max = maxHP
        hp.current = min(hp.current, Double(maxHP))
        snapshot.hitPoints = hp
    }

    var player: PlayerState { snapshot.player }

    /// HP for the Status page. Before the first refresh: full, at the max the stat levels give.
    var hitPoints: (current: Int, max: Int) {
        let maxHP = snapshot.hitPoints?.max ?? HitPoints.maxHP(for: statLevels)
        var current = snapshot.hitPoints.map { Int($0.current.rounded(.down)) } ?? maxHP
        #if DEBUG
        // Launch with `-hpDebugPercent 15` to see the window at that share of max HP. Nothing is saved.
        if let percent = UserDefaults.standard.string(forKey: "hpDebugPercent").flatMap(Double.init) {
            current = Int((Double(maxHP) * min(max(percent, 0), 100) / 100).rounded(.down))
        }
        #endif
        return (current, maxHP)
    }

    /// Fatigue for the status sheet, 0...100. Before the first refresh: 0.
    var fatigue: Int {
        var value = snapshot.fatigue.map { Int($0.value.rounded()) } ?? 0
        #if DEBUG
        // Launch with `-fatigueDebug 85` to see the meter at that value. Nothing is saved.
        if let debug = UserDefaults.standard.string(forKey: "fatigueDebug").flatMap(Double.init) {
            value = Int(min(max(debug, 0), Fatigue.maxValue).rounded())
        }
        #endif
        return value
    }
    /// A hidden quest unlocked and not yet acknowledged. The quest screen shows its reveal window.
    var pendingHiddenReveal: HiddenQuestUnlock? { snapshot.pendingHiddenReveal }

    func acknowledgeHiddenReveal() {
        guard let reveal = snapshot.pendingHiddenReveal else { return }
        var next = snapshot
        next.markHiddenRevealSeen(id: reveal.id)
        snapshot = next
        cue(.systemClose)
        persist()
    }
    var bundle: QuestBundle { snapshot.bundle }
    var goalQuests: [Quest] { bundle.goalQuests }

    /// Sets of this stretch in today's Hevy workouts.
    func stretchSetsDone(_ stretch: StretchSplit.Stretch) -> Int {
        StretchSplit.setsDone(stretch, workouts: dayData.hevy.workouts)
    }

    private var stretchesInHevy: Set<String> {
        guard let day = snapshot.bundle.quests.first(where: { $0.id == DailyStretch.questId }).flatMap(StretchSplit.day(of:)) else { return [] }
        return Set(day.stretches.filter { stretchSetsDone($0) >= $0.sets }.map(\.name))
    }

    /// Checked by hand, full in Hevy, or the whole row is complete.
    func stretchDone(_ stretch: StretchSplit.Stretch) -> Bool {
        snapshot.bundle.quests.first { $0.id == DailyStretch.questId }?.status == .completed
            || snapshot.stretchesChecked.contains(stretch.name) || stretchSetsDone(stretch) >= stretch.sets
    }

    /// Checks or unchecks one stretch. A tap on the last open stretch completes the Stretching row.
    /// A stretch that is full in Hevy stays checked, and a completed row has no undo.
    func toggleStretch(_ stretch: StretchSplit.Stretch, now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        guard stretchSetsDone(stretch) < stretch.sets else { return }
        var next = snapshot
        next.toggleStretch(stretch.name, doneInHevy: stretchesInHevy)
        guard next != snapshot else { return }
        snapshot = next
        clock = now
        if let result = next.stretchCompletion(doneInHevy: stretchesInHevy, now: now) {
            commit(result, questId: DailyStretch.questId, now: now)
        } else {
            persist()
        }
    }

    var optionalQuests: [Quest] { bundle.optionalQuests }

    func rowLabel(for quest: Quest) -> String {
        guard quest.status != .completed,
              let started = snapshot.runningTimers.first(where: { $0.questId == quest.id })?.startedAt else {
            return quest.progress.bracketLabel
        }
        let elapsed = max(0, clock.timeIntervalSince(started))
        let required = TimerSessionVerifier.requiredSeconds(quest)
        return "[\(Self.clockString(elapsed))/\(Self.clockString(required))]"
    }

    func accessibilityValue(for quest: Quest) -> String {
        if quest.skippedWithPotion { return "Skipped with a potion" }
        if quest.status == .completed { return "Completed" }
        if snapshot.runningTimers.contains(where: { $0.questId == quest.id }) { return "Timer running" }
        switch quest.verification.method {
        case .timerSession:
            return "Timer not started"
        case .manualConfirm:
            return "Not confirmed"
        default:
            return "Not completed"
        }
    }

    /// The run row's own checkbox: counts the run by hand, for a day with a long bike ride instead. There is no undo.
    func checkOffByHand(id: String, now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        guard let quest = snapshot.bundle.quests.first(where: { $0.id == id }), quest.allowsCheckOff, quest.status == .pending else { return }
        var next = snapshot
        let outcome = next.applyLocalOverride(questId: id, now: now)
        next.checkHiddenQuests(integrations: dayData, now: now)
        snapshot = next
        clock = now
        note(for: outcome, title: quest.title)
        persist()
        enforcePenalty()
    }

    func handleQuestTap(id: String, now: Date = .now) {
        guard !startedNewDay(now: now) else { return }
        guard let quest = snapshot.bundle.quests.first(where: { $0.id == id }) else { return }
        // A completed quest stays completed. There is no undo.
        guard quest.status != .completed else { return }

        switch quest.verification.method {
        case .timerSession:
            beginTimer(questId: id, title: quest.title, now: now)
        case .manualConfirm:
            let context = snapshot.verificationContext(for: quest, now: now, timerElapsed: nil, userConfirmed: true)
            let result = ManualConfirmVerifier().evaluate(quest: quest, context: context)
            commit(result, questId: id, now: now)
        default:
            if quest.verification.method.allowsLocalCheckbox {
                var next = snapshot
                let outcome = next.applyLocalOverride(questId: id, now: now)
                snapshot = next
                clock = now
                note(for: outcome, title: quest.title)
                persist()
                enforcePenalty()
            } else if DistanceRule.minimumMeters(quest) != nil {
                // The runs of the day add together for a run row. The pass does that sum, so a tap runs the pass.
                evaluateConnectedVerifiers(now: now)
                clock = now
                let after = snapshot.bundle.quests.first { $0.id == id }
                if after?.status != .completed, after?.progress.current == quest.progress.current { cue(.questFail) }
                persist()
                enforcePenalty()
            } else {
                let context = snapshot.verificationContext(
                    for: quest,
                    now: now,
                    timerElapsed: nil,
                    userConfirmed: false,
                    integrations: dayData
                )
                let result = VerifierRegistry.verifier(for: quest.verification.method).evaluate(quest: quest, context: context)
                // A tap on a row the feeds verify shows no text: the row's own numbers say where it stands.
                switch result {
                case .incomplete, .unchanged:
                    clock = now
                    cue(.questFail)
                case .failed, .progress, .completed:
                    commit(result, questId: id, now: now)
                }
            }
        }
    }

    func refreshForToday(now: Date = .now) {
        let previousDay = snapshot.bundle.dayKey
        let previousGold = snapshot.gold
        var next = snapshot
        if persistence == .standard { next.habits.homeEvents = HomeEvents.load() }
        next.refreshIfNeeded(catalog: catalog, now: now)
        snapshot = next
        if snapshot.bundle.dayKey != previousDay {
            verificationNote = nil
            // Yesterday's gold is paid at rollover; that cue outranks the plain arrival.
            cue(snapshot.gold > previousGold ? .reward : .newDay)
        }
        dayClock = DayClock.resolve(current: dayClock, now: now)
        advanceTimers(now: now)
        evaluateConnectedVerifiers(now: now)
        persist()
        ensureTicker()
        refreshIntegrations(now: now)
        enforcePenalty()
    }

    /// Takes the newest phone count while the app stays open. The monitor writes it every minute of phone use.
    func readPhoneMinutes() {
        // The app stayed open past 5:00: end the old day here, so it is judged on time and no tap can change it.
        guard QuestDay.key(for: .now) <= snapshot.bundle.dayKey else { return refreshForToday() }
        var next = snapshot
        let phone = PhoneScreenGroup.minutes(for: next.bundle.dayKey)
        next.correctPhoneScreenTime(to: phone)
        next.applyScreenTime(phoneMinutes: phone, workMinutes: nil)
        rearmPhoneCount()
        guard next.screenTimeToday != snapshot.screenTimeToday else { return }
        snapshot = next
        sendScreenTimeAlerts()
        persist()
        enforcePenalty()
    }

    /// Notices at 50, 75, 90, 95, and 100 percent of the daily screen time cap.
    private func sendScreenTimeAlerts() {
        guard persistence == .standard, snapshot.bundle.quests.contains(where: { $0.id == ScreenTime.questId }) else { return }
        ScreenTimeAlerts.update(day: snapshot.screenTimeToday)
    }

    private func rearmPhoneCount() {
        if persistence == .standard {
            ScreenTimeEnforcement.rearmAfterBurst(now: .now)
        }
    }

    private func observeHealthUpdates() {
        HealthKitBridge.startObservers()
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .healthDataDidChange) {
                self?.refreshIntegrations(now: .now)
            }
        }
    }

    /// Phone minutes that surely overlap Mac minutes today. Nil without the Macs' minute bitmap or the day's start.
    private static func screenOverlap(dayKey: String, macScreen: WorkScreenReading?) -> Int? {
        guard let active = macScreen?.activeMinutes(for: dayKey), let start = QuestDay.start(of: dayKey) else { return nil }
        return ScreenOverlap.minutes(phoneTimes: PhoneScreenGroup.times(for: dayKey), macActive: active, dayStart: start)
    }

    private func refreshIntegrations(now: Date) {
        // A wake in the background (Apple Health) after 5:00 finds yesterday's day here. End it first: its quests must
        // not be checked against today's data, and its closed penalty flag must not lift the lock the monitor set at 5:00.
        guard QuestDay.key(for: now) <= snapshot.bundle.dayKey else { return refreshForToday(now: now) }
        guard !refreshingIntegrations else { return }
        refreshingIntegrations = true
        let dayKey = QuestDay.key(for: now)
        let endedKey = snapshot.endedDay?.bundle.dayKey
        let endedMissed = snapshot.endedDay?.missed ?? false
        Task { @MainActor [weak self] in
            // A day that ended with a quest open is read once more from its own data, before today is touched.
            // A day whose Screen Time row passed gets the Macs' last minutes.
            let endedData = await Self.endedDayData(endedKey, workouts: endedMissed)
            let endedMac = await Self.endedMacRead(endedKey)
            let health = await HealthKitBridge.summary(on: now)
            let bodyMass = await HealthKitBridge.latestBodyMass(days: EnduranceLevel.bodyWeightWindowDays, now: now)
            let remote = await IntegrationClient.load(dayKey: dayKey)
            let focusDays = FocusTracking.loadDays()
            let macScreen = await MacScreenClient.load(dayKey: dayKey)
            guard let self else { return }
            self.refreshingIntegrations = false
            // The day changed during the read (the app slept through 5:00 in the middle of it): this data is
            // yesterday's. Drop it and read for the new day.
            guard !(self.snapshot.bundle.dayKey > dayKey && QuestDay.key(for: .now) == self.snapshot.bundle.dayKey) else {
                self.refreshIntegrations(now: .now)
                return
            }
            var next = self.snapshot
            var settled = LateSettle()
            if let endedData, next.endedDay?.bundle.dayKey == endedKey {
                // A locked phone hides Apple Health: a read made then cannot say that Health holds no late work.
                let healthRead = Self.protectedDataAvailable
                settled = next.settleEndedDay(integrations: endedData, mac: endedMac, healthRead: healthRead, catalog: self.catalog, now: now)
            }
            let rebuilt = next.applyWhoopReadiness(remote.whoop, catalog: self.catalog, now: now) || settled.rebuiltToday
            let phone = PhoneScreenGroup.minutes(for: next.bundle.dayKey)
            next.correctPhoneScreenTime(to: phone)
            self.rearmPhoneCount()
            next.applyScreenTime(
                phoneMinutes: phone,
                workMinutes: macScreen?.minutes(for: next.bundle.dayKey),
                overlapMinutes: Self.screenOverlap(dayKey: next.bundle.dayKey, macScreen: macScreen)
            )
            next.applyFinance(remote.mercury)
            let day = DayIntegrationSnapshot.make(
                whoop: remote.whoop,
                strava: remote.strava,
                health: health,
                mercury: remote.mercury,
                hevy: remote.hevy
            )
            // The stat levels first: max HP is built from them.
            self.statInputs = (remote.codeforces, remote.monkeytype, remote.financeMonths, bodyMass, focusDays, self.statInputs?.inputs ?? StatInputs())
            self.recomputeStatLevels(now: now)
            let eatOutPenalty = next.applyEatOutCap(catalog: self.catalog, now: now)
            let unlocked = next.checkMorningLock(integrations: day, wokeAt: remote.whoop.wokeAt)
            // Weigh-ins: today's newest from Apple Health, and the daily ones of the last 30 days once they are loaded.
            let dailyMass = (self.statInputs?.inputs.recoveryDays ?? []).compactMap { day -> BodyMassReading? in
                guard let kg = day.bodyMassKg, let date = QuestDay.date(from: day.dayKey) else { return nil }
                return BodyMassReading(kg: kg, date: date, source: "Apple Health")
            }
            next.recordWeights(dailyMass + (bodyMass.map { [$0] } ?? []))
            let brokenContracts = next.judgeContracts(now: now)
            next.habits.homeEvents = HomeEvents.load()
            next.applyHomeBy(now: now)
            // After today's readiness, so a red recovery hits HP and sets the regeneration speed.
            next.applyHitPoints(integrations: day, maxHP: HitPoints.maxHP(for: self.statLevels), now: now)
            // After today's screen time too, so only the new minutes add fatigue.
            next.applyFatigue(integrations: day, now: now)
            self.snapshot = next
            self.sendScreenTimeAlerts()
            if self.persistence == .standard, let week = next.eatOutWeek { EatOutAlerts.update(week: week) }
            self.integrations = day
            self.integrationsDayKey = dayKey
            if settled.liftedPenalty {
                self.verificationNote = "The last quest day was completed. The penalty is lifted."
            } else if brokenContracts > 0 {
                self.verificationNote = "A contract week was broken: 1 Full Recovery token and 1 rest day are taken."
            } else if unlocked {
                self.verificationNote = "Morning workout found. Your apps are open."
            } else if eatOutPenalty {
                self.verificationNote = "Eating out went over \(FinanceLevel.usd(EatOut.capUsd)) this week. A penalty is open."
            } else if settled.openedPenalty {
                self.verificationNote = "The Macs' screen time put the last quest day over the limit. A penalty is open."
            }
            if rebuilt {
                self.runningTimersRemoveMissing()
            }
            self.evaluateConnectedVerifiers(now: now)
            // After today's readiness, sleep, and weight are in, so the generator plans from today's data.
            self.requestGenerationIfNeeded(now: now)
            self.persist()
            self.enforcePenalty()
            self.refreshStatInputs(now: now)
        }
    }

    /// False while the phone is locked: Apple Health and other protected data cannot be read then.
    private static var protectedDataAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// The Macs' minutes for the quest day `dayKey`, which has ended, as the Worker holds them now.
    private static func endedMacRead(_ dayKey: String?) async -> LateMacRead {
        guard let dayKey, MacScreenSettings.load().baseURL != nil else { return LateMacRead() }
        guard let reading = await MacScreenClient.load(dayKey: dayKey) else { return LateMacRead(trackerSet: true) }
        return LateMacRead(trackerSet: true, answered: true, workMinutes: reading.minutes(for: dayKey),
                           overlapMinutes: screenOverlap(dayKey: dayKey, macScreen: reading))
    }

    /// The workouts of the quest day `dayKey`, which has ended. Nil when no day waits for a late read.
    private static func endedDayData(_ dayKey: String?, workouts: Bool) async -> DayIntegrationSnapshot? {
        guard let dayKey, let inside = QuestDay.start(of: dayKey)?.addingTimeInterval(3_600) else { return nil }
        // A day that is kept only for the Macs' minutes has every workout row done: nothing to read.
        guard workouts else { return .empty(dayKey: dayKey) }
        async let hevy = HevyClient.snapshot(dayKey: dayKey)
        async let strava = StravaClient.snapshot(dayKey: dayKey)
        async let whoop = WhoopClient.snapshot(dayKey: dayKey)
        let health = await HealthKitBridge.summary(on: inside)
        return await DayIntegrationSnapshot.make(whoop: whoop, strava: strava, health: health, hevy: hevy)
    }

    /// The stat histories (Hevy, WHOOP, Strava, Apple Health) load after the day's snapshot, so a slow read never
    /// delays a quest check. Each source is cached and read again after 15 minutes (`StatInputLoader`).
    private func refreshStatInputs(now: Date) {
        guard persistence == .standard, !refreshingStatInputs else { return }
        refreshingStatInputs = true
        Task { @MainActor [weak self] in
            let inputs = await StatInputLoader.load(now: now)
            guard let self else { return }
            self.refreshingStatInputs = false
            guard var current = self.statInputs else { return }
            current.inputs = inputs
            self.statInputs = current
            self.statHistoriesLoaded = true
            self.recomputeStatLevels(now: now)
            self.persist()
            // The Hevy history is here now: it names the player's own exercises and last weights.
            self.writeHevyRoutine(now: now)
        }
    }

    /// Writes today's lifts and stretches to Hevy as a routine, when they changed (`HevyRoutine`).
    /// It waits for the Hevy history, so the routine holds the exercises the player uses.
    /// Only the player's phone writes: a Simulator build has the same key and its own, other day.
    private func writeHevyRoutine(now: Date) {
        #if targetEnvironment(simulator)
        return
        #else
        guard persistence == .standard, statHistoriesLoaded, let inputs = statInputs?.inputs,
              snapshot.bundle.dayKey == QuestDay.key(for: now) else { return }
        guard !writingHevyRoutine else {
            hevyRoutineAgain = true
            return
        }
        let bundle = snapshot.bundle
        let history = inputs.hevyWorkouts + dayData.hevy.workouts
        writingHevyRoutine = true
        Task { @MainActor [weak self] in
            let note = await HevyRoutine.sync(bundle: bundle, history: history)
            guard let self else { return }
            self.writingHevyRoutine = false
            if let note {
                self.hevyRoutineResult = (bundle.dayKey, note)
                UserDefaults.standard.set(note, forKey: Self.hevyRoutineNoteKey)
                UserDefaults.standard.set(bundle.dayKey, forKey: Self.hevyRoutineNoteKey + ".day")
            }
            if self.hevyRoutineAgain {
                self.hevyRoutineAgain = false
                self.writeHevyRoutine(now: .now)
            }
        }
        #endif
    }

    private func enforcePenalty() {
        let open = PenaltyQuests.rows(in: snapshot.bundle).first(where: { $0.status != .completed })
        let visible = snapshot.player.penaltyOpen && open != nil
        let title = open?.title ?? snapshot.bundle.headerLine
        PenaltyEnforcement.sync(
            penaltyVisible: visible,
            penaltyOpen: snapshot.player.penaltyOpen,
            questTitle: title,
            shieldLine: open.map(Self.shieldLine) ?? title,
            dayKey: snapshot.bundle.dayKey,
            openDayKey: snapshot.missesRequiredSet ? snapshot.bundle.dayKey : nil,
            // A penalty that waits through a token day or a rest day comes back tomorrow: the monitor locks at 5:00.
            owedDayKey: snapshot.player.penaltyOpen && !visible ? snapshot.bundle.dayKey : nil
        )
        guard persistence == .standard else { return }
        MorningLockEnforcement.sync(lockNow: snapshot.morningLockOn(now: .now), offToday: snapshot.morningLockOff, dayKey: snapshot.bundle.dayKey)
    }

    /// "Penalty 10K [3.2/10km]", like the quest row.
    nonisolated static func shieldLine(_ quest: Quest) -> String {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
        return "\(quest.title) [\(number(quest.progress.current))/\(number(quest.progress.target))\(quest.progress.unit)]"
    }

    /// The penalty row still open today, or nil. While it exists, `PenaltyQuestView` covers every page.
    var openPenaltyQuest: Quest? {
        guard snapshot.player.penaltyOpen else { return nil }
        return PenaltyQuests.rows(in: snapshot.bundle).first { $0.status != .completed }
    }

    /// When the open penalty started, as the enforcement saved it. Now, if it has not been saved yet.
    var penaltyStartedAt: Date {
        let saved = PenaltyGroup.defaults.double(forKey: PenaltyGroup.startedAtKey)
        return saved > 0 ? Date(timeIntervalSince1970: saved) : .now
    }

    /// One attempt per local day. The catalog bundle stays on screen until a valid bundle returns.
    private func requestGenerationIfNeeded(now: Date) {
        let dayKey = QuestDay.key(for: now)
        guard snapshot.bundle.dayKey == dayKey else { return }
        guard snapshot.generationAttemptDayKey != dayKey else { return }
        // A day the player spent a token on has nothing to plan.
        guard !snapshot.signals.spendingFullRecovery, snapshot.fullRecoveryDayKey != dayKey else { return }
        var next = snapshot
        next.generationAttemptDayKey = dayKey
        snapshot = next
        let finished = snapshot.bundle.quests.contains { $0.status == .completed } || !snapshot.runningTimers.isEmpty
        // An offline mock plan does not count once a Claude key is saved.
        let author = snapshot.bundle.generatedBy
        let alreadyGenerated = ["llm", "template"].contains(author) || (author == "mock" && !OnDeviceQuestGenerateClient.hasKey)
        if finished || alreadyGenerated {
            if alreadyGenerated, snapshot.generatedBundle == nil {
                snapshot.generatedBundle = snapshot.bundle.strippingModelCompletion(assignedAt: now)
            }
            persist()
            return
        }
        persist()
        let context = ContextBuilder.make(snapshot: snapshot, now: now, targets: statTargets, bodyMass: statInputs?.bodyMass, levels: statLevels, integrations: dayData)
        Task { [weak self] in
            await self?.runGeneration(context: context, dayKey: dayKey)
        }
    }

    /// Tries per local day when the planner gets no reply. Each later app open or refresh tries again.
    private static let generationRetriesPerDay = 3

    private func runGeneration(context: MorningContext, dayKey: String) async {
        // Planning can take two minutes. Ask iOS for time to finish if the app goes to the background.
        let background = GenerationBackgroundTask.begin()
        defer { GenerationBackgroundTask.end(background) }
        let result = await generator.generateResult(context: context)
        let bundle = result.bundle
        if result.retryLater {
            allowGenerationRetry(dayKey: dayKey)
            return
        }
        if result.restToday {
            takePlannerRest(dayKey: dayKey, reason: result.restReason)
            return
        }
        guard bundle.generatedBy != "fallback" else { return }
        let now = Date()
        guard snapshot.bundle.dayKey == dayKey, snapshot.generationAttemptDayKey == dayKey else { return }
        guard !snapshot.bundle.quests.contains(where: { $0.status == .completed }) else { return }
        guard snapshot.runningTimers.isEmpty else { return }
        let decision = ModePicker.decide(snapshot.modeInput(now: now))
        guard decision.selectedMode == context.modeDecision.selectedMode else { return }
        // "No gym today" changed while the plan was written: that plan is for the other kind of day. Plan again.
        guard context.constraints.noGymToday == snapshot.noGymToday else {
            var retry = snapshot
            retry.generationAttemptDayKey = nil
            snapshot = retry
            persist()
            return
        }
        guard let accepted = QuestSafety.accepting(bundle, context: context, assignedAt: now),
              let prepared = TrainingDay.exerciseOnly(accepted) else { return }
        // A rest day keeps the planner's words but none of its rows. The app adds Stretching and Screen Time.
        var plan = prepared
        if plan.mode == .fullRecovery { plan.quests = [] }
        var next = snapshot
        // A plan written for "No gym today" has no lifts, and its added 10K is the app's own row.
        if context.constraints.noGymToday {
            plan = NoGymDay.claimingAddedRun(plan)
            next.noGymPlanDayKey = dayKey
        } else if next.noGymPlanDayKey == dayKey {
            next.noGymPlanDayKey = nil
        }
        next.generatedBundle = plan
        next.bundle = next.finished(plan, catalog: catalog, now: now)
        snapshot = next
        runningTimersRemoveMissing()
        persist()
    }

    /// The planner made today the week's rest day. The day locks to Full Recovery and the catalog writes the Rest Day.
    private func takePlannerRest(dayKey: String, reason: String?) {
        let now = Date()
        guard snapshot.bundle.dayKey == dayKey, snapshot.generationAttemptDayKey == dayKey,
              !snapshot.bundle.quests.contains(where: { $0.status == .completed }),
              snapshot.runningTimers.isEmpty, snapshot.restAvailable(on: dayKey) else { return }
        var next = snapshot
        next.plannerRestDayKey = dayKey
        next.plannerRestReason = reason
        next.generatedBundle = nil
        next.rebuildBundle(catalog: catalog, now: now)
        snapshot = next
        runningTimersRemoveMissing()
        persist()
        enforcePenalty()
    }

    /// No reply came back: clear today's attempt so the next open or refresh plans again, up to the daily limit.
    private func allowGenerationRetry(dayKey: String) {
        let key = "com.angelmorales.thesystem.generationRetries.\(dayKey)"
        let used = UserDefaults.standard.integer(forKey: key)
        guard used < Self.generationRetriesPerDay, snapshot.generationAttemptDayKey == dayKey else { return }
        UserDefaults.standard.set(used + 1, forKey: key)
        var next = snapshot
        next.generationAttemptDayKey = nil
        snapshot = next
        persist()
    }

    private func beginTimer(questId: String, title: String, now: Date) {
        if snapshot.runningTimers.contains(where: { $0.questId == questId }) { return }
        var next = snapshot
        next.runningTimers.removeAll()
        next.runningTimers.append(TimerRun(questId: questId, startedAt: now))
        snapshot = next
        clock = now
        cue(.timerStart)
        let required = snapshot.bundle.quests.first(where: { $0.id == questId }).map { TimerSessionVerifier.requiredSeconds($0) } ?? 0
        verificationNote = "\(title) \(Self.clockString(0)) / \(Self.clockString(required))"
        persist()
        ensureTicker()
    }

    private func advanceTimers(now: Date) {
        clock = now
        guard !snapshot.runningTimers.isEmpty else { return }
        var next = snapshot
        var runningNote: String?
        var completed = false
        for run in snapshot.runningTimers {
            guard let quest = next.bundle.quests.first(where: { $0.id == run.questId }), quest.status != .completed else {
                next.runningTimers.removeAll { $0.questId == run.questId }
                continue
            }
            let elapsed = max(0, now.timeIntervalSince(run.startedAt))
            let context = next.verificationContext(for: quest, now: now, timerElapsed: elapsed, userConfirmed: false)
            let result = TimerSessionVerifier().evaluate(quest: quest, context: context)
            let outcome = next.apply(result, questId: quest.id, now: now)
            switch outcome {
            case .completed:
                completed = true
                next.runningTimers.removeAll { $0.questId == quest.id }
            case .rejected(let reason):
                runningNote = "\(quest.title): \(reason)"
                next.runningTimers.removeAll { $0.questId == quest.id }
            case .updated, .ignored:
                let required = TimerSessionVerifier.requiredSeconds(quest)
                runningNote = "\(quest.title) \(Self.clockString(elapsed)) / \(Self.clockString(required))"
            }
        }
        snapshot = next
        if completed, next.runningTimers.isEmpty {
            verificationNote = nil
        } else if let runningNote {
            verificationNote = runningNote
        }
        if next.runningTimers.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        if completed {
            enforcePenalty()
        }
    }

    /// Foreground pass for adapters that can see evidence without a tap. Stubs return incomplete and change nothing.
    private func evaluateConnectedVerifiers(now: Date) {
        var next = snapshot
        next.checkOpenRows(integrations: dayData, now: now, skipping: [.manualConfirm, .timerSession])
        // Hevy can finish the stretches that are left, short of the row's total minutes.
        if let result = next.stretchCompletion(doneInHevy: stretchesInHevy, now: now) {
            _ = next.apply(result, questId: DailyStretch.questId, now: now)
        }
        next.checkHiddenQuests(integrations: dayData, now: now)
        snapshot = next
    }

    private func commit(_ result: VerificationResult, questId: String, now: Date) {
        let title = snapshot.bundle.quests.first(where: { $0.id == questId })?.title ?? "Quest"
        var next = snapshot
        let outcome = next.apply(result, questId: questId, now: now)
        next.checkHiddenQuests(integrations: dayData, now: now)
        snapshot = next
        clock = now
        note(for: outcome, title: title)
        persist()
        enforcePenalty()
    }

    private func note(for outcome: VerificationApply, title: String) {
        switch outcome {
        case .completed:
            verificationNote = nil
        case .rejected:
            // No text under the list for a refused tap; the cue says it did not take.
            cue(.questFail)
        case .ignored, .updated:
            break
        }
    }

    private func runningTimersRemoveMissing() {
        let ids = Set(snapshot.bundle.quests.map(\.id))
        snapshot.runningTimers.removeAll { !ids.contains($0.questId) }
    }

    private func ensureTicker() {
        guard !snapshot.runningTimers.isEmpty else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // The timer is on the main run loop, so it always fires on the main actor.
            MainActor.assumeIsolated {
                self?.advanceTimers(now: .now)
                self?.persist()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func persist() {
        guard persistence == .standard else { return }
        snapshot.saveToUserDefaults()
        dayClock.save()
        statHistory.save()
    }

    private static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
