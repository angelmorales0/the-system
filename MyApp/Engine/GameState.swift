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
    var recoveryComposite: RecoveryComposite = RecoveryComposite()
    /// Mercury aggregates for the quest day. Not a dollar balance.
    var finance: FinanceSnapshot?
    /// FIN points already added from `FinanceProjection`. Quest grants sit on top of this.
    var appliedFinProjection: Int = 0
    /// Titles from the previous quest day. Sent as summaries, never as evidence.
    var recentQuestTitles: [String] = []
    /// Local day that already spent its one generation attempt, including a failed one.
    var generationAttemptDayKey: String?
    /// Last accepted generated bundle for that day, before the player’s progress.
    var generatedBundle: QuestBundle?
    /// Day that should run as Full Recovery. Set when a token is spent for today.
    var fullRecoveryDayKey: String?
    /// Token spent after today's quests already started. Applied on the next rollover.
    var queuedFullRecoveryDayKey: String?
    /// Tier restored if a cleared penalty quest is undone the same day.
    var heldPenaltyTier: Int = 0
    /// True after a FamilyActivityPicker save. Tokens themselves stay in the App Group.
    var hasDistractorSelection: Bool = false
    /// Hidden quests the player unlocked, oldest first. One Beyond the Limit per quest day.
    var hiddenUnlocks: [HiddenQuestUnlock] = []
    /// A real emergency quest failed on this day. Ending the day then opens a penalty.
    var emergencyFailedDayKey: String?

    static func fresh(
        catalog: FallbackCatalog,
        now: Date = .now,
        signals: MorningSignals = .placeholder,
        player: PlayerState = .starter
    ) -> GameSnapshot {
        var snapshot = GameSnapshot(version: currentVersion, player: player, signals: signals, bundle: .empty)
        snapshot.rebuildBundle(catalog: catalog, now: now)
        return snapshot
    }

    /// New local day swaps in a fallback bundle, then the store may replace it once from generation.
    /// A missed required set raises `penaltyTier` (1...3) unless that day was Full Recovery.
    mutating func refreshIfNeeded(catalog: FallbackCatalog, now: Date = .now) {
        let key = QuestDay.key(for: now)
        // Flying west across midnight moves the local date back. Keep the later day, so it is not judged twice.
        guard key > bundle.dayKey else { return }
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

    /// Incomplete required quests escalate the penalty. A Full Recovery day does not.
    mutating func recordMissedDayIfNeeded() {
        guard missesRequiredSet else { return }
        player.penaltyTier = min(3, player.penaltyTier + 1)
    }

    /// True when ending the day now would raise the penalty tier.
    var missesRequiredSet: Bool {
        let required = bundle.quests.filter { $0.kind != .optional }
        let missed = (!required.isEmpty && required.contains { $0.status != .completed })
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

    /// Applies a verifier result. XP is granted only from `.completed`, and only once.
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

    mutating func undoQuest(id: String) {
        guard let index = bundle.quests.firstIndex(where: { $0.id == id }) else { return }
        guard bundle.quests[index].status == .completed else { return }
        undoCompletion(at: index)
        restorePenaltyIfNeeded()
        // Manual confirms stay in the log so undo cannot refund the 3-per-day cap.
        evidenceLog.removeAll { $0.questId == id && $0.evidence.source != ManualConfirmVerifier.source }
        runningTimers.removeAll { $0.questId == id }
        var quest = bundle.quests[index]
        quest.evidence = []
        bundle.quests[index] = quest
    }

    static func xpGrant(for quest: Quest, mode: QuestMode) -> Int {
        var amount = quest.xp
        if mode == .penalty {
            // Once, from the quest's own XP. Callers must not run this on an already taxed grant.
            amount = max(1, Int((Double(quest.xp) * 0.9).rounded()))
        }
        if quest.reward?.type == .xpBonus {
            amount += max(0, quest.reward?.amount ?? 0)
        }
        return amount
    }

    func modeInput(now: Date) -> ModePickerInput {
        ModePickerInput(
            penaltyTier: player.penaltyTier,
            spendingFullRecovery: signals.spendingFullRecovery,
            isSunday: QuestDay.isSunday(now),
            readinessBand: signals.readinessBand,
            sleepPerformance: signals.sleepPerformance,
            calendarBusyMinutes: signals.calendarBusyMinutes
        )
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

    /// Stores WHOOP recovery as readiness. Does not write `player.stats.REC`.
    /// A quiet morning rebuilds the catalog when the locked mode changes.
    @discardableResult
    mutating func applyWhoopReadiness(_ reading: WhoopDayReading, catalog: FallbackCatalog, now: Date) -> Bool {
        guard reading.available, let score = reading.recoveryScore else { return false }
        let previousREC = player.stats.REC
        let previousMode = bundle.mode
        let band = ReadinessBand.from(recoveryScore: score)
        readiness = ReadinessSnapshot(
            recoveryScore: score,
            restingHr: reading.restingHr,
            hrv: reading.hrv,
            sleepPerformance: reading.sleepPerformance,
            band: band,
            capturedOn: reading.dayKey
        )
        signals.readinessBand = band
        if let sleep = reading.sleepPerformance {
            signals.sleepPerformance = sleep
        }
        recoveryComposite.record(score: score, on: reading.dayKey)
        player.stats.REC = previousREC
        let nextMode = ModePicker.decide(modeInput(now: now)).selectedMode
        let quiet = runningTimers.isEmpty && !bundle.quests.contains { $0.status == .completed }
        guard quiet, nextMode != previousMode, bundle.dayKey == QuestDay.key(for: now) else { return false }
        rebuildBundle(catalog: catalog, now: now)
        return true
    }

    /// Moves the FIN radar by the projection delta. Does not replace FIN with a balance or a dollar total.
    mutating func applyFinance(_ reading: MercuryDayReading) {
        guard reading.configured, reading.available, reading.synced else { return }
        let previousREC = player.stats.REC
        let points = FinanceProjection.points(
            pace: reading.paceState,
            ytdIncomeUsd: reading.ytdIncomeUsd,
            ytdGoalUsd: reading.ytdGoalUsd
        )
        let delta = points - appliedFinProjection
        if delta != 0 {
            // Track only the points that really moved FIN, so the stat cap cannot make a later drop remove quest points.
            let before = player.stats.FIN
            player.stats.FIN = min(StatValues.maximum, max(0, before + delta))
            appliedFinProjection += player.stats.FIN - before
        }
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
        player.stats.REC = previousREC
    }

    mutating func rebuildBundle(catalog: FallbackCatalog, now: Date) {
        let decision = ModePicker.decide(modeInput(now: now))
        let dayKey = QuestDay.key(for: now)
        if let cached = generatedBundle,
           cached.dayKey == dayKey,
           cached.mode == decision.selectedMode,
           let allowed = TrainingDay.exerciseOnly(cached) {
            bundle = DailyStretch.ensure(in: allowed.strippingModelCompletion(assignedAt: now), now: now)
            return
        }
        bundle = DailyStretch.ensure(in: catalog.makeBundle(
            mode: decision.selectedMode,
            band: signals.readinessBand,
            dayKey: dayKey,
            now: now
        ), now: now)
    }

    private mutating func complete(at index: Int) {
        var quest = bundle.quests[index]
        guard quest.status != .completed else { return }
        let xpGain = Self.xpGrant(for: quest, mode: bundle.mode)
        // Only the points under the cap are granted, so undo removes exactly what was added.
        let statGain = min(quest.difficulty.statWeight, player.stats.room(for: quest.stat))
        player.addXP(xpGain)
        player.stats[quest.stat] += statGain
        var grantedToken = false
        if quest.kind == .optional && quest.reward?.type == .fullRecoveryToken {
            grantedToken = player.depositRecoveryToken()
        }
        quest.grantedXP = xpGain
        quest.grantedStatPoints = statGain
        quest.grantedRecoveryToken = grantedToken
        quest.status = .completed
        quest.progress.current = quest.progress.target
        bundle.quests[index] = quest
        liftPenaltyIfCleared()
    }

    /// Every required penalty row is done. Tier drops to 0. The 0.9× XP tax already applied at grant time.
    private mutating func liftPenaltyIfCleared() {
        guard bundle.mode == .penalty else { return }
        let required = bundle.quests.filter { $0.kind != .optional }
        guard !required.isEmpty, required.allSatisfy({ $0.status == .completed }) else { return }
        guard player.penaltyTier > 0 else { return }
        heldPenaltyTier = player.penaltyTier
        player.penaltyTier = 0
    }

    private mutating func restorePenaltyIfNeeded() {
        guard bundle.mode == .penalty, player.penaltyTier == 0 else { return }
        let required = bundle.quests.filter { $0.kind != .optional }
        guard required.contains(where: { $0.status != .completed }) else { return }
        player.penaltyTier = min(3, max(1, heldPenaltyTier))
    }

    private mutating func undoCompletion(at index: Int) {
        var quest = bundle.quests[index]
        guard quest.status == .completed else { return }
        player.removeXP(quest.grantedXP)
        player.stats[quest.stat] = max(0, player.stats[quest.stat] - quest.grantedStatPoints)
        if quest.grantedRecoveryToken {
            player.withdrawRecoveryToken()
        }
        quest.grantedXP = 0
        quest.grantedStatPoints = 0
        quest.grantedRecoveryToken = false
        quest.status = .pending
        quest.progress.current = 0
        bundle.quests[index] = quest
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
        case recentQuestTitles, generationAttemptDayKey, generatedBundle, readiness, recoveryComposite
        case finance, appliedFinProjection
        case fullRecoveryDayKey, queuedFullRecoveryDayKey, heldPenaltyTier, hasDistractorSelection
        case hiddenUnlocks
        case emergencyFailedDayKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        player = try container.decode(PlayerState.self, forKey: .player)
        player.stats = player.stats.capped()
        signals = try container.decode(MorningSignals.self, forKey: .signals)
        bundle = try container.decode(QuestBundle.self, forKey: .bundle)
        evidenceLog = try container.decodeIfPresent([EvidenceUse].self, forKey: .evidenceLog) ?? []
        runningTimers = try container.decodeIfPresent([TimerRun].self, forKey: .runningTimers) ?? []
        recentQuestTitles = try container.decodeIfPresent([String].self, forKey: .recentQuestTitles) ?? []
        readiness = try container.decodeIfPresent(ReadinessSnapshot.self, forKey: .readiness)
        recoveryComposite = try container.decodeIfPresent(RecoveryComposite.self, forKey: .recoveryComposite) ?? RecoveryComposite()
        finance = try container.decodeIfPresent(FinanceSnapshot.self, forKey: .finance)
        appliedFinProjection = try container.decodeIfPresent(Int.self, forKey: .appliedFinProjection) ?? 0
        fullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .fullRecoveryDayKey)
        queuedFullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .queuedFullRecoveryDayKey)
        heldPenaltyTier = try container.decodeIfPresent(Int.self, forKey: .heldPenaltyTier) ?? 0
        hasDistractorSelection = try container.decodeIfPresent(Bool.self, forKey: .hasDistractorSelection) ?? false
        hiddenUnlocks = try container.decodeIfPresent([HiddenQuestUnlock].self, forKey: .hiddenUnlocks) ?? []
        emergencyFailedDayKey = try container.decodeIfPresent(String.self, forKey: .emergencyFailedDayKey)
        generationAttemptDayKey = try container.decodeIfPresent(String.self, forKey: .generationAttemptDayKey)
        generatedBundle = try container.decodeIfPresent(QuestBundle.self, forKey: .generatedBundle)
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
        try container.encode(recoveryComposite, forKey: .recoveryComposite)
        try container.encodeIfPresent(finance, forKey: .finance)
        try container.encode(appliedFinProjection, forKey: .appliedFinProjection)
        try container.encodeIfPresent(fullRecoveryDayKey, forKey: .fullRecoveryDayKey)
        try container.encodeIfPresent(queuedFullRecoveryDayKey, forKey: .queuedFullRecoveryDayKey)
        try container.encode(heldPenaltyTier, forKey: .heldPenaltyTier)
        try container.encode(hasDistractorSelection, forKey: .hasDistractorSelection)
        try container.encode(hiddenUnlocks, forKey: .hiddenUnlocks)
        try container.encodeIfPresent(emergencyFailedDayKey, forKey: .emergencyFailedDayKey)
        try container.encodeIfPresent(generationAttemptDayKey, forKey: .generationAttemptDayKey)
        try container.encodeIfPresent(generatedBundle, forKey: .generatedBundle)
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
