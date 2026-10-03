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
    var targets: [Target] = []
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
    /// Shown once, then cleared. Not stored.
    var targetToast: String?
    /// Day that should run as Full Recovery. Set when a token is spent for today.
    var fullRecoveryDayKey: String?
    /// Token spent after today's quests already started. Applied on the next rollover.
    var queuedFullRecoveryDayKey: String?
    /// Tier restored if a cleared penalty quest is undone the same day.
    var heldPenaltyTier: Int = 0
    /// True after a FamilyActivityPicker save. Tokens themselves stay in the App Group.
    var hasDistractorSelection: Bool = false

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
        guard bundle.dayKey != key else { return }
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
        let required = bundle.quests.filter { $0.kind != .optional }
        let missed = !required.isEmpty && required.contains { $0.status != .completed }
        let waived = bundle.mode == .fullRecovery || signals.spendingFullRecovery || fullRecoveryDayKey == bundle.dayKey
        guard missed, !waived else { return }
        player.penaltyTier = min(3, player.penaltyTier + 1)
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
        let completedQuest = bundle.quests[index]
        undoCompletion(at: index)
        restorePenaltyIfNeeded()
        reverseTargetProgress(for: completedQuest)
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
            activeTarget: activeTarget(on: now) != nil,
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
            player.stats.FIN = max(0, player.stats.FIN + delta)
        }
        appliedFinProjection = points
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
        reconcileTargets(now: now)
        let decision = ModePicker.decide(modeInput(now: now))
        let dayKey = QuestDay.key(for: now)
        if var cached = generatedBundle,
           cached.dayKey == dayKey,
           cached.mode == decision.selectedMode {
            cached = cached.strippingModelCompletion(assignedAt: now)
            if let target = activeTarget(on: now) {
                cached = cached.injecting(target, now: now)
            }
            bundle = cached
            return
        }
        var built = catalog.makeBundle(
            mode: decision.selectedMode,
            band: signals.readinessBand,
            dayKey: dayKey,
            now: now
        )
        if let target = activeTarget(on: now) {
            built = built.injecting(target, now: now)
        }
        bundle = built
    }

    private mutating func complete(at index: Int) {
        var quest = bundle.quests[index]
        guard quest.status != .completed else { return }
        let xpGain = Self.xpGrant(for: quest, mode: bundle.mode)
        let statGain = quest.difficulty.statWeight
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
        recordTargetProgress(for: quest)
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
        case version, player, signals, bundle, evidenceLog, runningTimers, targets
        case recentQuestTitles, generationAttemptDayKey, generatedBundle, readiness, recoveryComposite
        case finance, appliedFinProjection
        case fullRecoveryDayKey, queuedFullRecoveryDayKey, heldPenaltyTier, hasDistractorSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        player = try container.decode(PlayerState.self, forKey: .player)
        signals = try container.decode(MorningSignals.self, forKey: .signals)
        bundle = try container.decode(QuestBundle.self, forKey: .bundle)
        evidenceLog = try container.decodeIfPresent([EvidenceUse].self, forKey: .evidenceLog) ?? []
        runningTimers = try container.decodeIfPresent([TimerRun].self, forKey: .runningTimers) ?? []
        targets = try container.decodeIfPresent([Target].self, forKey: .targets) ?? []
        recentQuestTitles = try container.decodeIfPresent([String].self, forKey: .recentQuestTitles) ?? []
        readiness = try container.decodeIfPresent(ReadinessSnapshot.self, forKey: .readiness)
        recoveryComposite = try container.decodeIfPresent(RecoveryComposite.self, forKey: .recoveryComposite) ?? RecoveryComposite()
        finance = try container.decodeIfPresent(FinanceSnapshot.self, forKey: .finance)
        appliedFinProjection = try container.decodeIfPresent(Int.self, forKey: .appliedFinProjection) ?? 0
        fullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .fullRecoveryDayKey)
        queuedFullRecoveryDayKey = try container.decodeIfPresent(String.self, forKey: .queuedFullRecoveryDayKey)
        heldPenaltyTier = try container.decodeIfPresent(Int.self, forKey: .heldPenaltyTier) ?? 0
        hasDistractorSelection = try container.decodeIfPresent(Bool.self, forKey: .hasDistractorSelection) ?? false
        generationAttemptDayKey = try container.decodeIfPresent(String.self, forKey: .generationAttemptDayKey)
        generatedBundle = try container.decodeIfPresent(QuestBundle.self, forKey: .generatedBundle)
        targetToast = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(player, forKey: .player)
        try container.encode(signals, forKey: .signals)
        try container.encode(bundle, forKey: .bundle)
        try container.encode(evidenceLog, forKey: .evidenceLog)
        try container.encode(runningTimers, forKey: .runningTimers)
        try container.encode(targets, forKey: .targets)
        try container.encode(recentQuestTitles, forKey: .recentQuestTitles)
        try container.encodeIfPresent(readiness, forKey: .readiness)
        try container.encode(recoveryComposite, forKey: .recoveryComposite)
        try container.encodeIfPresent(finance, forKey: .finance)
        try container.encode(appliedFinProjection, forKey: .appliedFinProjection)
        try container.encodeIfPresent(fullRecoveryDayKey, forKey: .fullRecoveryDayKey)
        try container.encodeIfPresent(queuedFullRecoveryDayKey, forKey: .queuedFullRecoveryDayKey)
        try container.encode(heldPenaltyTier, forKey: .heldPenaltyTier)
        try container.encode(hasDistractorSelection, forKey: .hasDistractorSelection)
        try container.encodeIfPresent(generationAttemptDayKey, forKey: .generationAttemptDayKey)
        try container.encodeIfPresent(generatedBundle, forKey: .generatedBundle)
    }
}

extension GameSnapshot {
    func activeTarget(on now: Date) -> Target? {
        let today = QuestDay.key(for: now)
        return targets.first { $0.status == .active && $0.contains(today) }
    }

    func targetBanner(on dayKey: String) -> String? {
        guard let target = targets.first(where: { $0.status == .active && $0.contains(dayKey) }) else { return nil }
        return "TARGET ACTIVE · \(target.title) · Day \(target.dayNumber(on: dayKey))/\(target.spanDays)"
    }

    /// Saves a Target. Activates it when the window includes today and nothing else is active.
    mutating func upsertTarget(_ incoming: Target, catalog: FallbackCatalog, now: Date) -> String? {
        var target = incoming
        let trimmed = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Title is required." }
        target.title = trimmed
        guard target.endsOn >= target.startsOn else { return "End date is before the start date." }
        guard !target.dailyRequirements.isEmpty else { return "Add a daily requirement." }
        guard target.dailyRequirements.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.quota > 0 }) else {
            return "Each requirement needs a title and a quota."
        }
        if target.unitsGoal == nil {
            let perDay = target.dailyRequirements.reduce(0) { $0 + Int($1.quota.rounded()) }
            target.unitsGoal = perDay * target.spanDays
        }

        let today = QuestDay.key(for: now)
        let wasActive = targets.first { $0.id == target.id }?.status == .active
        let someoneElseActive = targets.contains { $0.status == .active && $0.id != target.id && $0.contains(today) }
        if target.contains(today) && !someoneElseActive && target.status != .aborted && target.status != .completed && target.status != .expired {
            target.status = .active
        } else if today < target.startsOn {
            target.status = .scheduled
        } else if today > target.endsOn {
            target.status = .expired
        } else if someoneElseActive && target.status != .completed && target.status != .aborted && target.status != .expired {
            target.status = .scheduled
        }

        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        if target.status == .active || wasActive {
            rebuildBundle(catalog: catalog, now: now)
        }
        if someoneElseActive && target.contains(today) {
            return "Scheduled. Abort the active Target first."
        }
        return nil
    }

    mutating func activateTarget(id: String, catalog: FallbackCatalog, now: Date) -> String? {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return "Missing Target." }
        let today = QuestDay.key(for: now)
        if today < targets[index].startsOn {
            targets[index].status = .scheduled
            return "Scheduled for \(targets[index].startsOn)."
        }
        if today > targets[index].endsOn {
            targets[index].status = .expired
            return "That window has ended."
        }
        if targets.contains(where: { $0.status == .active && $0.id != id && $0.contains(today) }) {
            return "Another Target is already active."
        }
        targets[index].status = .active
        rebuildBundle(catalog: catalog, now: now)
        return nil
    }

    mutating func abortTarget(id: String, catalog: FallbackCatalog, now: Date) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        guard targets[index].status == .active || targets[index].status == .scheduled || targets[index].status == .draft else { return }
        targets[index].status = .aborted
        rebuildBundle(catalog: catalog, now: now)
    }

    private mutating func reconcileTargets(now: Date) {
        let today = QuestDay.key(for: now)
        for index in targets.indices where targets[index].status == .active {
            if today > targets[index].endsOn {
                if targets[index].markCompletedIfNeeded(today: today) {
                    player.addXP(Target.completionXP)
                    targetToast = "[Target Complete.]"
                } else if targets[index].status == .active {
                    targets[index].status = .expired
                }
            }
        }
        for index in targets.indices where targets[index].status == .active && today < targets[index].startsOn {
            targets[index].status = .scheduled
        }
        guard activeTarget(on: now) == nil else { return }
        let next = targets.indices
            .filter { targets[$0].status == .scheduled && targets[$0].contains(today) }
            .sorted { targets[$0].startsOn < targets[$1].startsOn }
            .first
        if let next {
            targets[next].status = .active
        }
    }

    private mutating func recordTargetProgress(for quest: Quest) {
        guard quest.kind == .targetInjection, let targetId = quest.targetId,
              let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
        let dayFullyCleared = dayIsCleared(targetId: targetId)
        targets[index].noteQuestCompleted(
            questId: quest.id,
            quota: Int(quest.progress.target.rounded()),
            dayKey: bundle.dayKey,
            dayFullyCleared: dayFullyCleared
        )
        if targets[index].markCompletedIfNeeded(today: bundle.dayKey) {
            player.addXP(Target.completionXP)
            targetToast = "[Target Complete.]"
        }
    }

    private mutating func reverseTargetProgress(for quest: Quest) {
        guard quest.kind == .targetInjection, let targetId = quest.targetId,
              let index = targets.firstIndex(where: { $0.id == targetId }) else { return }
        let dayFullyCleared = dayIsCleared(targetId: targetId)
        targets[index].noteQuestUndone(
            questId: quest.id,
            quota: Int(quest.progress.target.rounded()),
            dayKey: bundle.dayKey,
            dayFullyCleared: dayFullyCleared
        )
        if targets[index].reopenIfIncomplete(today: bundle.dayKey) {
            player.removeXP(Target.completionXP)
            targetToast = nil
        }
    }

    private func dayIsCleared(targetId: String) -> Bool {
        let rows = bundle.quests.filter { $0.kind == .targetInjection && $0.targetId == targetId }
        return !rows.isEmpty && rows.allSatisfy { $0.status == .completed }
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
