import Foundation

struct TimerRun: Codable, Equatable {
    var questId: String
    var startedAt: Date
}

struct GameSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let storageKey = "com.angelmorales.thesystem.snapshot.v1"

    var version: Int
    var player: PlayerState
    var signals: MorningSignals
    var bundle: QuestBundle
    var evidenceLog: [EvidenceUse] = []
    var runningTimers: [TimerRun] = []
    /// Today's WHOOP recovery. Not copied into `player.stats.REC`.
    var readiness: ReadinessSnapshot?
    /// Mercury aggregates for the quest day. Not a dollar balance.
    var finance: FinanceSnapshot?
    /// The newest month whose monthly quests were judged, "YYYY-MM". Each month opens at most one penalty.
    var monthlyPenaltyMonth: String?
    /// Titles from the previous quest day. Sent as summaries, never as evidence.
    var recentQuestTitles: [String] = []
    /// Past quest days as they ended, newest first, at most 30. The generator reads them.
    var questHistory: [QuestDayRecord] = []
    /// Today's phone and work screen minutes. The Screen Time row follows them.
    var screenTime: ScreenTimeDay?
    /// Today's stretches the player checked by hand. The Stretching row completes when all of them are done.
    var stretchChecks: StretchChecks?
    /// Local day that already spent its one generation attempt, including a failed one.
    var generationAttemptDayKey: String?
    /// Last accepted generated bundle for that day, before the player’s progress.
    var generatedBundle: QuestBundle?
    /// Day that should run as Full Recovery. Set when a token is spent for today.
    var fullRecoveryDayKey: String?
    /// Token spent after today's quests already started. Applied on the next rollover.
    var queuedFullRecoveryDayKey: String?
    /// True after a FamilyActivityPicker save. Tokens themselves stay in the App Group.
    /// Hidden quests the player unlocked, oldest first. One Beyond the Limit per quest day.
    var hiddenUnlocks: [HiddenQuestUnlock] = []
    /// Quest day the player marked "No gym today". Lifts become one added 10K on that day only.
    var noGymDayKey: String?
    /// Quest day whose plan the planner wrote for "No gym today". That plan has no lifts, so "No gym" off drops it.
    var noGymPlanDayKey: String?
    /// Quest day the planner made the week's rest day. `restDue` then locks it to Full Recovery.
    var plannerRestDayKey: String?
    /// The planner's one sentence on why that day rests. The Rest Day shows it as its narrative.
    var plannerRestReason: String?
    /// Quest days the player spent a rest day on, oldest first. `RestDays` sets how many a week may hold.
    var restDayKeys: [String] = []
    /// Earned on perfect days. Spent in `Shop`.
    var gold: Int = 0
    /// Potions used, oldest first. Prices, cooldowns, and stat excuses read this.
    var potionLog: [PotionUse] = []
    /// Gold from the last day that ended. Nil when that day earned none.
    var lastGoldReward: GoldReward?
    /// Nil until the first integration refresh. Then `HitPoints` moves it on every refresh.
    var hitPoints: HitPointState?
    /// Nil until the first integration refresh. Then `Fatigue` moves it on every refresh.
    var fatigue: FatigueState?
    /// The last day that ended with a required quest open, or with a Screen Time row that a Mac can still fail,
    /// until its own data is read once more (see `EndedDay`).
    var endedDay: EndedDay?

    static func fresh(
        catalog: FallbackCatalog,
        now: Date = .now,
        signals: MorningSignals = .placeholder,
        player: PlayerState = .starter,
        readiness: ReadinessSnapshot? = nil
    ) -> GameSnapshot {
        var snapshot = GameSnapshot(version: currentVersion, player: player, signals: signals, bundle: .empty)
        snapshot.readiness = readiness
        snapshot.rebuildBundle(catalog: catalog, now: now)
        return snapshot
    }

    /// New local day swaps in a fallback bundle, then the store may replace it once from generation.
    /// A missed required set opens a penalty unless that day was Full Recovery.
    mutating func refreshIfNeeded(catalog: FallbackCatalog, now: Date = .now) {
        let key = QuestDay.key(for: now)
        // Flying west across midnight moves the local date back. Keep the later day, so it is not judged twice.
        guard key > bundle.dayKey else { return }
        grantHolidayRecovery(previousKey: bundle.dayKey, key: key)
        settleScreenTime()
        awardDayGold()
        recordQuestDay()
        keepEndedDay()
        recordMissedDayIfNeeded()
        let previousTitles = bundle.quests.map(\.title)
        if !previousTitles.isEmpty {
            recentQuestTitles = Array(previousTitles.prefix(8))
        }
        generationAttemptDayKey = nil
        generatedBundle = nil
        // Evidence stops one quest from using another quest's proof on the same day. Older days are never read again.
        evidenceLog.removeAll { $0.dayKey < bundle.dayKey }
        assignQueuedRecovery(on: key)
        rebuildBundle(catalog: catalog, now: now)
        runningTimers.removeAll()
    }

    /// Saves the day that is ending, with each quest's status, and keeps the newest 30 days.
    mutating func recordQuestDay() {
        guard !bundle.quests.isEmpty || bundle.mode == .fullRecovery else { return }
        let quests = Self.questRecords(of: bundle)
        // A token or a rest day spent after the lifts changes the header. The day still trained its split day,
        // so the record keeps it and the split moves on.
        let liftedBeforeRest = bundle.mode == .fullRecovery && quests.contains { $0.stat == .STR && $0.status == .completed }
        let record = QuestDayRecord(
            dayKey: bundle.dayKey,
            mode: bundle.mode,
            trainingBand: trainingBand,
            // The record says "no gym" for a day that held the added 10K, since later run windows take 10 km off such a day.
            // A day whose window already asked for 20 km got no added 10K, so it gives up nothing.
            noGym: noGymDayKey == bundle.dayKey && bundle.mode == .performanceTraining
                && bundle.quests.contains { NoGymDay.isAdded($0, dayKey: bundle.dayKey) },
            splitDay: GymSplit.day(named: bundle.headerLine)?.id
                ?? (liftedBeforeRest ? GymSplit.today(history: questHistory, dayKey: bundle.dayKey).id : nil),
            generatedBy: bundle.generatedBy,
            missedRequired: missesRequiredSet,
            quests: quests
        )
        questHistory.removeAll { $0.dayKey == record.dayKey }
        questHistory.insert(record, at: 0)
        questHistory = Array(questHistory.prefix(QuestDayRecord.keepDays))
    }

    /// The rows of a day as its record keeps them.
    static func questRecords(of bundle: QuestBundle) -> [QuestRecord] {
        bundle.quests.map { quest in
            QuestRecord(
                title: quest.title,
                kind: quest.kind,
                stat: quest.stat,
                method: quest.verification.method,
                params: quest.verification.params,
                target: quest.progress.target,
                done: quest.progress.current,
                unit: quest.progress.unit,
                // A potion skip is not real work, so split rotation and progression ignore it.
                status: quest.skippedWithPotion ? .expired : quest.status
            )
        }
    }

    /// A Screen Time row that stayed under the total cap all day completes as the day ends. The phone's last count comes in first.
    /// A day with no reading at all stays pending: it opens no penalty, but it is no pass and pays no gold.
    mutating func settleScreenTime() {
        if let minutes = PhoneScreenGroup.minutes(for: bundle.dayKey) {
            correctPhoneScreenTime(to: minutes)
            applyScreenTime(phoneMinutes: minutes, workMinutes: nil)
        }
        guard let index = bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId && $0.status == .pending }),
              screenTimeToday.hasReading else { return }
        complete(at: index)
        // The saved row keeps the day's real minutes, not the cap, so the planner reads the true total.
        bundle.quests[index].progress.current = Double(screenTimeToday.totalMinutes)
    }

    /// Incomplete required quests escalate the penalty. A Full Recovery day does not.
    mutating func recordMissedDayIfNeeded() {
        guard missesRequiredSet else { return }
        player.penaltyOpen = true
    }

    /// True when ending the day now would open a penalty.
    var missesRequiredSet: Bool {
        let missed = !bundle.openRequired.isEmpty
        let waived = bundle.mode == .fullRecovery || signals.spendingFullRecovery || fullRecoveryDayKey == bundle.dayKey
        return missed && !waived
    }

    private mutating func assignQueuedRecovery(on key: String) {
        if queuedFullRecoveryDayKey == key {
            signals.spendingFullRecovery = true
            fullRecoveryDayKey = key
            queuedFullRecoveryDayKey = nil
        } else {
            signals.spendingFullRecovery = false
            if fullRecoveryDayKey != key {
                fullRecoveryDayKey = nil
            }
        }
    }

    /// Shown when the quest day on screen is ahead of the local date, after travel west. A rest then waits for the clock.
    static let dayAheadMessage = "The quest day is ahead of the local date. Try again after 5:00."

    /// Spends one banked token. Today always becomes the Full Recovery day; finished work stays done.
    /// A day that ended while the app stayed open is judged first, so a token never hides its miss.
    mutating func spendFullRecovery(catalog: FallbackCatalog, now: Date) -> String {
        refreshIfNeeded(catalog: catalog, now: now)
        let today = QuestDay.key(for: now)
        guard bundle.dayKey == today else { return Self.dayAheadMessage }
        guard player.fullRecoveryBank > 0 else { return "No Full Recovery token in the bank." }
        if signals.spendingFullRecovery || fullRecoveryDayKey == today {
            return "Full Recovery is already assigned for today."
        }
        if isRestDay {
            return "Today is already a rest day. The token stays in the bank."
        }
        player.withdrawRecoveryToken()
        let done = bundle.quests.filter { $0.status == .completed }
        signals.spendingFullRecovery = true
        fullRecoveryDayKey = today
        generatedBundle = nil
        // A rest day has no lifts to swap, so "No gym today" ends here.
        if noGymDayKey == today { noGymDayKey = nil }
        rebuildBundle(catalog: catalog, now: now)
        keepFinished(done)
        return "Full Recovery day assigned. A missed training set will not open a penalty."
    }

    /// Spends one of this week's rest days on today. Finished work stays done, and an unused rest day ends with its week.
    /// A day that ended while the app stayed open is judged first, like `spendFullRecovery`.
    mutating func useRestDay(catalog: FallbackCatalog, now: Date) -> String {
        refreshIfNeeded(catalog: catalog, now: now)
        let today = QuestDay.key(for: now)
        guard bundle.dayKey == today else { return Self.dayAheadMessage }
        guard !player.penaltyOpen else { return "Clear the penalty first." }
        if signals.spendingFullRecovery || fullRecoveryDayKey == today || bundle.mode == .fullRecovery {
            return "Today is already a rest day."
        }
        guard restDaysLeft(on: today) > 0 else { return "No rest days left this week." }
        let done = bundle.quests.filter { $0.status == .completed }
        restDayKeys = Array((restDayKeys + [today]).suffix(RestDays.keepDays))
        generatedBundle = nil
        if noGymDayKey == today { noGymDayKey = nil }
        rebuildBundle(catalog: catalog, now: now)
        keepFinished(done)
        return "Rest day used. \(restDaysLeft(on: today)) left this week."
    }

    /// A row already finished keeps its place and its status; one the rest day does not have goes before Stretching.
    mutating func keepFinished(_ done: [Quest]) {
        for quest in done {
            if let index = bundle.quests.firstIndex(where: { $0.id == quest.id }) {
                bundle.quests[index] = quest
            } else {
                bundle.quests.insert(quest, at: bundle.workoutInsertIndex)
            }
        }
        let ids = Set(bundle.quests.map(\.id))
        runningTimers.removeAll { !ids.contains($0.questId) }
    }

    /// A token an older build queued for tomorrow from today's settings goes to today instead.
    mutating func claimQueuedRecoveryForToday(catalog: FallbackCatalog, now: Date) {
        let today = QuestDay.key(for: now)
        guard bundle.dayKey == today, queuedFullRecoveryDayKey == QuestDay.key(byAddingDays: 1, to: today) else { return }
        queuedFullRecoveryDayKey = nil
        player.depositRecoveryToken()
        _ = spendFullRecovery(catalog: catalog, now: now)
    }

    func verificationContext(
        for quest: Quest,
        now: Date,
        timerElapsed: TimeInterval?,
        userConfirmed: Bool,
        integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    ) -> VerificationContext {
        let others = evidenceLog.filter { $0.dayKey == bundle.dayKey && $0.questId != quest.id }
        let claimed = Set(others.map(\.evidence.reuseKey))
        return VerificationContext(
            now: now,
            dayKey: bundle.dayKey,
            assignedAt: quest.assignedAt,
            manualConfirmsToday: manualConfirmCount(on: bundle.dayKey, excluding: quest.id),
            claimedKeys: claimed,
            timerElapsedSec: timerElapsed,
            userConfirmed: userConfirmed,
            integrations: integrations,
            claimedWorkoutIds: others.reduce(into: Set<String>()) { $0.formUnion($1.evidence.workoutIds) },
            claimedSessions: others.compactMap(\.evidence.session),
            otherExercises: Set(bundle.quests.filter { $0.id != quest.id && $0.verification.method == .hevySets && $0.id != DailyStretch.questId }
                .map { StrengthLevel.normalizedName($0.verification.params["exercise"]?.stringValue ?? $0.title) })
        )
    }

    func manualConfirmCount(on dayKey: String, excluding questId: String) -> Int {
        Set(
            evidenceLog
                .filter {
                    $0.dayKey == dayKey
                        && $0.questId != questId
                        && $0.evidence.source == ManualConfirmVerifier.source
                }
                .map(\.questId)
        ).count
    }

    /// Applies a verifier result. A quest completes only once.
    @discardableResult
    mutating func apply(_ result: VerificationResult, questId: String, now: Date) -> VerificationApply {
        guard let index = bundle.quests.firstIndex(where: { $0.id == questId }) else { return .ignored }
        guard bundle.quests[index].status != .completed else { return .ignored }
        switch result {
        case .unchanged, .incomplete:
            return .ignored
        case .failed(let reason):
            return .rejected(reason)
        case .progress(let current, _):
            var quest = bundle.quests[index]
            let next = min(max(current, quest.progress.current), quest.progress.target)
            guard next != quest.progress.current else { return .ignored }
            quest.progress.current = next
            bundle.quests[index] = quest
            return .updated
        case .completed(let evidence):
            if let reason = rejection(for: evidence, questId: questId) {
                return .rejected(reason)
            }
            var quest = bundle.quests[index]
            if !quest.evidence.contains(where: { $0.payloadHash == evidence.payloadHash }) {
                quest.evidence.append(evidence)
            }
            bundle.quests[index] = quest
            if !evidenceLog.contains(where: { $0.dayKey == bundle.dayKey && $0.questId == questId && $0.evidence.reuseKey == evidence.reuseKey }) {
                evidenceLog.append(EvidenceUse(dayKey: bundle.dayKey, questId: questId, evidence: evidence))
            }
            complete(at: index)
            return .completed
        }
    }

    /// Hand check for the rows that allow one (see `Quest.allowsCheckOff`). Does not pretend to be Strava, WHOOP, or the other live sources.
    @discardableResult
    mutating func applyLocalOverride(questId: String, now: Date) -> VerificationApply {
        guard let quest = bundle.quests.first(where: { $0.id == questId }) else { return .ignored }
        guard quest.allowsCheckOff else { return .ignored }
        let evidence = Evidence.make(
            source: "manual_override",
            externalId: "override:\(quest.id):\(bundle.dayKey)",
            payload: "override|\(quest.id)|\(bundle.dayKey)|\(now.timeIntervalSince1970)",
            timestamp: now
        )
        return apply(.completed(evidence: evidence), questId: questId, now: now)
    }

    /// The WHOOP reading captured on `dayKey`. Nil when the newest reading is from another day.
    func readiness(on dayKey: String) -> ReadinessSnapshot? {
        readiness?.capturedOn == dayKey ? readiness : nil
    }

    /// Picker input from today's reading only. Yesterday's reading never sizes today.
    /// With no reading today the band is green and sleep makes no adjustment, like the planner's default.
    func modeInput(now: Date) -> ModePickerInput {
        let dayKey = QuestDay.key(for: now)
        return Self.modeInput(spendingFullRecovery: signals.spendingFullRecovery, readiness: readiness(on: dayKey), restDue: restDue(on: dayKey))
    }

    static func modeInput(spendingFullRecovery: Bool, readiness: ReadinessSnapshot?, restDue: Bool = false) -> ModePickerInput {
        ModePickerInput(
            spendingFullRecovery: spendingFullRecovery,
            readinessBand: readiness?.band ?? .green,
            sleepPerformance: readiness?.sleepPerformance,
            restDue: restDue
        )
    }

    /// Header of a free rest day. A token day keeps the catalog's "Full Recovery Day".
    static let restDayHeader = "Rest Day"

    private func recordedModes() -> [String: QuestMode] {
        Dictionary(questHistory.map { ($0.dayKey, $0.mode) }, uniquingKeysWith: { first, _ in first })
    }

    /// Quest days trained in a row before `dayKey`: recorded days back from yesterday until a Full Recovery day
    /// or a day the app never saw.
    func trainedDaysInARow(before dayKey: String) -> Int {
        let modes = recordedModes()
        var count = 0
        while count < QuestDayRecord.keepDays, let mode = modes[QuestDay.key(byAddingDays: -(count + 1), to: dayKey)], mode != .fullRecovery {
            count += 1
        }
        return count
    }

    /// Today rests because the player spent a rest day on it. `useRestDay` refuses while a penalty is open.
    /// A penalty that opens later on the rest day waits for the next day, as on a token day, so the rest day is not lost.
    func restDue(on dayKey: String) -> Bool {
        restDayKeys.contains(dayKey)
    }

    /// The player spends rest days, so the planner never makes a day rest.
    func restAvailable(on dayKey: String) -> Bool { false }

    /// Rest days spent in the quest week that holds `dayKey`.
    func restDaysUsed(on dayKey: String) -> Int {
        let week = RestDays.weekKey(of: dayKey)
        return restDayKeys.filter { RestDays.weekKey(of: $0) == week }.count
    }

    /// Rest days still open in the quest week that holds `dayKey`.
    func restDaysLeft(on dayKey: String) -> Int {
        max(RestDays.allowance(on: dayKey) - restDaysUsed(on: dayKey), 0)
    }

    /// Today is a free rest day, not a token day.
    var isRestDay: Bool {
        bundle.mode == .fullRecovery && !signals.spendingFullRecovery && fullRecoveryDayKey != bundle.dayKey && restDue(on: bundle.dayKey)
    }

    /// Offline stand-in for the planner's run window: km logged on the run rows of the six quest days before `dayKey`.
    /// A "No gym today" day gives up its added 10K, like `TrainingHistory.windowKm`.
    func loggedRunKm(before dayKey: String) -> Double {
        let keys = Set((1..<ModePicker.restEveryDays).map { QuestDay.key(byAddingDays: -$0, to: dayKey) })
        return questHistory.filter { keys.contains($0.dayKey) }.reduce(0) { total, day in
            // Finished run rows count in full. Open rows all show the same unfinished run, so it counts one time.
            let runs = day.quests.filter { $0.unit == "km" }
            let km = runs.filter { $0.status == .completed }.reduce(0) { $0 + $1.done }
                + (runs.filter { $0.status != .completed }.map(\.done).max() ?? 0)
            return total + (day.noGym ? max(0, km - Double(TrainingHistory.noGymAddedKm)) : km)
        }
    }

    /// Readiness band that sizes the bundle day's Training quests, after the sleep adjustment.
    var trainingBand: ReadinessBand {
        let today = readiness(on: bundle.dayKey)
        return ModePicker.trainingBand(readiness: today?.band ?? .green, sleepPerformance: today?.sleepPerformance)
    }

    /// Where a save that could not be read is kept, so a new game does not write over the only copy.
    static let unreadableKey = storageKey + ".unreadable"

    static func loadFromUserDefaults() -> GameSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        if let snapshot = try? decoded(data) { return snapshot }
        // The save exists but does not decode. The caller starts a new game and saves it under the same key,
        // so keep these bytes: tokens, gold, and history can then be recovered by hand.
        UserDefaults.standard.set(data, forKey: unreadableKey)
        return nil
    }

    func saveToUserDefaults() {
        guard let data = try? encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    static func decoded(_ data: Data) throws -> GameSnapshot {
        let snapshot = try decoder().decode(GameSnapshot.self, from: data)
        guard snapshot.version == currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported snapshot version"))
        }
        return snapshot
    }

    private func rejection(for evidence: Evidence, questId: String) -> String? {
        if evidence.source == "llm" || evidence.externalId.isEmpty {
            return "Completion has to come from a verifier."
        }
        let workoutIds = evidence.workoutIds
        let session = evidence.session
        let reused = evidenceLog.contains { use in
            guard use.dayKey == bundle.dayKey, use.questId != questId else { return false }
            if use.evidence.reuseKey == evidence.reuseKey || !use.evidence.workoutIds.isDisjoint(with: workoutIds) { return true }
            guard let session, let other = use.evidence.session else { return false }
            return WorkoutDedupe.sameTime(other.start, other.end, session.start, session.end)
        }
        if reused {
            return "That evidence was already used for another quest today."
        }
        return nil
    }

    /// Stores WHOOP recovery as readiness. The REC level comes from `RecoveryLevel`, not from this.
    /// An unavailable reading keeps the old snapshot, but `modeInput` and `trainingBand` only read one captured today.
    /// A quiet morning rebuilds the catalog when the locked mode or the training band changes.
    @discardableResult
    mutating func applyWhoopReadiness(_ reading: WhoopDayReading, catalog: FallbackCatalog, now: Date) -> Bool {
        guard reading.available, let score = reading.recoveryScore else { return false }
        let previousDecision = ModePicker.decide(modeInput(now: now))
        let band = ReadinessBand.from(recoveryScore: score)
        readiness = ReadinessSnapshot(
            recoveryScore: score,
            restingHr: reading.restingHr,
            hrv: reading.hrv,
            sleepPerformance: reading.sleepPerformance,
            band: band,
            capturedOn: reading.dayKey
        )
        let nextDecision = ModePicker.decide(modeInput(now: now))
        let quiet = runningTimers.isEmpty && !bundle.quests.contains { $0.status == .completed }
        guard quiet, nextDecision != previousDecision, bundle.dayKey == QuestDay.key(for: now) else { return false }
        rebuildBundle(catalog: catalog, now: now)
        return true
    }

    /// Stores the day's Mercury summary. The FIN level comes from `FinanceLevel`, not from this.
    mutating func applyFinance(_ reading: MercuryDayReading) {
        guard reading.configured, reading.available, reading.synced else { return }
        finance = FinanceSnapshot(
            dayKey: reading.dayKey,
            discretionarySpendUsd: reading.discretionarySpendUsd,
            necessarySpendUsd: reading.necessarySpendUsd,
            capUsd: reading.capUsd,
            discretionary7dUsd: reading.discretionary7dUsd,
            paceState: reading.paceState,
            ytdIncomeUsd: reading.ytdIncomeUsd,
            ytdGoalUsd: reading.ytdGoalUsd,
            settled: reading.settled
        )
    }

    mutating func rebuildBundle(catalog: FallbackCatalog, now: Date) {
        let decision = ModePicker.decide(modeInput(now: now))
        let dayKey = QuestDay.key(for: now)
        if let cached = generatedBundle,
           cached.dayKey == dayKey,
           cached.mode == decision.selectedMode,
           let allowed = TrainingDay.exerciseOnly(cached) {
            bundle = finished(allowed.strippingModelCompletion(assignedAt: now), catalog: catalog, now: now)
            return
        }
        let catalogDay = catalog.makeBundle(
            mode: decision.selectedMode,
            band: decision.trainingBand,
            dayKey: dayKey,
            now: now
        )
        // Offline, the day still follows the split: its exercises without loads.
        let today = GymSplit.today(history: questHistory, dayKey: dayKey, goals: catalog.strengthGoals)
        var split = GymSplit.apply(today, to: catalogDay, band: decision.trainingBand, now: now)
        // The 50 km window is already full: a rest day from running. The lifts stay.
        // On a "No gym today" day `finished` then adds the one 10K that never counts.
        if decision.selectedMode == .performanceTraining, loggedRunKm(before: dayKey) >= Double(TrainingDay.runKmPer7Days) {
            split.quests.removeAll { $0.kind != .penalty && TrainingDay.isRaceRun($0) }
        }
        bundle = finished(split, catalog: catalog, now: now)
    }

    /// Adds the fixed rows: Screen Time, Stretching unless it is a spent rest day, then any open penalty.
    /// On a "No gym today" day, the lifts first give way to a second 10K. A day holds at most two workouts.
    func finished(_ bundle: QuestBundle, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        var day = GymSplit.cappingSets(TrainingDay.cappingWorkouts(noGymDayKey == bundle.dayKey ? NoGymDay.cardioOnly(bundle, now: now) : bundle))
        let restDay = day.mode == .fullRecovery && !signals.spendingFullRecovery && fullRecoveryDayKey != day.dayKey && restDue(on: day.dayKey)
        if restDay {
            day.headerLine = Self.restDayHeader
            day.narrative = ""
        }
        let screen = ScreenTime.ensure(in: day, now: now)
        let stretch = StretchSplit.today(history: questHistory, dayKey: day.dayKey)
        return PenaltyQuests.ensure(
            in: measured(restDay ? screen : DailyStretch.ensure(in: screen, now: now, day: stretch)),
            open: player.penaltyOpen,
            band: trainingBand,
            catalog: catalog,
            now: now
        )
    }

    /// A day that is built again gets new Screen Time and Stretching rows. They take the day's saved readings and
    /// hand checks at once, so a count, a failure, or a checked stretch is not lost until the next reading.
    private func measured(_ bundle: QuestBundle) -> QuestBundle {
        var copy = bundle
        if let day = screenTime, day.dayKey == copy.dayKey, day.hasReading,
           let index = copy.quests.firstIndex(where: { $0.id == ScreenTime.questId && $0.status != .completed }) {
            copy.quests[index].progress.current = Double(day.totalMinutes)
            if day.overTotal, copy.quests[index].status == .pending { copy.quests[index].status = .failed }
        }
        if let checks = stretchChecks, checks.dayKey == copy.dayKey,
           let index = copy.quests.firstIndex(where: { $0.id == DailyStretch.questId && $0.status == .pending }),
           let day = StretchSplit.day(of: copy.quests[index]) {
            let minutes = day.stretches.filter { checks.names.contains($0.name) }.reduce(0) { $0 + $1.minutes }
            let row = copy.quests[index].progress
            copy.quests[index].progress.current = max(row.current, min(minutes, row.target))
        }
        return copy
    }

    /// Marks the row done. Nothing is granted here: the levels come from the real histories,
    /// and Full Recovery tokens come only from `RecoveryHolidays`.
    private mutating func complete(at index: Int) {
        var quest = bundle.quests[index]
        guard quest.status != .completed else { return }
        quest.status = .completed
        quest.progress.current = quest.progress.target
        bundle.quests[index] = quest
        // Only the penalty run closes a penalty. On a rest day the bundle can hold just an old finished penalty row
        // while a new penalty waits; another row that completes must not close that one.
        if quest.kind == .penalty { liftPenaltyIfCleared() }
    }

    /// Every penalty row is done. The penalty closes.
    private mutating func liftPenaltyIfCleared() {
        guard PenaltyQuests.isCleared(in: bundle), player.penaltyOpen else { return }
        player.penaltyOpen = false
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension GameSnapshot {
    private enum CodingKeys: String, CodingKey {
        case version, player, signals, bundle, evidenceLog, runningTimers
        case recentQuestTitles, generationAttemptDayKey, generatedBundle, readiness
        case finance, monthlyPenaltyMonth
        case fullRecoveryDayKey, queuedFullRecoveryDayKey
        case hiddenUnlocks
        case noGymDayKey, noGymPlanDayKey, plannerRestDayKey, plannerRestReason, restDayKeys
        case questHistory, screenTime, stretchChecks
        case gold, potionLog, lastGoldReward
        case hitPoints, fatigue, endedDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        player = try container.decode(PlayerState.self, forKey: .player)
        signals = try container.decode(MorningSignals.self, forKey: .signals)
        bundle = try container.decode(QuestBundle.self, forKey: .bundle)
        evidenceLog = try container.decodeIfPresent([EvidenceUse].self, forKey: .evidenceLog) ?? []
        runningTimers = try container.decodeIfPresent([TimerRun].self, forKey: .runningTimers) ?? []
        recentQuestTitles = try container.decodeIfPresent([String].self, forKey: .recentQuestTitles) ?? []
        readiness = try container.decodeIfPresent(ReadinessSnapshot.self, forKey: .readiness)
        finance = try container.decodeIfPresent(FinanceSnapshot.self, forKey: .finance)
        monthlyPenaltyMonth = try container.decodeIfPresent(String.self, forKey: .monthlyPenaltyMonth)
        fullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .fullRecoveryDayKey)
        queuedFullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .queuedFullRecoveryDayKey)
        hiddenUnlocks = try container.decodeIfPresent(LossyArray<HiddenQuestUnlock>.self, forKey: .hiddenUnlocks)?.elements ?? []
        noGymDayKey = try container.decodeIfPresent(String.self, forKey: .noGymDayKey)
        noGymPlanDayKey = try container.decodeIfPresent(String.self, forKey: .noGymPlanDayKey)
        plannerRestDayKey = try container.decodeIfPresent(String.self, forKey: .plannerRestDayKey)
        plannerRestReason = try container.decodeIfPresent(String.self, forKey: .plannerRestReason)
        restDayKeys = try container.decodeIfPresent([String].self, forKey: .restDayKeys) ?? []
        generationAttemptDayKey = try container.decodeIfPresent(String.self, forKey: .generationAttemptDayKey)
        generatedBundle = try container.decodeIfPresent(QuestBundle.self, forKey: .generatedBundle)
        questHistory = try container.decodeIfPresent(LossyArray<QuestDayRecord>.self, forKey: .questHistory)?.elements ?? []
        screenTime = try container.decodeIfPresent(ScreenTimeDay.self, forKey: .screenTime)
        stretchChecks = try container.decodeIfPresent(StretchChecks.self, forKey: .stretchChecks)
        gold = try container.decodeIfPresent(Int.self, forKey: .gold) ?? 0
        potionLog = try container.decodeIfPresent(LossyArray<PotionUse>.self, forKey: .potionLog)?.elements ?? []
        lastGoldReward = try container.decodeIfPresent(GoldReward.self, forKey: .lastGoldReward)
        hitPoints = try container.decodeIfPresent(HitPointState.self, forKey: .hitPoints)
        fatigue = try container.decodeIfPresent(FatigueState.self, forKey: .fatigue)
        endedDay = try container.decodeIfPresent(EndedDay.self, forKey: .endedDay)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(player, forKey: .player)
        try container.encode(signals, forKey: .signals)
        try container.encode(bundle, forKey: .bundle)
        try container.encode(evidenceLog, forKey: .evidenceLog)
        try container.encode(runningTimers, forKey: .runningTimers)
        try container.encode(recentQuestTitles, forKey: .recentQuestTitles)
        try container.encodeIfPresent(readiness, forKey: .readiness)
        try container.encodeIfPresent(finance, forKey: .finance)
        try container.encodeIfPresent(monthlyPenaltyMonth, forKey: .monthlyPenaltyMonth)
        try container.encodeIfPresent(fullRecoveryDayKey, forKey: .fullRecoveryDayKey)
        try container.encodeIfPresent(queuedFullRecoveryDayKey, forKey: .queuedFullRecoveryDayKey)
        try container.encode(hiddenUnlocks, forKey: .hiddenUnlocks)
        try container.encodeIfPresent(noGymDayKey, forKey: .noGymDayKey)
        try container.encodeIfPresent(noGymPlanDayKey, forKey: .noGymPlanDayKey)
        try container.encodeIfPresent(plannerRestDayKey, forKey: .plannerRestDayKey)
        try container.encodeIfPresent(plannerRestReason, forKey: .plannerRestReason)
        try container.encodeIfPresent(stretchChecks, forKey: .stretchChecks)
        try container.encode(restDayKeys, forKey: .restDayKeys)
        try container.encode(questHistory, forKey: .questHistory)
        try container.encodeIfPresent(screenTime, forKey: .screenTime)
        try container.encodeIfPresent(generationAttemptDayKey, forKey: .generationAttemptDayKey)
        try container.encodeIfPresent(generatedBundle, forKey: .generatedBundle)
        try container.encode(gold, forKey: .gold)
        try container.encode(potionLog, forKey: .potionLog)
        try container.encodeIfPresent(lastGoldReward, forKey: .lastGoldReward)
        try container.encodeIfPresent(hitPoints, forKey: .hitPoints)
        try container.encodeIfPresent(fatigue, forKey: .fatigue)
        try container.encodeIfPresent(endedDay, forKey: .endedDay)
    }
}

extension QuestBundle {
    static let empty = QuestBundle(
        schemaVersion: 1,
        dayKey: "",
        mode: .performanceTraining,
        headerLine: QuestMode.performanceTraining.headerLine,
        narrative: "",
        quests: [],
        warnings: [QuestBundle.defaultWarning],
        generatedBy: "fallback"
    )
}

/// A day that is built again keeps what was measured: the screen time count, its failure, and the checked stretches.
enum RebuiltRowRules {
    static func check() -> [String] {
        var errors: [String] = []
        let catalog = FallbackCatalog.bundled()
        guard let now = QuestDay.start(of: "2026-10-05")?.addingTimeInterval(3_600) else { return ["could not build rebuild dates"] }
        func row(_ snapshot: GameSnapshot, _ id: String) -> Quest? { snapshot.bundle.quests.first { $0.id == id } }

        var day = GameSnapshot.fresh(catalog: catalog, now: now)
        day.applyScreenTime(phoneMinutes: 120, workMinutes: 200)
        if let stretch = row(day, DailyStretch.questId).flatMap({ StretchSplit.day(of: $0) })?.stretches.first {
            day.toggleStretch(stretch.name, doneInHevy: [])
        }
        let stretched = row(day, DailyStretch.questId)?.progress.current
        day.rebuildBundle(catalog: catalog, now: now)
        if row(day, ScreenTime.questId)?.progress.current != 200 || row(day, DailyStretch.questId)?.progress.current != stretched || stretched == 0 {
            errors.append("a rebuilt day should keep its screen time count and its checked stretches")
        }
        // A failed Screen Time row stays failed, so the day cannot pass with no new reading.
        day.applyScreenTime(phoneMinutes: nil, workMinutes: ScreenTime.failAfterMinutes + 1)
        day.rebuildBundle(catalog: catalog, now: now)
        if row(day, ScreenTime.questId)?.status != .failed { errors.append("a rebuilt day should keep a failed Screen Time row") }

        // The day's record keeps the real minutes of a Screen Time row that passed, not the cap.
        var passed = GameSnapshot.fresh(catalog: catalog, now: now)
        passed.applyScreenTime(phoneMinutes: 120, workMinutes: 200)
        passed.refreshIfNeeded(catalog: catalog, now: now.addingTimeInterval(86_400))
        if ContextBuilder.screenMinutesYesterday(snapshot: passed, dayKey: passed.bundle.dayKey) != 200 {
            errors.append("the record should keep yesterday's real screen minutes")
        }
        return errors
    }
}

/// An array that drops the elements it cannot decode. One history row from a newer or an older build (a quest kind,
/// a stat, or a potion that no longer exists) then costs that row, not the whole save.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(JSONValue.self)) == nil {
                // The element cannot even be passed over: stop here and keep what was read.
                break
            }
        }
    }
}
