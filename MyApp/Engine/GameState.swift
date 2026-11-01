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
    /// Rolling recovery-capacity placeholder. The radar REC stat stays XP-driven.
    /// Mercury aggregates for the quest day. Not a dollar balance.
    var finance: FinanceSnapshot?
    /// Titles from the previous quest day. Sent as summaries, never as evidence.
    var recentQuestTitles: [String] = []
    /// Past quest days as they ended, newest first, at most 30. The generator reads them.
    var questHistory: [QuestDayRecord] = []
    /// Today's phone and work screen minutes. The Screen Time row follows them.
    var screenTime: ScreenTimeDay?
    /// Local day that already spent its one generation attempt, including a failed one.
    var generationAttemptDayKey: String?
    /// Last accepted generated bundle for that day, before the player’s progress.
    var generatedBundle: QuestBundle?
    /// Day that should run as Full Recovery. Set when a token is spent for today.
    var fullRecoveryDayKey: String?
    /// Token spent after today's quests already started. Applied on the next rollover.
    var queuedFullRecoveryDayKey: String?
    /// True after a FamilyActivityPicker save. Tokens themselves stay in the App Group.
    var hasDistractorSelection: Bool = false
    /// Hidden quests the player unlocked, oldest first. One Beyond the Limit per quest day.
    var hiddenUnlocks: [HiddenQuestUnlock] = []
    /// A real emergency quest failed on this day. Ending the day then opens a penalty.
    var emergencyFailedDayKey: String?
    /// Quest day the player marked "No gym today". Lifts become one added 10K on that day only.
    var noGymDayKey: String?
    /// Quest day the planner made the week's rest day. `restDue` then locks it to Full Recovery.
    var plannerRestDayKey: String?
    /// The planner's one sentence on why that day rests. The Rest Day shows it as its narrative.
    var plannerRestReason: String?
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
    /// A missed required set raises `penaltyTier` (1...3) unless that day was Full Recovery.
    mutating func refreshIfNeeded(catalog: FallbackCatalog, now: Date = .now) {
        let key = QuestDay.key(for: now)
        // Flying west across midnight moves the local date back. Keep the later day, so it is not judged twice.
        guard key > bundle.dayKey else { return }
        grantHolidayRecovery(previousKey: bundle.dayKey, key: key)
        settleScreenTime()
        awardDayGold()
        recordQuestDay()
        recordMissedDayIfNeeded()
        let previousTitles = bundle.quests.map(\.title)
        if !previousTitles.isEmpty {
            recentQuestTitles = Array(previousTitles.prefix(8))
        }
        generationAttemptDayKey = nil
        generatedBundle = nil
        assignQueuedRecovery(on: key)
        rebuildBundle(catalog: catalog, now: now)
        runningTimers.removeAll()
    }

    /// Saves the day that is ending, with each quest's status, and keeps the newest 30 days.
    mutating func recordQuestDay() {
        guard !bundle.quests.isEmpty else { return }
        let record = QuestDayRecord(
            dayKey: bundle.dayKey,
            mode: bundle.mode,
            trainingBand: trainingBand,
            noGym: noGymDayKey == bundle.dayKey,
            splitDay: GymSplit.day(named: bundle.headerLine)?.id,
            generatedBy: bundle.generatedBy,
            missedRequired: missesRequiredSet,
            quests: bundle.quests.map { quest in
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
        )
        questHistory.removeAll { $0.dayKey == record.dayKey }
        questHistory.insert(record, at: 0)
        questHistory = Array(questHistory.prefix(QuestDayRecord.keepDays))
    }

    /// A Screen Time row that stayed under the total cap all day completes as the day ends, with its XP.
    mutating func settleScreenTime() {
        guard let index = bundle.quests.firstIndex(where: { $0.id == ScreenTime.questId && $0.status == .pending }) else { return }
        complete(at: index)
    }

    /// Incomplete required quests escalate the penalty. A Full Recovery day does not.
    mutating func recordMissedDayIfNeeded() {
        guard missesRequiredSet else { return }
        player.penaltyTier = min(3, player.penaltyTier + 1)
    }

    /// True when ending the day now would raise the penalty tier.
    var missesRequiredSet: Bool {
        let required = bundle.quests.filter { $0.kind != .optional }
        // A Screen Time row still under its cap holds until the day ends; only a failed one is a miss.
        let open = required.filter { $0.status != .completed && !($0.id == ScreenTime.questId && $0.status == .pending) }
        let missed = !open.isEmpty
            || emergencyFailedDayKey == bundle.dayKey
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

    /// Spends one banked token. A quiet morning switches today; a day already in progress is queued.
    mutating func spendFullRecovery(catalog: FallbackCatalog, now: Date) -> String {
        let today = QuestDay.key(for: now)
        guard player.fullRecoveryBank > 0 else { return "No Full Recovery token in the bank." }
        if signals.spendingFullRecovery || fullRecoveryDayKey == today {
            return "Full Recovery is already assigned for today."
        }
        if bundle.dayKey == today, isRestDay {
            return "Today is already a rest day. The token stays in the bank."
        }
        if queuedFullRecoveryDayKey != nil {
            return "A Full Recovery day is already queued."
        }
        player.withdrawRecoveryToken()
        let quiet = runningTimers.isEmpty && !bundle.quests.contains { $0.status == .completed }
        if quiet {
            signals.spendingFullRecovery = true
            fullRecoveryDayKey = today
            generatedBundle = nil
            rebuildBundle(catalog: catalog, now: now)
            return "Full Recovery day assigned. A missed training set will not open a penalty."
        }
        queuedFullRecoveryDayKey = QuestDay.key(byAddingDays: 1, to: today)
        return "Queued for tomorrow. Today's finished work stays."
    }

    func verificationContext(
        for quest: Quest,
        now: Date,
        timerElapsed: TimeInterval?,
        userConfirmed: Bool,
        integrations: DayIntegrationSnapshot = .empty(dayKey: "")
    ) -> VerificationContext {
        let claimed = Set(
            evidenceLog
                .filter { $0.dayKey == bundle.dayKey && $0.questId != quest.id }
                .map(\.evidence.reuseKey)
        )
        return VerificationContext(
            now: now,
            dayKey: bundle.dayKey,
            assignedAt: quest.assignedAt,
            manualConfirmsToday: manualConfirmCount(on: bundle.dayKey, excluding: quest.id),
            claimedKeys: claimed,
            timerElapsedSec: timerElapsed,
            userConfirmed: userConfirmed,
            integrations: integrations
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

    /// Local checkbox for adapters that are still stubs. Does not pretend to be Strava, WHOOP, or the other live sources.
    @discardableResult
    mutating func applyLocalOverride(questId: String, now: Date) -> VerificationApply {
        guard let quest = bundle.quests.first(where: { $0.id == questId }) else { return .ignored }
        guard quest.verification.method.allowsLocalCheckbox else { return .ignored }
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

    /// Header of the free weekly rest day. A token day keeps the catalog's "Full Recovery Day".
    static let restDayHeader = "Rest Day"
    /// Narrative of the forced seventh day, and of a picked day with no reason on record.
    static let forcedRestNarrative = "The seventh day. Training is waived; the body does the work."
    static let pickedRestNarrative = "The System calls a rest. Training is waived; the body does the work."

    /// What the Rest Day says under its header: the planner's reason on its picked day, else the fixed line.
    func restDayNarrative(on dayKey: String) -> String {
        guard plannerRestDayKey == dayKey else { return Self.forcedRestNarrative }
        let reason = plannerRestReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? Self.pickedRestNarrative : reason
    }

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

    /// A Full Recovery day (a token, a forced rest, or the planner's pick) sits in the six quest days before `dayKey`.
    func restTaken(before dayKey: String) -> Bool {
        let modes = recordedModes()
        return (1..<ModePicker.restEveryDays).contains { modes[QuestDay.key(byAddingDays: -$0, to: dayKey)] == .fullRecovery }
    }

    /// Today rests: the planner picked it, or six quest days trained in a row and the seventh is forced.
    /// An open penalty is served first: no rest day while the tier is above 0.
    func restDue(on dayKey: String) -> Bool {
        guard player.penaltyTier == 0 else { return false }
        return plannerRestDayKey == dayKey || trainedDaysInARow(before: dayKey) >= ModePicker.restEveryDays - 1
    }

    /// The planner may make `dayKey` the rest day: no penalty, no rest in the last six days, not already forced,
    /// and at least `ModePicker.restMinTrainedDays` trained days behind it, so two rests never touch.
    func restAvailable(on dayKey: String) -> Bool {
        player.penaltyTier == 0 && !restDue(on: dayKey) && !restTaken(before: dayKey)
            && trainedDaysInARow(before: dayKey) >= ModePicker.restMinTrainedDays
    }

    /// Today is the free weekly rest day, not a token day.
    var isRestDay: Bool {
        bundle.mode == .fullRecovery && !signals.spendingFullRecovery && fullRecoveryDayKey != bundle.dayKey && restDue(on: bundle.dayKey)
    }

    /// Offline stand-in for the planner's run window: km logged on the run rows of the six quest days before `dayKey`.
    /// A "No gym today" day gives up its added 10K, like `TrainingHistory.windowKm`.
    func loggedRunKm(before dayKey: String) -> Double {
        let keys = Set((1..<ModePicker.restEveryDays).map { QuestDay.key(byAddingDays: -$0, to: dayKey) })
        return questHistory.filter { keys.contains($0.dayKey) }.reduce(0) { total, day in
            let km = day.quests.filter { $0.unit == "km" }.reduce(0) { $0 + $1.done }
            return total + (day.noGym ? max(0, km - Double(TrainingHistory.noGymAddedKm)) : km)
        }
    }

    /// Readiness band that sizes the bundle day's Training quests, after the sleep adjustment.
    var trainingBand: ReadinessBand {
        let today = readiness(on: bundle.dayKey)
        return ModePicker.trainingBand(readiness: today?.band ?? .green, sleepPerformance: today?.sleepPerformance)
    }

    static func loadFromUserDefaults() -> GameSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? decoded(data)
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
        let reused = evidenceLog.contains {
            $0.dayKey == bundle.dayKey && $0.questId != questId && $0.evidence.reuseKey == evidence.reuseKey
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

    /// Adds the fixed rows every day gets: Stretching, then any open penalty.
    /// On a "No gym today" day, the lifts first give way to a second 10K.
    func finished(_ bundle: QuestBundle, catalog: FallbackCatalog, now: Date) -> QuestBundle {
        var day = noGymDayKey == bundle.dayKey ? NoGymDay.cardioOnly(bundle, now: now) : bundle
        if day.mode == .fullRecovery, !signals.spendingFullRecovery, fullRecoveryDayKey != day.dayKey, restDue(on: day.dayKey) {
            day.headerLine = Self.restDayHeader
            day.narrative = restDayNarrative(on: day.dayKey)
        }
        return PenaltyQuests.ensure(
            in: DailyStretch.ensure(in: ScreenTime.ensure(in: day, now: now), now: now),
            tier: player.penaltyTier,
            band: trainingBand,
            catalog: catalog,
            now: now
        )
    }

    /// Marks the row done. Nothing is granted here: the levels come from the real histories,
    /// and Full Recovery tokens come only from `RecoveryHolidays`.
    private mutating func complete(at index: Int) {
        var quest = bundle.quests[index]
        guard quest.status != .completed else { return }
        quest.status = .completed
        quest.progress.current = quest.progress.target
        bundle.quests[index] = quest
        liftPenaltyIfCleared()
    }

    /// Every penalty row is done. Tier drops to 0.
    private mutating func liftPenaltyIfCleared() {
        guard PenaltyQuests.isCleared(in: bundle), player.penaltyTier > 0 else { return }
        player.penaltyTier = 0
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
        case finance
        case fullRecoveryDayKey, queuedFullRecoveryDayKey, hasDistractorSelection
        case hiddenUnlocks
        case emergencyFailedDayKey, noGymDayKey, plannerRestDayKey, plannerRestReason
        case questHistory, screenTime
        case gold, potionLog, lastGoldReward
        case hitPoints, fatigue
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
        fullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .fullRecoveryDayKey)
        queuedFullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .queuedFullRecoveryDayKey)
        hasDistractorSelection = try container.decodeIfPresent(Bool.self, forKey: .hasDistractorSelection) ?? false
        hiddenUnlocks = try container.decodeIfPresent([HiddenQuestUnlock].self, forKey: .hiddenUnlocks) ?? []
        emergencyFailedDayKey = try container.decodeIfPresent(String.self, forKey: .emergencyFailedDayKey)
        noGymDayKey = try container.decodeIfPresent(String.self, forKey: .noGymDayKey)
        plannerRestDayKey = try container.decodeIfPresent(String.self, forKey: .plannerRestDayKey)
        plannerRestReason = try container.decodeIfPresent(String.self, forKey: .plannerRestReason)
        generationAttemptDayKey = try container.decodeIfPresent(String.self, forKey: .generationAttemptDayKey)
        generatedBundle = try container.decodeIfPresent(QuestBundle.self, forKey: .generatedBundle)
        questHistory = try container.decodeIfPresent([QuestDayRecord].self, forKey: .questHistory) ?? []
        screenTime = try container.decodeIfPresent(ScreenTimeDay.self, forKey: .screenTime)
        gold = try container.decodeIfPresent(Int.self, forKey: .gold) ?? 0
        potionLog = try container.decodeIfPresent([PotionUse].self, forKey: .potionLog) ?? []
        lastGoldReward = try container.decodeIfPresent(GoldReward.self, forKey: .lastGoldReward)
        hitPoints = try container.decodeIfPresent(HitPointState.self, forKey: .hitPoints)
        fatigue = try container.decodeIfPresent(FatigueState.self, forKey: .fatigue)
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
        try container.encodeIfPresent(fullRecoveryDayKey, forKey: .fullRecoveryDayKey)
        try container.encodeIfPresent(queuedFullRecoveryDayKey, forKey: .queuedFullRecoveryDayKey)
        try container.encode(hasDistractorSelection, forKey: .hasDistractorSelection)
        try container.encode(hiddenUnlocks, forKey: .hiddenUnlocks)
        try container.encodeIfPresent(emergencyFailedDayKey, forKey: .emergencyFailedDayKey)
        try container.encodeIfPresent(noGymDayKey, forKey: .noGymDayKey)
        try container.encodeIfPresent(plannerRestDayKey, forKey: .plannerRestDayKey)
        try container.encodeIfPresent(plannerRestReason, forKey: .plannerRestReason)
        try container.encode(questHistory, forKey: .questHistory)
        try container.encodeIfPresent(screenTime, forKey: .screenTime)
        try container.encodeIfPresent(generationAttemptDayKey, forKey: .generationAttemptDayKey)
        try container.encodeIfPresent(generatedBundle, forKey: .generatedBundle)
        try container.encode(gold, forKey: .gold)
        try container.encode(potionLog, forKey: .potionLog)
        try container.encodeIfPresent(lastGoldReward, forKey: .lastGoldReward)
        try container.encodeIfPresent(hitPoints, forKey: .hitPoints)
        try container.encodeIfPresent(fatigue, forKey: .fatigue)
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
