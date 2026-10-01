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

    /// New local day swaps in a fallback bundle. Penalty rollover is still later.
    mutating func refreshIfNeeded(catalog: FallbackCatalog, now: Date = .now) {
        let key = QuestDay.key(for: now)
        guard bundle.dayKey != key else { return }
        rebuildBundle(catalog: catalog, now: now)
        runningTimers.removeAll()
    }

    func verificationContext(
        for quest: Quest,
        now: Date,
        timerElapsed: TimeInterval?,
        userConfirmed: Bool
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
            userConfirmed: userConfirmed
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
            activeTarget: signals.activeTarget,
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

    private mutating func rebuildBundle(catalog: FallbackCatalog, now: Date) {
        let decision = ModePicker.decide(modeInput(now: now))
        bundle = catalog.makeBundle(
            mode: decision.selectedMode,
            band: signals.readinessBand,
            dayKey: QuestDay.key(for: now),
            now: now
        )
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        player = try container.decode(PlayerState.self, forKey: .player)
        signals = try container.decode(MorningSignals.self, forKey: .signals)
        bundle = try container.decode(QuestBundle.self, forKey: .bundle)
        evidenceLog = try container.decodeIfPresent([EvidenceUse].self, forKey: .evidenceLog) ?? []
        runningTimers = try container.decodeIfPresent([TimerRun].self, forKey: .runningTimers) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(player, forKey: .player)
        try container.encode(signals, forKey: .signals)
        try container.encode(bundle, forKey: .bundle)
        try container.encode(evidenceLog, forKey: .evidenceLog)
        try container.encode(runningTimers, forKey: .runningTimers)
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
