import Foundation

struct GameSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let storageKey = "com.angelmorales.thesystem.snapshot.v1"

    var version: Int
    var player: PlayerState
    var signals: MorningSignals
    var bundle: QuestBundle

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

    /// New local day swaps in a fallback bundle. Penalty rollover is Phase 2.
    mutating func refreshIfNeeded(catalog: FallbackCatalog, now: Date = .now) {
        let key = QuestDay.key(for: now)
        guard bundle.dayKey != key else { return }
        rebuildBundle(catalog: catalog, now: now)
    }

    mutating func toggleQuest(id: String) {
        guard let index = bundle.quests.firstIndex(where: { $0.id == id }) else { return }
        if bundle.quests[index].status == .completed {
            undoCompletion(at: index)
        } else {
            complete(at: index)
        }
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
